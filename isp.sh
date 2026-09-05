#!/bin/bash

# ==========================================
# Sing-box 家宽流量接管模块 (SBA ISP) v2
#   默认：本机所有节点的全部流量走家宽落地
#   高级：只让指定节点 / 端口的流量走家宽
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
NODES_FILE="${CONFIG_DIR}/nodes.json"
ISP_FILE="${CONFIG_DIR}/isp.json"
ISP_TAG="Residential-ISP-Node"
HAVE_CORE=0

# 复用主脚本的函数 (apply_config / 节点表 / 校验等)
load_core() {
    local dir cand
    dir=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo .)")" 2>/dev/null && pwd)
    for cand in "${dir}/install.sh" /usr/bin/sba; do
        [ -f "$cand" ] || continue
        grep -q 'SBA_SOURCE_ONLY' "$cand" 2>/dev/null || continue
        # shellcheck disable=SC1090
        SBA_SOURCE_ONLY=1 source "$cand" >/dev/null 2>&1 && {
            HAVE_CORE=1
            return 0
        }
    done
    return 1
}
load_core

msg() { echo -e "$1"; }
ok() { echo -e "${GREEN}✔ $1${PLAIN}"; }
warn() { echo -e "${YELLOW}! $1${PLAIN}"; }
err() { echo -e "${RED}✘ $1${PLAIN}"; }
line() { echo -e "${CYAN}------------------------------------------${PLAIN}"; }
pause() {
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
    echo ""
}

isp_preflight() {
    if [ "$EUID" -ne 0 ]; then
        err "必须使用 root 用户运行此脚本！"
        sleep 2
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        warn "正在安装 jq 依赖 ..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y jq >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y jq >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y jq >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache jq >/dev/null 2>&1
        fi
        command -v jq >/dev/null 2>&1 || {
            err "jq 安装失败，请手动安装后重试。"
            exit 1
        }
    fi

    if [ ! -f "$CONFIG_FILE" ] && [ ! -f "$NODES_FILE" ]; then
        err "未找到 sing-box 配置 (${CONFIG_FILE})"
        warn "请先安装 sing-box (主脚本菜单 1)。"
        sleep 3
        exit 1
    fi
}

# ================= 通用小工具 =================

urldec() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

qs_get() {
    # qs_get <查询串> <键>
    local qs="$1" k="$2" kv
    for kv in ${qs//&/ }; do
        [ "${kv%%=*}" == "$k" ] || continue
        urldec "${kv#*=}"
        return 0
    done
    return 1
}

b64d() {
    # 兼容无 padding 的 base64url
    local s="${1//-/+}"
    s="${s//_//}"
    case $((${#s} % 4)) in
        2) s="${s}==" ;;
        3) s="${s}=" ;;
    esac
    printf '%s' "$s" | base64 -d 2>/dev/null
}

vp() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

uri_split() {
    local u="$1" rest
    U_SCHEME="${u%%://*}"
    rest="${u#*://}"
    rest="${rest%%#*}"
    U_QUERY=""
    case "$rest" in
        *\?*)
            U_QUERY="${rest#*\?}"
            rest="${rest%%\?*}"
            ;;
    esac
    U_USER=""
    case "$rest" in
        *@*)
            U_USER="${rest%@*}"
            rest="${rest##*@}"
            ;;
    esac
    if [[ "$rest" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        U_HOST="${BASH_REMATCH[1]}"
        U_PORT="${BASH_REMATCH[2]}"
    elif [[ "$rest" == *:* ]]; then
        U_HOST="${rest%%:*}"
        U_PORT="${rest##*:}"
    else
        U_HOST="$rest"
        U_PORT=""
    fi
}

o_tls() {
    # o_tls <none|tls|reality> <sni> <insecure 0/1> <alpn逗号分隔> <pbk> <sid>
    case "$1" in
        tls)
            jq -n --arg sni "$2" --arg ins "$3" --arg alpn "$4" \
                '{enabled:true, server_name:$sni, insecure:($ins=="1")}
                 + (if $alpn == "" then {} else {alpn:($alpn|split(","))} end)'
            ;;
        reality)
            jq -n --arg sni "$2" --arg pbk "$5" --arg sid "$6" \
                '{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:"chrome"},
                  reality:{enabled:true, public_key:$pbk, short_id:$sid}}'
            ;;
        *) echo "null" ;;
    esac
}

o_trans() {
    # o_trans <tcp|ws|grpc|httpupgrade> <path> <host> <serviceName>
    local p="$2" ed=0
    case "$p" in
        *\?ed=*)
            ed="${p##*\?ed=}"
            p="${p%%\?*}"
            ;;
    esac
    case "$1" in
        ws)
            jq -n --arg p "${p:-/}" --arg h "$3" --arg ed "$ed" \
                '{type:"ws", path:$p} + (if $h == "" then {} else {headers:{Host:$h}} end)
                 + (if ($ed|tonumber) > 0 then {max_early_data:($ed|tonumber), early_data_header_name:"Sec-WebSocket-Protocol"} else {} end)'
            ;;
        grpc) jq -n --arg s "$4" '{type:"grpc", service_name:$s}' ;;
        httpupgrade | hu)
            jq -n --arg p "${p:-/}" --arg h "$3" \
                '{type:"httpupgrade", path:$p} + (if $h == "" then {} else {host:$h} end)'
            ;;
        *) echo "null" ;;
    esac
}

set_info() { P_INFO=$(jq -nc --arg t "$1" --arg s "$2" --arg p "$3" '{type:$t, server:$s, port:($p|tonumber)}'); }

pl_vless() {
    local sec type path host svc pbk sid flow ins tls trans base
    sec=$(qs_get "$U_QUERY" security || echo "none")
    type=$(qs_get "$U_QUERY" type || echo tcp)
    path=$(qs_get "$U_QUERY" path || echo "")
    host=$(qs_get "$U_QUERY" host || echo "")
    svc=$(qs_get "$U_QUERY" serviceName || echo "")
    pbk=$(qs_get "$U_QUERY" pbk || echo "")
    sid=$(qs_get "$U_QUERY" sid || echo "")
    flow=$(qs_get "$U_QUERY" flow || echo "")
    ins=0
    [ "$(qs_get "$U_QUERY" allowInsecure || echo 0)" == "1" ] && ins=1
    [ "$(qs_get "$U_QUERY" insecure || echo 0)" == "1" ] && ins=1
    local sni
    sni=$(qs_get "$U_QUERY" sni || echo "")
    [ -z "$sni" ] && sni="${host:-$U_HOST}"

    tls=$(o_tls "$sec" "$sni" "$ins" "" "$pbk" "$sid")
    trans=$(o_trans "$type" "$path" "$host" "$svc")
    base=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" --arg u "$(urldec "$U_USER")" --arg f "$flow" \
        '{type:"vless", tag:$t, server:$s, server_port:($p|tonumber), uuid:$u}
         + (if $f == "" then {} else {flow:$f} end)')
    P_OUT=$(jq -nc --argjson b "$base" --argjson tls "$tls" --argjson tr "$trans" \
        '[$b + (if $tls==null then {} else {tls:$tls} end) + (if $tr==null then {} else {transport:$tr} end)]')
    set_info vless "$U_HOST" "$U_PORT"
}

pl_vmess() {
    local raw j add port id aid net type host path tls sni ins o_t o_tr base
    raw=$(b64d "${1#vmess://}")
    jq -e . >/dev/null 2>&1 <<<"$raw" || {
        err "vmess 链接解析失败 (仅支持 base64 JSON 格式)"
        return 1
    }
    j="$raw"
    add=$(jq -r '.add // ""' <<<"$j")
    port=$(jq -r '.port // ""' <<<"$j" | tr -d '"')
    id=$(jq -r '.id // ""' <<<"$j")
    aid=$(jq -r '.aid // .alterId // 0' <<<"$j" | tr -d '"')
    net=$(jq -r '.net // "tcp"' <<<"$j")
    host=$(jq -r '.host // ""' <<<"$j")
    path=$(jq -r '.path // ""' <<<"$j")
    tls=$(jq -r '.tls // ""' <<<"$j")
    sni=$(jq -r '.sni // ""' <<<"$j")
    [ -z "$sni" ] && sni="${host:-$add}"
    ins=0
    [ "$(jq -r '.verify_cert // "true"' <<<"$j")" == "false" ] && ins=1
    o_t="null"
    [ "$tls" == "tls" ] && o_t=$(o_tls tls "$sni" "$ins" "" "" "")
    [ "$tls" == "reality" ] && o_t=$(o_tls reality "$sni" 0 "" "$(jq -r '.pbk // ""' <<<"$j")" "$(jq -r '.sid // ""' <<<"$j")")
    o_tr=$(o_trans "$net" "$path" "$host" "$path")
    vp "$port" || {
        err "vmess 链接端口不合法"
        return 1
    }
    base=$(jq -nc --arg t "$ISP_TAG" --arg s "$add" --arg p "$port" --arg u "$id" --arg a "$aid" \
        '{type:"vmess", tag:$t, server:$s, server_port:($p|tonumber), uuid:$u,
          security:"auto", alter_id:($a|tonumber)}')
    P_OUT=$(jq -nc --argjson b "$base" --argjson tls "$o_t" --argjson tr "$o_tr" \
        '[$b + (if $tls==null then {} else {tls:$tls} end) + (if $tr==null then {} else {transport:$tr} end)]')
    set_info vmess "$add" "$port"
}

pl_trojan() {
    local sec type path host svc ins sni tls trans base
    sec=$(qs_get "$U_QUERY" security || echo "tls")
    [ "$sec" == "none" ] && sec="none"
    type=$(qs_get "$U_QUERY" type || echo tcp)
    path=$(qs_get "$U_QUERY" path || echo "")
    host=$(qs_get "$U_QUERY" host || echo "")
    svc=$(qs_get "$U_QUERY" serviceName || echo "")
    ins=0
    [ "$(qs_get "$U_QUERY" allowInsecure || echo 0)" == "1" ] && ins=1
    [ "$(qs_get "$U_QUERY" insecure || echo 0)" == "1" ] && ins=1
    sni=$(qs_get "$U_QUERY" sni || echo "")
    [ -z "$sni" ] && sni="${host:-$U_HOST}"
    [ "$sec" == "reality" ] &&
        tls=$(o_tls reality "$sni" 0 "" "$(qs_get "$U_QUERY" pbk || echo '')" "$(qs_get "$U_QUERY" sid || echo '')") ||
        tls=$(o_tls "$sec" "$sni" "$ins" "" "" "")
    trans=$(o_trans "$type" "$path" "$host" "$svc")
    base=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" --arg pw "$(urldec "$U_USER")" \
        '{type:"trojan", tag:$t, server:$s, server_port:($p|tonumber), password:$pw}')
    P_OUT=$(jq -nc --argjson b "$base" --argjson tls "$tls" --argjson tr "$trans" \
        '[$b + (if $tls==null then {} else {tls:$tls} end) + (if $tr==null then {} else {transport:$tr} end)]')
    set_info trojan "$U_HOST" "$U_PORT"
}

pl_ss() {
    local body userinfo method pass plugin stls_host stls_pw ver
    body="${1#ss://}"
    body="${body%%#*}"
    if [[ "$body" != *@* ]]; then
        # 整体 base64: method:pass@host:port
        body=$(b64d "${body%%\?*}")
        [ -z "$body" ] && {
            err "ss 链接解析失败"
            return 1
        }
        uri_split "ss://${body}"
        userinfo="$U_USER"
        method="${userinfo%%:*}"
        pass="${userinfo#*:}"
    else
        uri_split "$1"
        userinfo=$(b64d "$U_USER")
        [ -z "$userinfo" ] && userinfo=$(urldec "$U_USER")
        method="${userinfo%%:*}"
        pass="${userinfo#*:}"
    fi
    vp "$U_PORT" || {
        err "ss 链接端口不合法"
        return 1
    }
    plugin=$(qs_get "$U_QUERY" plugin || echo "")

    if [[ "$plugin" == shadow-tls* ]]; then
        # ss over shadowtls: shadowsocks 不写 server/port，靠 detour 指向 shadowtls 出站
        stls_host=$(sed -n 's/.*host=\([^;]*\).*/\1/p' <<<"$plugin")
        stls_pw=$(sed -n 's/.*password=\([^;]*\).*/\1/p' <<<"$plugin")
        ver=$(sed -n 's/.*version=\([^;]*\).*/\1/p' <<<"$plugin")
        [ -z "$ver" ] && ver=3
        P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg m "$method" --arg pw "$pass" \
            --arg s "$U_HOST" --arg p "$U_PORT" --arg h "${stls_host:-$U_HOST}" \
            --arg spw "$stls_pw" --arg v "$ver" \
            '[{type:"shadowsocks", tag:$t, method:$m, password:$pw, detour:($t+"-stls")},
              {type:"shadowtls", tag:($t+"-stls"), server:$s, server_port:($p|tonumber),
               version:($v|tonumber), password:$spw,
               tls:{enabled:true, server_name:$h, utls:{enabled:true, fingerprint:"chrome"}}}]')
        set_info "ss+shadowtls" "$U_HOST" "$U_PORT"
    else
        P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" --arg m "$method" --arg pw "$pass" \
            '[{type:"shadowsocks", tag:$t, server:$s, server_port:($p|tonumber), method:$m, password:$pw}]')
        set_info shadowsocks "$U_HOST" "$U_PORT"
    fi
}

pl_hy2() {
    local sni ins obfs obpw
    sni=$(qs_get "$U_QUERY" sni || echo "$U_HOST")
    ins=0
    [ "$(qs_get "$U_QUERY" insecure || echo 0)" == "1" ] && ins=1
    obfs=$(qs_get "$U_QUERY" obfs || echo "")
    obpw=$(qs_get "$U_QUERY" obfs-password || echo "")
    P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" \
        --arg pw "$(urldec "$U_USER")" --arg sni "$sni" --arg ins "$ins" \
        --arg ob "$obfs" --arg obpw "$obpw" \
        '[{type:"hysteria2", tag:$t, server:$s, server_port:($p|tonumber), password:$pw,
           tls:{enabled:true, server_name:$sni, insecure:($ins=="1"), alpn:["h3"]}}
          + (if $ob == "" then {} else {obfs:{type:$ob, password:$obpw}} end)]')
    set_info hysteria2 "$U_HOST" "$U_PORT"
}

pl_hysteria() {
    local sni ins auth up down
    sni=$(qs_get "$U_QUERY" peer || qs_get "$U_QUERY" sni || echo "$U_HOST")
    ins=0
    [ "$(qs_get "$U_QUERY" insecure || echo 0)" == "1" ] && ins=1
    auth=$(qs_get "$U_QUERY" auth || echo "")
    up=$(qs_get "$U_QUERY" upmbps || echo 100)
    down=$(qs_get "$U_QUERY" downmbps || echo 500)
    P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" --arg a "$auth" \
        --arg sni "$sni" --arg ins "$ins" --arg up "$up" --arg down "$down" \
        '[{type:"hysteria", tag:$t, server:$s, server_port:($p|tonumber), auth_str:$a,
           up_mbps:($up|tonumber), down_mbps:($down|tonumber),
           tls:{enabled:true, server_name:$sni, insecure:($ins=="1"), alpn:["h3"]}}]')
    set_info hysteria "$U_HOST" "$U_PORT"
}

pl_tuic() {
    local uuid pass sni ins cc udp
    uuid="${U_USER%%:*}"
    pass=$(urldec "${U_USER#*:}")
    sni=$(qs_get "$U_QUERY" sni || echo "$U_HOST")
    ins=0
    [ "$(qs_get "$U_QUERY" allow_insecure || echo 0)" == "1" ] && ins=1
    [ "$(qs_get "$U_QUERY" insecure || echo 0)" == "1" ] && ins=1
    cc=$(qs_get "$U_QUERY" congestion_control || echo bbr)
    udp=$(qs_get "$U_QUERY" udp_relay_mode || echo native)
    P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" --arg u "$uuid" \
        --arg pw "$pass" --arg sni "$sni" --arg ins "$ins" --arg cc "$cc" --arg udp "$udp" \
        '[{type:"tuic", tag:$t, server:$s, server_port:($p|tonumber), uuid:$u, password:$pw,
           congestion_control:$cc, udp_relay_mode:$udp,
           tls:{enabled:true, server_name:$sni, insecure:($ins=="1"), alpn:["h3"]}}]')
    set_info tuic "$U_HOST" "$U_PORT"
}

pl_anytls() {
    local sni ins sec tls
    sni=$(qs_get "$U_QUERY" sni || echo "$U_HOST")
    ins=0
    [ "$(qs_get "$U_QUERY" insecure || echo 0)" == "1" ] && ins=1
    sec=$(qs_get "$U_QUERY" security || echo tls)
    if [ "$sec" == "reality" ]; then
        tls=$(o_tls reality "$sni" 0 "" "$(qs_get "$U_QUERY" pbk || echo '')" "$(qs_get "$U_QUERY" sid || echo '')")
    else
        tls=$(o_tls tls "$sni" "$ins" "" "" "")
    fi
    P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" \
        --arg pw "$(urldec "$U_USER")" --argjson tls "$tls" \
        '[{type:"anytls", tag:$t, server:$s, server_port:($p|tonumber), password:$pw, tls:$tls}]')
    set_info anytls "$U_HOST" "$U_PORT"
}

pl_socks() {
    local ui user pass
    ui="$U_USER"
    [[ "$ui" != *:* ]] && ui=$(b64d "$ui")
    user=$(urldec "${ui%%:*}")
    pass=$(urldec "${ui#*:}")
    [ "$user" == "$pass" ] && [ -z "${ui}" ] && {
        user=""
        pass=""
    }
    P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "$U_PORT" --arg u "$user" --arg pw "$pass" \
        '[{type:"socks", tag:$t, server:$s, server_port:($p|tonumber), version:"5"}
          + (if $u == "" then {} else {username:$u, password:$pw} end)]')
    set_info socks "$U_HOST" "$U_PORT"
}

pl_http() {
    local user pass usetls=0
    [ "$U_SCHEME" == "https" ] && usetls=1
    user=$(urldec "${U_USER%%:*}")
    pass=$(urldec "${U_USER#*:}")
    [ -z "$U_USER" ] && {
        user=""
        pass=""
    }
    P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$U_HOST" --arg p "${U_PORT:-80}" --arg u "$user" \
        --arg pw "$pass" --arg tls "$usetls" --arg sni "$U_HOST" \
        '[{type:"http", tag:$t, server:$s, server_port:($p|tonumber)}
          + (if $u == "" then {} else {username:$u, password:$pw} end)
          + (if $tls == "1" then {tls:{enabled:true, server_name:$sni}} else {} end)]')
    set_info http "$U_HOST" "${U_PORT:-80}"
}

parse_link() {
    local u
    u=$(printf '%s' "$1" | tr -d '[:space:]')
    P_OUT=""
    P_INFO=""
    case "$u" in
        vmess://*) pl_vmess "$u" || return 1 ;;
        vless://*)
            uri_split "$u"
            pl_vless
            ;;
        trojan://*)
            uri_split "$u"
            pl_trojan
            ;;
        ss://*) pl_ss "$u" || return 1 ;;
        hysteria2://* | hy2://*)
            uri_split "$u"
            pl_hy2
            ;;
        hysteria://*)
            uri_split "$u"
            pl_hysteria
            ;;
        tuic://*)
            uri_split "$u"
            pl_tuic
            ;;
        anytls://*)
            uri_split "$u"
            pl_anytls
            ;;
        socks://* | socks5://*)
            uri_split "$u"
            pl_socks
            ;;
        http://* | https://*)
            uri_split "$u"
            pl_http
            ;;
        naive+https://*)
            err "sing-box 1.14 的 naive 出站不可用 (cronet 库缺失)，请换用其它协议。"
            return 1
            ;;
        *)
            err "无法识别的链接格式: ${u:0:20}..."
            return 1
            ;;
    esac
    jq -e . >/dev/null 2>&1 <<<"$P_OUT" || {
        err "链接解析失败"
        return 1
    }
    local sv
    sv=$(jq -r '[.[] | select(.server != null)] | .[0].server // ""' <<<"$P_OUT")
    [ -z "$sv" ] && {
        err "链接里缺少服务器地址"
        return 1
    }
    return 0
}

input_by_link() {
    local u
    line
    msg "支持: vless / vmess / trojan / ss (含 shadow-tls 插件) / hysteria2 / hysteria / tuic / anytls / socks / http"
    line
    read -r -p "请粘贴家宽节点分享链接: " u
    [ -z "${u// /}" ] && return 1
    parse_link "$u" || return 1
    ok "已解析: $(jq -r '.type + "  " + .server + ":" + (.port|tostring)' <<<"$P_INFO")"
    return 0
}

ask_common() {
    # 结果: M_ADDR / M_PORT
    while true; do
        read -r -p "服务器 IP 或域名: " M_ADDR
        [ -n "${M_ADDR// /}" ] && break
        err "不能为空"
    done
    while true; do
        read -r -p "服务器端口: " M_PORT
        vp "$M_PORT" && break
        err "端口不合法"
    done
}

input_manual() {
    local c u pw method sni ins ver mode
    line
    msg " 1. SOCKS5 (最常见的家宽/指纹浏览器节点)"
    msg " 2. HTTP / HTTPS"
    msg " 3. Shadowsocks"
    msg " 4. Trojan"
    msg " 5. VMess (TCP，可选 TLS)"
    msg " 6. VLESS (TCP / TLS)"
    msg " 7. Hysteria2"
    msg " 8. TUIC v5"
    msg " 9. AnyTLS"
    msg "10. Snell (v4 / v6)"
    line
    read -r -p "请选择家宽节点协议 [1-10]: " c
    ask_common
    P_OUT=""
    case "$c" in
        1)
            read -r -p "用户名 (留空=无认证): " u
            read -r -p "密码: " pw
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg u "$u" --arg pw "$pw" \
                '[{type:"socks", tag:$t, server:$s, server_port:($p|tonumber), version:"5"}
                  + (if $u == "" then {} else {username:$u, password:$pw} end)]')
            set_info socks "$M_ADDR" "$M_PORT"
            ;;
        2)
            read -r -p "用户名 (留空=无认证): " u
            read -r -p "密码: " pw
            read -r -p "启用 TLS (HTTPS 代理)？[y/N]: " ins
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg u "$u" --arg pw "$pw" \
                --arg tls "$(echo "$ins" | grep -qi '^y' && echo 1 || echo 0)" \
                '[{type:"http", tag:$t, server:$s, server_port:($p|tonumber)}
                  + (if $u == "" then {} else {username:$u, password:$pw} end)
                  + (if $tls == "1" then {tls:{enabled:true, server_name:$s}} else {} end)]')
            set_info http "$M_ADDR" "$M_PORT"
            ;;
        3)
            read -r -p "加密方式 [回车=aes-256-gcm]: " method
            method="${method:-aes-256-gcm}"
            read -r -p "密码: " pw
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg m "$method" --arg pw "$pw" \
                '[{type:"shadowsocks", tag:$t, server:$s, server_port:($p|tonumber), method:$m, password:$pw}]')
            set_info shadowsocks "$M_ADDR" "$M_PORT"
            ;;
        4)
            read -r -p "密码: " pw
            read -r -p "SNI [回车=${M_ADDR}]: " sni
            read -r -p "跳过证书验证 (自签证书需要)？[y/N]: " ins
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg pw "$pw" \
                --arg sni "${sni:-$M_ADDR}" --arg ins "$(echo "$ins" | grep -qi '^y' && echo 1 || echo 0)" \
                '[{type:"trojan", tag:$t, server:$s, server_port:($p|tonumber), password:$pw,
                   tls:{enabled:true, server_name:$sni, insecure:($ins=="1")}}]')
            set_info trojan "$M_ADDR" "$M_PORT"
            ;;
        5)
            read -r -p "UUID: " u
            read -r -p "启用 TLS？[y/N]: " ins
            read -r -p "SNI [回车=${M_ADDR}]: " sni
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg u "$u" \
                --arg sni "${sni:-$M_ADDR}" --arg tls "$(echo "$ins" | grep -qi '^y' && echo 1 || echo 0)" \
                '[{type:"vmess", tag:$t, server:$s, server_port:($p|tonumber), uuid:$u,
                   security:"auto", alter_id:0}
                  + (if $tls == "1" then {tls:{enabled:true, server_name:$sni, insecure:true}} else {} end)]')
            set_info vmess "$M_ADDR" "$M_PORT"
            ;;
        6)
            read -r -p "UUID: " u
            read -r -p "启用 TLS？[y/N]: " ins
            read -r -p "SNI [回车=${M_ADDR}]: " sni
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg u "$u" \
                --arg sni "${sni:-$M_ADDR}" --arg tls "$(echo "$ins" | grep -qi '^y' && echo 1 || echo 0)" \
                '[{type:"vless", tag:$t, server:$s, server_port:($p|tonumber), uuid:$u}
                  + (if $tls == "1" then {tls:{enabled:true, server_name:$sni, insecure:true}} else {} end)]')
            set_info vless "$M_ADDR" "$M_PORT"
            ;;
        7)
            read -r -p "密码: " pw
            read -r -p "SNI [回车=${M_ADDR}]: " sni
            read -r -p "跳过证书验证？[Y/n]: " ins
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg pw "$pw" \
                --arg sni "${sni:-$M_ADDR}" --arg ins "$(echo "$ins" | grep -qi '^n' && echo 0 || echo 1)" \
                '[{type:"hysteria2", tag:$t, server:$s, server_port:($p|tonumber), password:$pw,
                   tls:{enabled:true, server_name:$sni, insecure:($ins=="1"), alpn:["h3"]}}]')
            set_info hysteria2 "$M_ADDR" "$M_PORT"
            ;;
        8)
            read -r -p "UUID: " u
            read -r -p "密码: " pw
            read -r -p "SNI [回车=${M_ADDR}]: " sni
            read -r -p "跳过证书验证？[Y/n]: " ins
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg u "$u" --arg pw "$pw" \
                --arg sni "${sni:-$M_ADDR}" --arg ins "$(echo "$ins" | grep -qi '^n' && echo 0 || echo 1)" \
                '[{type:"tuic", tag:$t, server:$s, server_port:($p|tonumber), uuid:$u, password:$pw,
                   congestion_control:"bbr", udp_relay_mode:"native",
                   tls:{enabled:true, server_name:$sni, insecure:($ins=="1"), alpn:["h3"]}}]')
            set_info tuic "$M_ADDR" "$M_PORT"
            ;;
        9)
            read -r -p "密码: " pw
            read -r -p "SNI [回车=${M_ADDR}]: " sni
            read -r -p "跳过证书验证？[Y/n]: " ins
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg pw "$pw" \
                --arg sni "${sni:-$M_ADDR}" --arg ins "$(echo "$ins" | grep -qi '^n' && echo 0 || echo 1)" \
                '[{type:"anytls", tag:$t, server:$s, server_port:($p|tonumber), password:$pw,
                   tls:{enabled:true, server_name:$sni, insecure:($ins=="1")}}]')
            set_info anytls "$M_ADDR" "$M_PORT"
            ;;
        10)
            read -r -p "PSK: " pw
            warn "sing-box 出站只支持 Snell v4 / v6 (v5 服务端请填 4，线路协议一致)。"
            read -r -p "版本 [4/6，回车=4]: " ver
            ver="${ver:-4}"
            [ "$ver" == "6" ] || ver=4
            mode=""
            [ "$ver" == "6" ] && {
                read -r -p "v6 mode [default/unshaped/unsafe-raw，回车=default]: " mode
                mode="${mode:-default}"
            }
            P_OUT=$(jq -nc --arg t "$ISP_TAG" --arg s "$M_ADDR" --arg p "$M_PORT" --arg pw "$pw" \
                --arg v "$ver" --arg m "$mode" \
                '[{type:"snell", tag:$t, server:$s, server_port:($p|tonumber), psk:$pw, version:($v|tonumber)}
                  + (if $m == "" then {} else {mode:$m} end)]')
            set_info "snell v${ver}" "$M_ADDR" "$M_PORT"
            ;;
        *)
            err "输入错误"
            return 1
            ;;
    esac
    [ -z "$P_OUT" ] && return 1
    return 0
}

isp_expand() {
    local raw="${1//,/ }" tok a b i out=""
    for tok in $raw; do
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a="${BASH_REMATCH[1]}"
            b="${BASH_REMATCH[2]}"
            for ((i = a; i <= b; i++)); do out="$out $i"; done
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then
            out="$out $tok"
        fi
    done
    echo "$out" | tr ' ' '\n' | grep -v '^$' | awk '!seen[$0]++' | tr '\n' ' '
}

list_inbounds() {
    # 输出: tag <TAB> port <TAB> 类型
    if [ -f "$NODES_FILE" ]; then
        jq -r '.nodes[]? | select(.enabled != false) | "\(.tag)\t\(.port)\t\(.key)"' "$NODES_FILE" 2>/dev/null
    elif [ -f "$CONFIG_FILE" ]; then
        jq -r '.inbounds[]? | select(.tag != null and .type != "direct" and .type != "tun")
               | "\(.tag)\t\(.listen_port // 0)\t\(.type)"' "$CONFIG_FILE" 2>/dev/null
    fi
}

select_targets() {
    # 结果: TARGET_TAGS (JSON 数组)
    TARGET_TAGS="[]"
    local rows=() i n c tag ports p
    mapfile -t rows < <(list_inbounds)
    [ ${#rows[@]} -eq 0 ] && {
        err "没有找到任何本机节点"
        return 1
    }
    line
    msg "本机节点列表："
    for i in "${!rows[@]}"; do
        printf " %b%2d%b) %-24s 端口 %-8s %s\n" "$GREEN" "$((i + 1))" "$PLAIN" \
            "$(cut -f1 <<<"${rows[$i]}")" "$(cut -f2 <<<"${rows[$i]}")" "$(cut -f3 <<<"${rows[$i]}")"
    done
    line
    msg " 直接输入编号选择需要接管的节点，支持 ${YELLOW}1 3${PLAIN} / ${YELLOW}1-4${PLAIN}"
    msg " 输入 ${YELLOW}p${PLAIN} 改为按端口指定 (会自动换算成节点 tag)"
    read -r -p "请输入: " c

    if [[ "$c" =~ ^[pP]$ ]]; then
        read -r -p "端口号 (多个用空格/逗号分隔): " ports
        for p in ${ports//,/ }; do
            tag=$(awk -F'\t' -v pp="$p" '$2==pp{print $1; exit}' <<<"$(printf '%s\n' "${rows[@]}")")
            if [ -n "$tag" ]; then
                TARGET_TAGS=$(jq -c --arg t "$tag" '. + [$t]' <<<"$TARGET_TAGS")
            else
                warn "端口 $p 没有对应的本机节点，已忽略 (1.14 的 route.rules 不支持直接写端口)"
            fi
        done
    else
        for n in $(isp_expand "$c"); do
            [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#rows[@]}" ] || continue
            tag=$(cut -f1 <<<"${rows[$((n - 1))]}")
            TARGET_TAGS=$(jq -c --arg t "$tag" '. + [$t]' <<<"$TARGET_TAGS")
        done
    fi
    TARGET_TAGS=$(jq -c 'unique' <<<"$TARGET_TAGS")
    [ "$(jq 'length' <<<"$TARGET_TAGS")" -eq 0 ] && {
        err "未选择任何节点"
        return 1
    }
    ok "已选择: $(jq -r 'join(", ")' <<<"$TARGET_TAGS")"
    return 0
}

write_isp() {
    # write_isp <all|selective>
    local mode="$1" tmp="${ISP_FILE}.tmp"
    mkdir -p "$CONFIG_DIR"
    jq -n --argjson out "$P_OUT" --argjson info "${P_INFO:-null}" --arg tag "$ISP_TAG" \
        --arg mode "$mode" --argjson tags "${TARGET_TAGS:-[]}" \
        '{enabled:true, mode:$mode, tag:$tag, outbounds:$out,
          targets:{tags:$tags}, info:$info}' >"$tmp" 2>/dev/null || {
        err "写入 isp.json 失败"
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$ISP_FILE"
    chmod 600 "$ISP_FILE"
}

sb_bin() {
    command -v sing-box 2>/dev/null || echo /usr/local/bin/sing-box
}

free_probe_port() {
    local p=42150
    while [ "$p" -lt 42199 ]; do
        (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null || {
            echo "$p"
            return 0
        }
        exec 3>&- 2>/dev/null
        p=$((p + 1))
    done
    echo 42199
}

exit_ip_via() {
    # exit_ip_via <proxy|direct>  依次试几个查 IP 的站，某一个被墙也还能拿到结果
    local proxy="$1" u ip
    for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip https://api-ipv4.ip.sb/ip; do
        if [ "$proxy" == "direct" ]; then
            ip=$(curl -fsS4 --max-time 6 "$u" 2>/dev/null | tr -dc '0-9a-fA-F:.' | cut -c1-45)
        else
            ip=$(curl -s --max-time 6 -x "$proxy" "$u" 2>/dev/null | tr -dc '0-9a-fA-F:.' | cut -c1-45)
        fi
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

probe_landing() {
    # probe_landing [outbounds_json]
    # 真的把流量灌进落地出站跑一次 —— 只探端口是不够的：端口开着但握手不成的情况最常见
    # 0=通 1=不通 2=无法测；成功时 LAND_IP 是经落地看到的出口 IP
    local outs tag bin cfg lport pid code
    LAND_IP=""
    LAND_MSG=""
    outs="${1:-}"
    tag="$ISP_TAG"
    if [ -z "$outs" ]; then
        [ -f "$ISP_FILE" ] || {
            LAND_MSG="没有 isp.json"
            return 2
        }
        outs=$(jq -c '.outbounds // []' "$ISP_FILE" 2>/dev/null)
        tag=$(jq -r ".tag // \"$ISP_TAG\"" "$ISP_FILE" 2>/dev/null)
    fi
    if [ -z "$outs" ] || [ "$outs" == "[]" ]; then
        LAND_MSG="没有落地出站参数"
        return 2
    fi
    bin=$(sb_bin)
    if [ ! -x "$bin" ] && ! command -v sing-box >/dev/null 2>&1; then
        LAND_MSG="找不到 sing-box 内核"
        return 2
    fi
    lport=$(free_probe_port)
    cfg="/tmp/sba_isp_probe_$$.json"
    jq -n --argjson o "$outs" --arg t "$tag" --arg p "$lport" \
        '{log:{level:"error"},
          dns:{servers:[{type:"local", tag:"local"}]},
          inbounds:[{type:"mixed", tag:"probe-in", listen:"127.0.0.1", listen_port:($p|tonumber)}],
          outbounds:($o + [{type:"direct", tag:"direct"}]),
          route:{rules:[], final:$t,
                 default_domain_resolver:{server:"local", strategy:"prefer_ipv4"}}}' >"$cfg" 2>/dev/null
    local cout
    cout=$("$bin" check -c "$cfg" 2>&1)
    if [ -n "$cout" ]; then
        LAND_MSG=$(echo "$cout" | head -1 | cut -c1-100)
        rm -f "$cfg"
        return 2
    fi
    "$bin" run -c "$cfg" >/dev/null 2>&1 &
    pid=$!
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        LAND_MSG="探测进程启动失败"
        rm -f "$cfg"
        return 2
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${ISP_PROBE_TIMEOUT:-10}" \
        -x "http://127.0.0.1:${lport}" "${ISP_PROBE_URL:-https://www.gstatic.com/generate_204}" 2>/dev/null)
    if [ "$code" == "204" ] || [ "$code" == "200" ]; then
        LAND_IP=$(exit_ip_via "http://127.0.0.1:${lport}")
    fi
    kill "$pid" >/dev/null 2>&1
    wait "$pid" 2>/dev/null
    rm -f "$cfg"
    if [ "$code" == "204" ] || [ "$code" == "200" ]; then
        return 0
    fi
    LAND_MSG="curl code=${code:-000}"
    return 1
}

landing_hint() {
    # 落地不通时给具体建议 (可传 outbounds_json，默认读 isp.json)
    local outs typ sec
    outs="${1:-}"
    if [ -z "$outs" ] && [ -f "$ISP_FILE" ]; then
        outs=$(jq -c '.outbounds // []' "$ISP_FILE" 2>/dev/null)
    fi
    typ=$(jq -r '.[0].type // ""' <<<"${outs:-[]}" 2>/dev/null)
    sec=$(jq -r 'if ((.[0].tls.enabled // false) == true) then "tls" else "none" end' \
        <<<"${outs:-[]}" 2>/dev/null)
    warn "落地不通的常见原因："
    msg "  · 家宽那台机器上的服务没在跑，或路由器/光猫的端口转发失效"
    msg "  · 端口填错：家宽脚本通常一次开好几个连号端口，${YELLOW}不同端口是不同协议${PLAIN}"
    msg "  · 参数不匹配：UUID / 密码 / SNI / public_key / short_id 抄漏一项都会静默卡住"
    if [ "$typ" == "vless" ] && [ "$sec" != "tls" ]; then
        line
        err "落地是「裸 VLESS」(既没有 TLS 也没有 REALITY)，这种组合八成连不上："
        msg "  Xray 25.9 起的内核会给裸 VLESS 入站启用 ${YELLOW}VLESS Encryption${PLAIN} (decryption=mlkem768x25519plus...)，"
        msg "  而 ${YELLOW}sing-box 的 vless 出站根本没有 encryption 字段${PLAIN}，握手会静默卡死、日志里也不报错。"
        msg "  解决：让落地那台机器换一个端口给本机用 —— ${GREEN}VLESS+REALITY / VMess / Trojan / Shadowsocks / SOCKS5${PLAIN} 都行。"
    fi
}

patch_config_direct() {
    # 没有 nodes.json 的老部署：直接改 config.json
    local mode tags bin tmp bak
    mode=$(jq -r '.mode // "all"' "$ISP_FILE")
    tags=$(jq -c '.targets.tags // []' "$ISP_FILE")
    bin=$(sb_bin)
    tmp="${CONFIG_FILE}.tmp"
    bak="${CONFIG_FILE}.bak_$(date +%s)"
    cp -f "$CONFIG_FILE" "$bak"

    jq --arg tag "$ISP_TAG" --argjson out "$P_OUT" --arg mode "$mode" --argjson tags "$tags" '
        .outbounds = ([(.outbounds // [])[]
                       | select((.tag // "") != $tag and ((.tag // "") | startswith($tag + "-") | not))]
                      + $out)
        | .outbounds = (if ([.outbounds[] | select(.type == "direct")] | length) == 0
                        then .outbounds + [{type:"direct", tag:"direct"}] else .outbounds end)
        | .route = (.route // {})
        | .route.rules = [((.route.rules // [])[]) | select((.outbound // "") != $tag)]
        | if $mode == "all"
          then .route.final = $tag
          else .route.rules = ([{inbound:$tags, outbound:$tag}] + .route.rules)
               | .route.final = (if (.route.final // "") == $tag then "direct" else (.route.final // "direct") end)
          end
    ' "$CONFIG_FILE" >"$tmp" 2>/dev/null || {
        err "修改 config.json 失败"
        rm -f "$tmp"
        return 1
    }

    if [ -x "$bin" ] || command -v sing-box >/dev/null 2>&1; then
        local out
        out=$("$bin" check -c "$tmp" 2>&1)
        [ -n "$out" ] && {
            err "新配置未通过 sing-box 校验，已放弃修改："
            echo "$out" | head -5
            rm -f "$tmp"
            return 1
        }
    fi
    mv -f "$tmp" "$CONFIG_FILE"
    systemctl restart sing-box >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        return 0
    fi
    err "sing-box 启动失败，已回滚。"
    journalctl -u sing-box -n 10 --no-pager 2>/dev/null | tail -10
    cp -f "$bak" "$CONFIG_FILE"
    systemctl restart sing-box >/dev/null 2>&1
    return 1
}

apply_isp() {
    if [ "$HAVE_CORE" == "1" ] && [ -f "$NODES_FILE" ]; then
        # 主脚本会用 nodes.json + isp.json 重新生成 config.json
        apply_config
        return $?
    fi
    patch_config_direct
}

load_existing() {
    [ -f "$ISP_FILE" ] || return 1
    P_OUT=$(jq -c '.outbounds // []' "$ISP_FILE" 2>/dev/null)
    P_INFO=$(jq -c '.info // null' "$ISP_FILE" 2>/dev/null)
    TARGET_TAGS=$(jq -c '.targets.tags // []' "$ISP_FILE" 2>/dev/null)
    [ -n "$P_OUT" ] && [ "$(jq 'length' <<<"$P_OUT")" -gt 0 ]
}

status_body() {
    if ! load_existing || ! jq -e '.enabled == true' "$ISP_FILE" >/dev/null 2>&1; then
        warn "当前未开启家宽接管。"
        return 1
    fi
    local mode
    mode=$(jq -r '.mode // "all"' "$ISP_FILE")
    echo -e "${GREEN}【家宽落地节点】${PLAIN}"
    jq -r '.outbounds[] | "  - " + .type + "  " + ((.server // "(链式)")|tostring)
           + (if .server_port then ":" + (.server_port|tostring) else "" end)
           + "   tag=" + .tag' "$ISP_FILE"
    echo ""
    echo -e "${GREEN}【接管范围】${PLAIN}"
    if [ "$mode" == "all" ]; then
        echo -e "  ${GREEN}全量接管${PLAIN}：本机所有入站的流量默认走家宽 (route.final=${ISP_TAG})"
    else
        echo -e "  ${YELLOW}按节点接管${PLAIN}：$(jq -r '(.targets.tags // []) | join(", ")' "$ISP_FILE")"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        echo ""
        echo -e "${GREEN}【生效情况 (config.json)】${PLAIN}"
        echo -e "  route.final = $(jq -r '.route.final // "-"' "$CONFIG_FILE")"
        echo -e "  指向家宽的规则数 = $(jq --arg t "$ISP_TAG" '[(.route.rules // [])[] | select((.outbound // "") == $t)] | length' "$CONFIG_FILE")"
        echo -e "  家宽出站已写入 = $(jq --arg t "$ISP_TAG" '[(.outbounds // [])[] | select(.tag == $t)] | length > 0' "$CONFIG_FILE")"
    fi
    return 0
}

view_status() {
    clear
    line
    echo -e "${CYAN}            家宽流量接管状态              ${PLAIN}"
    line
    status_body
    line
    pause
}

enable_takeover() {
    clear
    line
    echo -e "${CYAN}          配置家宽落地节点参数            ${PLAIN}"
    line
    msg " 1. 粘贴分享链接自动解析 ${GREEN}(推荐)${PLAIN}"
    msg " 2. 手动填写参数"
    msg " 0. 返回"
    local c m mode
    read -r -p "请选择 [1-2]: " c
    case "$c" in
        1) input_by_link || {
            pause
            return
        } ;;
        2) input_manual || {
            pause
            return
        } ;;
        *) return ;;
    esac

    line
    warn "正在实测落地节点能不能出网 (最多 ${ISP_PROBE_TIMEOUT:-10}s，只探端口是不够的) ..."
    probe_landing "$P_OUT"
    case "$?" in
        0) ok "落地可用，经落地看到的出口 IP：${GREEN}${LAND_IP:-未知}${PLAIN}" ;;
        2) warn "无法实测 (${LAND_MSG})，跳过这一步" ;;
        *)
            err "落地节点实测不通 (${LAND_MSG})"
            landing_hint "$P_OUT"
            line
            local goon
            read -r -p "仍要继续开启接管吗？(开启后被接管的节点都会连不上) [y/N]: " goon
            if [[ ! "$goon" =~ ^[yY]$ ]]; then
                warn "已取消，isp.json 未改动。"
                pause
                return
            fi
            ;;
    esac

    line
    msg "接管范围："
    msg " 1. ${GREEN}全量接管${PLAIN} — 本机所有节点的全部流量走家宽 (默认，推荐)"
    msg " 2. 按节点接管 — 只让选中的节点走家宽，其余保持直连 (高级)"
    read -r -p "请选择 [回车=1]: " m
    if [ "$m" == "2" ]; then
        select_targets || {
            pause
            return
        }
        mode="selective"
    else
        TARGET_TAGS="[]"
        mode="all"
    fi

    write_isp "$mode" || {
        pause
        return
    }
    warn "正在应用配置并重启 sing-box ..."
    if apply_isp; then
        ok "家宽流量接管已开启！"
        echo ""
        status_body
    else
        err "应用失败，配置已回滚 (isp.json 已保留，可修正后重试)。"
    fi
    pause
}

switch_mode() {
    clear
    line
    echo -e "${CYAN}            切换接管范围                  ${PLAIN}"
    line
    if ! load_existing; then
        err "还没有配置家宽节点，请先执行「开启家宽接管」。"
        pause
        return
    fi
    local cur m mode
    cur=$(jq -r '.mode // "all"' "$ISP_FILE")
    msg "当前范围：$([ "$cur" == "all" ] && echo "${GREEN}全量接管${PLAIN}" || echo "${YELLOW}按节点接管${PLAIN}")"
    echo ""
    msg " 1. 全量接管 — 所有节点流量走家宽"
    msg " 2. 按节点接管 — 重新选择要走家宽的节点"
    msg " 0. 返回"
    read -r -p "请选择: " m
    case "$m" in
        1)
            TARGET_TAGS="[]"
            mode="all"
            ;;
        2)
            select_targets || {
                pause
                return
            }
            mode="selective"
            ;;
        *) return ;;
    esac
    write_isp "$mode" || {
        pause
        return
    }
    warn "正在应用配置并重启 sing-box ..."
    if apply_isp; then
        ok "接管范围已切换为：$mode"
        echo ""
        status_body
    else
        err "应用失败，配置已回滚。"
    fi
    pause
}

clean_config_direct() {   # 没有 nodes.json 的老部署：把家宽相关内容从 config.json 摘掉
    [ -f "$CONFIG_FILE" ] || return 0
    local tmp bak
    tmp=$(mktemp)
    bak="${CONFIG_FILE}.bak_$(date +%s)"
    jq --arg tag "$ISP_TAG" '
        .outbounds = [ (.outbounds // [])[]
            | select( ((.tag // "") != $tag) and (((.tag // "") | startswith($tag + "-")) | not) ) ]
        | .outbounds = (if ([ .outbounds[] | select(.type == "direct") ] | length) == 0
                        then .outbounds + [{type:"direct", tag:"direct"}] else .outbounds end)
        | if .route then
              .route.rules = [ ((.route.rules // [])[]) | select((.outbound // "") != $tag) ]
              | .route.final = (if (.route.final // "") == $tag then "direct" else (.route.final // "direct") end)
          else . end
    ' "$CONFIG_FILE" >"$tmp" 2>/dev/null || {
        rm -f "$tmp"
        err "config.json 解析失败。"
        return 1
    }
    cp -f "$CONFIG_FILE" "$bak"
    mv -f "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    if ! "$(sb_bin)" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        mv -f "$bak" "$CONFIG_FILE"
        err "生成的配置未通过校验，已回滚。"
        return 1
    fi
    systemctl restart sing-box >/dev/null 2>&1
    sleep 1
    rm -f "$bak"
    return 0
}

disable_takeover() {
    clear
    line
    echo -e "${CYAN}            关闭家宽接管                  ${PLAIN}"
    line
    if [ ! -f "$ISP_FILE" ] && [ -f "$CONFIG_FILE" ] &&
        ! jq -e --arg t "$ISP_TAG" '((.route.final // "") == $t) or ([(.route.rules // [])[] | select((.outbound // "") == $t)] | length > 0)' \
            "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "当前没有检测到家宽接管配置。"
        pause
        return
    fi
    local c
    read -r -p "确认关闭并恢复为直连出站？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    rm -f "$ISP_FILE"
    warn "正在恢复配置 ..."
    local rc=0
    if [ "$HAVE_CORE" == "1" ] && [ -f "$NODES_FILE" ]; then
        apply_config || rc=1
    else
        clean_config_direct || rc=1
    fi
    if [ "$rc" == "0" ]; then
        ok "家宽接管已关闭，流量恢复本机直出。"
    else
        err "恢复失败，请检查 sing-box 日志：journalctl -u sing-box -n 50"
    fi
    pause
}

test_conn() {
    clear
    line
    echo -e "${CYAN}          家宽落地连通性测试              ${PLAIN}"
    line
    if ! load_existing; then
        err "还没有配置家宽节点。"
        pause
        return
    fi
    local host port typ
    host=$(jq -r '.info.server // ""' "$ISP_FILE")
    port=$(jq -r '.info.port // ""' "$ISP_FILE")
    typ=$(jq -r '.info.type // "-"' "$ISP_FILE")
    if [ -z "$host" ] || [ -z "$port" ]; then
        warn "isp.json 里没有记录落地地址，跳过端口探测。"
    else
        msg "落地节点：${GREEN}${typ}${PLAIN}  ${host}:${port}"
        case "$typ" in
            hysteria | hysteria2 | tuic)
                warn "该协议基于 UDP/QUIC，无法用 TCP 探测端口，请直接看下方出口 IP 结果。"
                ;;
            *)
                if timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
                    ok "TCP ${host}:${port} 可达"
                else
                    err "TCP ${host}:${port} 不可达 (可能是家宽端口未转发 / 防火墙 / 协议为 UDP)"
                fi
                ;;
        esac
    fi
    echo ""
    local myip out
    myip=$(exit_ip_via direct || echo "查询失败")
    msg "本机直连出口 IP：${YELLOW}${myip}${PLAIN}"
    warn "正在把流量真的灌进落地出站实测 (最多 ${ISP_PROBE_TIMEOUT:-10}s) ..."
    probe_landing
    case "$?" in
        0)
            ok "落地实测可用，经落地看到的出口 IP：${GREEN}${LAND_IP:-未知}${PLAIN}"
            if [ -n "$LAND_IP" ] && [ "$LAND_IP" == "$myip" ]; then
                warn "经落地的出口 IP 和本机直连一样，检查落地是不是又把流量转回了 VPS。"
            fi
            ;;
        2) warn "无法实测 (${LAND_MSG})" ;;
        *)
            err "落地实测不通 (${LAND_MSG}) —— 被接管的节点现在必然全部连不上 (客户端表现为 -1)"
            landing_hint
            ;;
    esac
    echo ""
    if systemctl is-active --quiet sing-box; then
        ok "sing-box 服务运行中"
    else
        err "sing-box 未运行：journalctl -u sing-box -n 50"
    fi
    out=$(jq -r '.route.final // "-"' "$CONFIG_FILE" 2>/dev/null)
    msg "当前 route.final = ${GREEN}${out}${PLAIN}"
    line
    pause
}

show_menu() {
    clear
    local st
    if [ -f "$ISP_FILE" ] && jq -e '.enabled == true' "$ISP_FILE" >/dev/null 2>&1; then
        if [ "$(jq -r '.mode // "all"' "$ISP_FILE")" == "all" ]; then
            st="${GREEN}已开启 · 全量接管${PLAIN}"
        else
            st="${GREEN}已开启 · 按节点接管${PLAIN}"
        fi
    else
        st="${YELLOW}未开启${PLAIN}"
    fi
    line
    echo -e "${CYAN}        Sing-box 家宽流量接管 (ISP)       ${PLAIN}"
    line
    echo -e " 状态：${st}"
    echo -e " 说明：把本机节点的流量转发到家宽落地机出网"
    line
    msg " ${GREEN}1.${PLAIN} 开启 / 重新配置家宽接管"
    msg " ${GREEN}2.${PLAIN} 查看当前状态"
    msg " ${GREEN}3.${PLAIN} 切换接管范围 (全量 ↔ 按节点)"
    msg " ${GREEN}4.${PLAIN} 连通性测试"
    msg " ${GREEN}5.${PLAIN} 关闭家宽接管"
    msg " ${GREEN}0.${PLAIN} 退出"
    line
}

isp_main() {
    local c
    isp_preflight
    while true; do
        show_menu
        read -r -p "请输入选项 [0-5]: " c
        case "$c" in
            1) enable_takeover ;;
            2) view_status ;;
            3) switch_mode ;;
            4) test_conn ;;
            5) disable_takeover ;;
            0)
                clear
                exit 0
                ;;
            *)
                err "无效选项"
                sleep 1
                ;;
        esac
    done
}

# SBA_ISP_SOURCE_ONLY=1 时只加载函数，供测试使用
[ "${SBA_ISP_SOURCE_ONLY:-0}" == "1" ] || isp_main "$@"
