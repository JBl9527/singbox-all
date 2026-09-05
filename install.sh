#!/bin/bash

# ==========================================
# Sing-box 全协议一键管理脚本 (SBA v2)
#
# 覆盖 sing-box 能对外提供的全部代理协议节点:
#   VLESS / VMess / Trojan (REALITY、TLS、WS、gRPC、HTTPUpgrade、明文)
#   AnyTLS / AnyTLS-REALITY / Hysteria2 / Hysteria v1 / TUIC v5
#   Shadowsocks 2022 / Shadowsocks / ShadowTLS v3 / Snell / NaiveProxy
#   SOCKS5 / HTTP / Mixed
#   Argo (Cloudflare Tunnel) 免域名节点
#
# 数据源: /usr/local/etc/sing-box/nodes.json
#   config.json 每次由 nodes.json + isp.json 重新生成，
#   因此家宽接管配置不会因为重装/改参数而丢失。
#
# GitHub 直连不通时先执行：
#   export GH_PROXY="https://你的加速前缀/"
# 再运行本脚本。
# ==========================================

SBA_VERSION="2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"
CONFIG_FILE="${CONFIG_DIR}/config.json"
NODES_FILE="${CONFIG_DIR}/nodes.json"
ISP_FILE="${CONFIG_DIR}/isp.json"
ARGO_FILE="${CONFIG_DIR}/argo.json"
CONF_FILE="${CONFIG_DIR}/sba.conf"
EXTRA_NODES_FILE="${CONFIG_DIR}/extra_nodes.conf"

SING_BOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
ARGO_SERVICE_FILE="/etc/systemd/system/sba-argo.service"
ARGO_LOG="/var/log/sba-argo.log"

GH_PROXY="${GH_PROXY:-}"
[ -n "$GH_PROXY" ] && [[ "$GH_PROXY" != */ ]] && GH_PROXY="${GH_PROXY}/"

REPO_RAW="${GH_PROXY}https://raw.githubusercontent.com/JBl9527/singbox-all/main"
SB_REPO="SagerNet/sing-box"
SB_FALLBACK_VERSION="1.14.0"

DEFAULT_REALITY_DEST="addons.mozilla.org"
DEFAULT_PADDING='["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"]'

CURL_OPTS=(-fsSL --connect-timeout 8 --max-time 30)
PUBLIC_IP=""
PUBLIC_IP6=""

# ==========================================
# 协议注册表
#   key | 显示名 | 加密方式(none/tls/reality) | 传输(tcp/ws/grpc/hu/-) | 旧版兼容 tag
# ==========================================
PROTO_DB=(
    "vless-reality|VLESS + REALITY + Vision|reality|tcp|reality-in"
    "vless-reality-grpc|VLESS + REALITY + gRPC|reality|grpc|"
    "vless-tcp-tls|VLESS + TCP + TLS|tls|tcp|"
    "vless-ws-tls|VLESS + WS + TLS|tls|ws|"
    "vless-grpc-tls|VLESS + gRPC + TLS|tls|grpc|"
    "vless-hu-tls|VLESS + HTTPUpgrade + TLS|tls|hu|"
    "vless-ws|VLESS + WS 明文 (套 CDN 用)|none|ws|"
    "vmess-reality|VMess + REALITY|reality|tcp|"
    "vmess-tcp|VMess + TCP 明文|none|tcp|"
    "vmess-tcp-tls|VMess + TCP + TLS|tls|tcp|"
    "vmess-ws|VMess + WS 明文 (套 CDN 用)|none|ws|"
    "vmess-ws-tls|VMess + WS + TLS|tls|ws|"
    "vmess-grpc-tls|VMess + gRPC + TLS|tls|grpc|"
    "trojan-reality|Trojan + REALITY|reality|tcp|"
    "trojan-tcp-tls|Trojan + TCP + TLS|tls|tcp|"
    "trojan-ws-tls|Trojan + WS + TLS|tls|ws|"
    "trojan-grpc-tls|Trojan + gRPC + TLS|tls|grpc|"
    "anytls|AnyTLS|tls|-|anytls-in"
    "anytls-reality|AnyTLS + REALITY|reality|-|any-reality-in"
    "hysteria2|Hysteria2 (含端口跳跃)|tls|-|hy2-in"
    "hysteria|Hysteria v1|tls|-|"
    "tuic|TUIC v5|tls|-|tuic-in"
    "shadowtls|ShadowTLS v3 + SS2022|none|-|"
    "ss-2022|Shadowsocks 2022|none|-|"
    "ss-aes|Shadowsocks aes-256-gcm|none|-|"
    "snell|Snell v5|none|-|"
    "naive|NaiveProxy (需真实证书)|tls|-|"
    "socks5|SOCKS5|none|-|"
    "http|HTTP 代理|none|-|"
    "mixed|Mixed (SOCKS5 + HTTP)|none|-|"
)

[[ $EUID -ne 0 && "${SBA_SOURCE_ONLY:-0}" != "1" ]] && {
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
}

# ================= 基础小工具 =================

msg() { echo -e "$1"; }
ok() { echo -e "${GREEN}✔ $1${PLAIN}"; }
warn() { echo -e "${YELLOW}! $1${PLAIN}"; }
err() { echo -e "${RED}✘ $1${PLAIN}"; }
line() { echo -e "${CYAN}------------------------------------------${PLAIN}"; }

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键继续..." || true
    echo ""
}

proto_field() {
    # $1=key $2=字段序号(2显示名 3加密 4传输 5旧tag)
    local e
    for e in "${PROTO_DB[@]}"; do
        [ "${e%%|*}" == "$1" ] && {
            echo "$e" | cut -d'|' -f"$2"
            return 0
        }
    done
    return 1
}

proto_label() { proto_field "$1" 2; }
proto_tls() { proto_field "$1" 3; }
proto_trans() { proto_field "$1" 4; }
proto_legacy_tag() { proto_field "$1" 5; }

proto_exists() { proto_field "$1" 1 >/dev/null 2>&1; }

proto_keys() {
    local e
    for e in "${PROTO_DB[@]}"; do echo "${e%%|*}"; done
}

default_tag() {
    local lt
    lt=$(proto_legacy_tag "$1")
    [ -n "$lt" ] && { echo "$lt"; return 0; }
    echo "$1-in"
}

pkg_install() {
    local pm=""
    command -v apt-get >/dev/null 2>&1 && pm="apt"
    [ -z "$pm" ] && command -v dnf >/dev/null 2>&1 && pm="dnf"
    [ -z "$pm" ] && command -v yum >/dev/null 2>&1 && pm="yum"
    [ -z "$pm" ] && command -v apk >/dev/null 2>&1 && pm="apk"

    case "$pm" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
            ;;
        dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
        yum) yum install -y "$@" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
        *)
            err "未识别的包管理器，请手动安装: $*"
            return 1
            ;;
    esac
}

check_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v tar >/dev/null 2>&1 || missing+=(tar)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)

    if [ ${#missing[@]} -gt 0 ]; then
        warn "安装依赖: ${missing[*]} ..."
        pkg_install "${missing[@]}" || true
    fi

    local fatal=()
    command -v curl >/dev/null 2>&1 || fatal+=(curl)
    command -v jq >/dev/null 2>&1 || fatal+=(jq)
    command -v openssl >/dev/null 2>&1 || fatal+=(openssl)

    if [ ${#fatal[@]} -gt 0 ]; then
        err "缺少关键依赖: ${fatal[*]}，请手动安装后重试。"
        return 1
    fi
    return 0
}

b64_encode() {
    printf '%s' "$1" | base64 -w 0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'
}

b64_url() {
    b64_encode "$1" | tr '+/' '-_' | tr -d '='
}

urlenc() {
    local s="$1" out="" i c
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

rand_str() {
    local n="${1:-8}"
    tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c "$n"
}

rand_hex() {
    openssl rand -hex "${1:-4}" 2>/dev/null | tr -d '\n'
}

gen_uuid() {
    if [ -x "$SING_BOX_BIN" ]; then
        "$SING_BOX_BIN" generate uuid 2>/dev/null && return 0
    fi
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null
}

gen_pass() { rand_hex "${1:-12}"; }

gen_ss_key() {
    if [ -x "$SING_BOX_BIN" ]; then
        "$SING_BOX_BIN" generate rand --base64 "${1:-16}" 2>/dev/null && return 0
    fi
    openssl rand -base64 "${1:-16}" 2>/dev/null | tr -d '\n'
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_range() {
    [[ "$1" =~ ^([0-9]+):([0-9]+)$ ]] || return 1
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    valid_port "$a" && valid_port "$b" && [ "$a" -lt "$b" ]
}

valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.' p
    read -ra p <<<"$1"
    for i in "${p[@]}"; do [ "$i" -le 255 ] || return 1; done
    return 0
}

port_in_use() {
    ss -lnutH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"
}

used_ports() {
    # nodes.json 中已占用的端口 + 端口跳跃区间起止
    [ -f "$NODES_FILE" ] || return 0
    jq -r '.nodes[]? | (.port|tostring), (if (.hop//"")!="" then (.hop|split(":")|.[]) else empty end)' \
        "$NODES_FILE" 2>/dev/null
}

pick_port() {
    # 随机取一个未被占用端口 (可选段: $1=起 $2=止)
    local lo="${1:-20000}" hi="${2:-60000}" p tries=0 taken
    taken=$(used_ports | tr '\n' ' ')
    while [ $tries -lt 200 ]; do
        p=$((RANDOM % (hi - lo) + lo))
        tries=$((tries + 1))
        [[ " $taken " == *" $p "* ]] && continue
        port_in_use "$p" && continue
        echo "$p"
        return 0
    done
    echo "$((RANDOM % 20000 + 30000))"
}

ask_port() {
    # $1=提示 $2=默认值 -> 结果写入 ASK_PORT
    local tip="$1" def="$2" input
    while true; do
        read -r -p "${tip} [回车=${def}]: " input
        input="${input:-$def}"
        if ! valid_port "$input"; then
            err "端口不合法"
            continue
        fi
        if [ "$input" != "$def" ] && port_in_use "$input"; then
            warn "端口 $input 已被系统占用"
            local c
            read -r -p "仍要使用吗？[y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] || continue
        fi
        ASK_PORT="$input"
        return 0
    done
}

get_public_ip() {
    [ -n "$PUBLIC_IP" ] && return 0
    local url
    for url in ifconfig.me ipv4.icanhazip.com api.ipify.org; do
        PUBLIC_IP=$(curl -s4 --connect-timeout 5 --max-time 8 "https://${url}" 2>/dev/null | tr -d '[:space:]')
        valid_ipv4 "$PUBLIC_IP" && return 0
        PUBLIC_IP=""
    done
    warn "自动获取公网 IPv4 失败。"
    while true; do
        read -r -p "请手动输入本机公网 IP: " PUBLIC_IP
        valid_ipv4 "$PUBLIC_IP" && return 0
        err "IPv4 地址格式不正确"
    done
}

get_public_ip6() {
    [ -n "$PUBLIC_IP6" ] && return 0
    PUBLIC_IP6=$(curl -s6 --connect-timeout 5 --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]')
    [[ "$PUBLIC_IP6" == *:* ]] || PUBLIC_IP6=""
}

check_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo -e "${GREEN}已开启${PLAIN}"
    else
        echo -e "${YELLOW}未开启${PLAIN}"
    fi
}

enable_bbr() {
    clear
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR 已经处于开启状态。"
        pause
        return
    fi
    sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
    } >>/etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR 已开启。"
    else
        err "开启失败，内核可能不支持 BBR (需要 4.9+)。"
    fi
    pause
}

install_shortcut() {
    [ -f /usr/bin/sba ] && return 0
    local self
    self=$(readlink -f "$0" 2>/dev/null)
    if [ -n "$self" ] && [ -f "$self" ] && [[ "$self" != /bin/bash && "$self" != /usr/bin/bash ]]; then
        cp "$self" /usr/bin/sba 2>/dev/null && chmod +x /usr/bin/sba && return 0
    fi
    command -v curl >/dev/null 2>&1 || return 0
    curl "${CURL_OPTS[@]}" -o /usr/bin/sba "${REPO_RAW}/install.sh" 2>/dev/null && chmod +x /usr/bin/sba
    return 0
}

# ================= 内核安装 =================

sys_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        s390x) echo "s390x" ;;
        *) return 1 ;;
    esac
}

resolve_sb_version() {
    # 家宽/CGNAT 上 api.github.com 常被限流 403，所以优先用 releases/latest 的 302 跳转
    local url tag
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 8 --max-time 20 \
        "https://github.com/${SB_REPO}/releases/latest" 2>/dev/null)
    tag="${url##*/tag/}"
    if [[ "$tag" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    tag=$(curl "${CURL_OPTS[@]}" "https://api.github.com/repos/${SB_REPO}/releases/latest" 2>/dev/null |
        jq -r '.tag_name // empty' | sed 's/^v//')
    if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$tag"
        return 0
    fi

    tag=$(curl "${CURL_OPTS[@]}" "https://github.com/${SB_REPO}/releases.atom" 2>/dev/null |
        grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's#.*/v##')
    if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$tag"
        return 0
    fi

    echo "$SB_FALLBACK_VERSION"
}

core_version() {
    [ -x "$SING_BOX_BIN" ] || return 1
    "$SING_BOX_BIN" version 2>/dev/null | awk 'NR==1{print $3}'
}

download_core() {
    local want="${1:-}" arch tmpdir
    arch=$(sys_arch) || {
        err "不支持的 CPU 架构: $(uname -m)"
        return 1
    }

    [ -z "$want" ] && want=$(resolve_sb_version)
    msg "${YELLOW}准备安装 sing-box v${want} (linux-${arch})...${PLAIN}"

    tmpdir=$(mktemp -d) || return 1
    local pkg="sing-box-${want}-linux-${arch}"
    if ! curl "${CURL_OPTS[@]}" --max-time 300 -o "$tmpdir/sb.tgz" \
        "${GH_PROXY}https://github.com/${SB_REPO}/releases/download/v${want}/${pkg}.tar.gz"; then
        err "核心下载失败（可尝试 export GH_PROXY=加速前缀 后重试）。"
        rm -rf "$tmpdir"
        return 1
    fi

    if ! tar -xzf "$tmpdir/sb.tgz" -C "$tmpdir" 2>/dev/null; then
        err "解压失败，安装包可能损坏。"
        rm -rf "$tmpdir"
        return 1
    fi

    if [ ! -x "$tmpdir/$pkg/sing-box" ]; then
        err "压缩包内未找到 sing-box 可执行文件。"
        rm -rf "$tmpdir"
        return 1
    fi

    install -m 755 "$tmpdir/$pkg/sing-box" "${SING_BOX_BIN}.new" || {
        rm -rf "$tmpdir"
        return 1
    }
    mv -f "${SING_BOX_BIN}.new" "$SING_BOX_BIN"
    rm -rf "$tmpdir"
    ok "核心已就绪: $(core_version)"
    return 0
}

update_core() {
    clear
    check_deps || {
        pause
        return
    }
    local cur new
    cur=$(core_version)
    new=$(resolve_sb_version)
    msg "当前核心: ${GREEN}${cur:-未安装}${PLAIN}   最新版本: ${GREEN}${new}${PLAIN}"

    if [ -n "$cur" ] && [ "$cur" == "$new" ]; then
        ok "已是最新版本，无需更新。"
        pause
        return
    fi

    cp -f "$SING_BOX_BIN" "${SING_BOX_BIN}.bak" 2>/dev/null
    if ! download_core "$new"; then
        [ -f "${SING_BOX_BIN}.bak" ] && mv -f "${SING_BOX_BIN}.bak" "$SING_BOX_BIN"
        pause
        return
    fi

    if [ -f "$CONFIG_FILE" ] && ! "$SING_BOX_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        err "新核心校验旧配置失败，正在回滚..."
        [ -f "${SING_BOX_BIN}.bak" ] && mv -f "${SING_BOX_BIN}.bak" "$SING_BOX_BIN"
        systemctl restart sing-box >/dev/null 2>&1
        pause
        return
    fi

    rm -f "${SING_BOX_BIN}.bak"
    systemctl restart sing-box >/dev/null 2>&1
    ok "核心已更新到 $(core_version)"
    pause
}

# ================= 证书 =================

prompt_domain() {
    local d
    while true; do
        read -r -p "请输入域名: " d
        valid_domain "$d" && {
            DOMAIN="$d"
            return 0
        }
        err "域名格式不正确"
    done
}

ask_cert_params() {
    local allow_back="${1:-}"
    while true; do
        msg "1. 生成临时自签证书 (有效期 10 年，无域名也能用，客户端需勾选跳过证书验证)"
        msg "2. 申请永久证书 (Standalone，要求域名已解析到本机且 80 端口空闲)"
        msg "3. 申请永久证书 (Cloudflare DNS API，无需 80 端口)"
        [ -n "$allow_back" ] && msg "0. 返回"
        read -r -p "请输入选项: " CERT_CHOICE
        [ -n "$allow_back" ] && [ "$CERT_CHOICE" == "0" ] && return 1
        case "$CERT_CHOICE" in
            1 | 2 | 3) break ;;
            *) err "无效选项" ;;
        esac
    done

    ACME_EMAIL=""
    CF_EMAIL=""
    CF_KEY=""
    CF_TOKEN=""
    CF_ACCOUNT_ID=""

    case "$CERT_CHOICE" in
        1) DOMAIN="bing.com" ;;
        2)
            prompt_domain
            read -r -p "ACME 注册邮箱 [留空自动生成]: " ACME_EMAIL
            ;;
        3)
            prompt_domain
            local use_token
            read -r -p "使用 CF API Token？(推荐) [Y/n]: " use_token
            if [[ ! "$use_token" =~ ^[Nn]$ ]]; then
                read -r -p "CF API Token: " CF_TOKEN
                read -r -p "CF Account ID (可留空): " CF_ACCOUNT_ID
            else
                read -r -p "CF 账号邮箱: " CF_EMAIL
                read -r -p "CF Global API Key: " CF_KEY
            fi
            ;;
    esac
    return 0
}

install_acme() {
    pkg_install socat cron >/dev/null 2>&1
    if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
        local email="${ACME_EMAIL:-sba_cert_${RANDOM}@gmail.com}"
        warn "安装 acme.sh (注册邮箱: ${email}) ..."
        curl -s --connect-timeout 8 --max-time 180 https://get.acme.sh | sh -s email="$email" || return 1
    fi
    [ -x "$HOME/.acme.sh/acme.sh" ]
}

precheck_standalone() {
    get_public_ip || return 1
    local resolved c
    resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$PUBLIC_IP" ] && [ -n "$resolved" ] && [ "$resolved" != "$PUBLIC_IP" ]; then
        warn "$DOMAIN 解析到 $resolved，与本机 $PUBLIC_IP 不一致，申请可能失败。"
        read -r -p "仍要继续吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return 1
    fi
    if port_in_use 80; then
        warn "80 端口已被占用，Standalone 验证需要 80 端口。"
        read -r -p "仍要继续吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

self_signed_cert() {
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=${1:-bing.com}" >/dev/null 2>&1
}

issue_cert() {
    mkdir -p "$CERT_DIR" || return 1
    case "$CERT_CHOICE" in
        1)
            self_signed_cert "bing.com" || return 1
            ;;
        2 | 3)
            install_acme || {
                err "acme.sh 安装失败"
                return 1
            }
            "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
            if [ "$CERT_CHOICE" == "2" ]; then
                precheck_standalone || return 1
                warn "申请证书 (Standalone) ..."
                "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone -k ec-256 || return 1
            else
                if [ -n "$CF_TOKEN" ]; then
                    export CF_Token="$CF_TOKEN"
                    [ -n "$CF_ACCOUNT_ID" ] && export CF_Account_ID="$CF_ACCOUNT_ID"
                else
                    export CF_Key="$CF_KEY"
                    export CF_Email="$CF_EMAIL"
                fi
                warn "申请证书 (Cloudflare DNS) ..."
                "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" -k ec-256 || return 1
            fi
            "$HOME/.acme.sh/acme.sh" --installcert -d "$DOMAIN" --ecc \
                --fullchain-file "$CERT_DIR/server.crt" \
                --key-file "$CERT_DIR/server.key" \
                --reloadcmd "systemctl restart sing-box >/dev/null 2>&1 || true" || return 1
            ;;
        *)
            err "未知证书类型"
            return 1
            ;;
    esac

    [ -s "$CERT_DIR/server.crt" ] && [ -s "$CERT_DIR/server.key" ] || return 1
    chmod 600 "$CERT_DIR/server.key"
    chmod 644 "$CERT_DIR/server.crt"
    return 0
}

# ================= nodes.json 数据层 =================

nodes_init() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$NODES_FILE" ] && jq -e . "$NODES_FILE" >/dev/null 2>&1 && return 0
    jq -n --argjson pad "$DEFAULT_PADDING" --arg dest "$DEFAULT_REALITY_DEST" '{
        version: 2,
        cert: {choice:"1", domain:"bing.com", acme_email:"", cf_email:"", cf_key:"", cf_token:"", cf_account_id:""},
        reality: {private_key:"", public_key:"", short_id:"", dest:$dest},
        creds: {uuid:"", password:"", ss2022:"", ss_pass:"", snell_psk:"", user:"sba", obfs:"", padding:$pad},
        nodes: []
    }' >"$NODES_FILE" || return 1
    chmod 600 "$NODES_FILE"
}

nj() {
    # 只读查询: nj '<filter>' [jq参数...]
    local f="$1"
    shift
    jq -r "$@" "$f" "$NODES_FILE" 2>/dev/null
}

nj_set() {
    # 原子更新: nj_set '<program>' [jq参数...]
    local prog="$1"
    shift
    local tmp="${NODES_FILE}.tmp"
    jq "$@" "$prog" "$NODES_FILE" >"$tmp" 2>/dev/null || {
        rm -f "$tmp"
        err "写入 nodes.json 失败"
        return 1
    }
    mv -f "$tmp" "$NODES_FILE"
    chmod 600 "$NODES_FILE"
}

node_json_by_tag() {
    jq -c --arg t "$1" '.nodes[] | select(.tag == $t)' "$NODES_FILE" 2>/dev/null
}

node_count() { jq -r '.nodes | length' "$NODES_FILE" 2>/dev/null || echo 0; }

ensure_creds() {
    nodes_init || return 1
    local uuid pass ss2022 sspass psk obfs
    uuid=$(nj '.creds.uuid // ""')
    [ -z "$uuid" ] && uuid=$(gen_uuid)
    pass=$(nj '.creds.password // ""')
    [ -z "$pass" ] && pass=$(gen_pass 12)
    ss2022=$(nj '.creds.ss2022 // ""')
    [ -z "$ss2022" ] && ss2022=$(gen_ss_key 16)
    sspass=$(nj '.creds.ss_pass // ""')
    [ -z "$sspass" ] && sspass=$(gen_pass 12)
    psk=$(nj '.creds.snell_psk // ""')
    [ -z "$psk" ] && psk=$(gen_pass 12)
    obfs=$(nj '.creds.obfs // ""')
    [ -z "$obfs" ] && obfs=$(gen_pass 8)

    nj_set '.creds.uuid=$u | .creds.password=$p | .creds.ss2022=$s2 | .creds.ss_pass=$sp
            | .creds.snell_psk=$psk | .creds.obfs=$obfs
            | .creds.user = (.creds.user // "sba" | if . == "" then "sba" else . end)
            | .creds.padding = (if (.creds.padding // [] | length) > 0 then .creds.padding else $pad end)' \
        --arg u "$uuid" --arg p "$pass" --arg s2 "$ss2022" --arg sp "$sspass" \
        --arg psk "$psk" --arg obfs "$obfs" --argjson pad "$DEFAULT_PADDING"
}

ensure_reality() {
    local priv pub
    priv=$(nj '.reality.private_key // ""')
    pub=$(nj '.reality.public_key // ""')
    if [ -n "$priv" ] && [ -n "$pub" ]; then return 0; fi

    [ -x "$SING_BOX_BIN" ] || {
        err "缺少 sing-box 核心，无法生成 REALITY 密钥。"
        return 1
    }
    local out
    out=$("$SING_BOX_BIN" generate reality-keypair 2>/dev/null)
    priv=$(echo "$out" | awk -F': *' '/PrivateKey/{print $2}')
    pub=$(echo "$out" | awk -F': *' '/PublicKey/{print $2}')
    [ -n "$priv" ] && [ -n "$pub" ] || {
        err "REALITY 密钥生成失败"
        return 1
    }
    nj_set '.reality.private_key=$a | .reality.public_key=$b
            | .reality.short_id = (if (.reality.short_id // "") == "" then $c else .reality.short_id end)
            | .reality.dest = (if (.reality.dest // "") == "" then $d else .reality.dest end)' \
        --arg a "$priv" --arg b "$pub" --arg c "$(rand_hex 4)" --arg d "$DEFAULT_REALITY_DEST"
}

uniq_tag() {
    local base="$1" t n=1
    t="$base"
    while jq -e --arg t "$t" '.nodes[]? | select(.tag == $t)' "$NODES_FILE" >/dev/null 2>&1; do
        n=$((n + 1))
        t="${base}-${n}"
    done
    echo "$t"
}

node_add() {
    # node_add <key> [port] [tag]
    local key="$1" port="${2:-}" tag="${3:-}"
    proto_exists "$key" || {
        err "未知协议: $key"
        return 1
    }
    [ -z "$port" ] && port=$(pick_port)
    [ -z "$tag" ] && tag=$(uniq_tag "$(default_tag "$key")")

    local tlsmode trans sni path svc ver method
    tlsmode=$(proto_tls "$key")
    trans=$(proto_trans "$key")
    sni=""
    path=""
    svc=""
    ver=0
    method=""

    case "$tlsmode" in
        reality) sni=$(nj '.reality.dest // ""') ;;
        tls) sni=$(nj '.cert.domain // ""') ;;
    esac
    [ "$key" == "shadowtls" ] && sni=$(nj '.reality.dest // ""')
    [ -z "$sni" ] && [ "$tlsmode" != "none" ] && sni="$DEFAULT_REALITY_DEST"

    case "$trans" in
        ws | hu) path="/$(rand_str 8)" ;;
        grpc) svc="$(rand_str 8)" ;;
    esac
    [ "$key" == "snell" ] && ver=5
    [ "$key" == "ss-2022" ] && method="2022-blake3-aes-128-gcm"
    [ "$key" == "ss-aes" ] && method="aes-256-gcm"

    nj_set '.nodes += [{key:$k, tag:$t, port:($p|tonumber), enabled:true, sni:$sni,
            path:$path, service_name:$svc, hop:"", version:($v|tonumber), method:$m,
            obfs:"", uuid:"", password:"", remark:""}]' \
        --arg k "$key" --arg t "$tag" --arg p "$port" --arg sni "$sni" \
        --arg path "$path" --arg svc "$svc" --arg v "$ver" --arg m "$method"
}

node_del() {
    nj_set '.nodes = [.nodes[] | select(.tag != $t)]' --arg t "$1"
}

# ================= 入站 JSON 生成 =================

load_state() {
    R_PRIV=$(nj '.reality.private_key // ""')
    R_PUB=$(nj '.reality.public_key // ""')
    R_SID=$(nj '.reality.short_id // ""')
    R_DEST=$(nj '.reality.dest // ""')
    CERT_CHOICE_SAVED=$(nj '.cert.choice // "1"')
    CERT_DOMAIN=$(nj '.cert.domain // ""')
    CR_UUID=$(nj '.creds.uuid // ""')
    CR_PASS=$(nj '.creds.password // ""')
    CR_SS2022=$(nj '.creds.ss2022 // ""')
    CR_SSPASS=$(nj '.creds.ss_pass // ""')
    CR_PSK=$(nj '.creds.snell_psk // ""')
    CR_USER=$(nj '.creds.user // "sba"')
    CR_OBFS=$(nj '.creds.obfs // ""')
    CR_PADDING=$(jq -c '.creds.padding // []' "$NODES_FILE" 2>/dev/null)
    [ -z "$CR_PADDING" ] && CR_PADDING="$DEFAULT_PADDING"
}

tls_block() {
    # $1=none|tls|reality  $2=sni  $3=alpn(逗号分隔,可空)
    case "$1" in
        reality)
            jq -n --arg sni "$2" --arg pk "$R_PRIV" --arg sid "$R_SID" \
                '{enabled:true, server_name:$sni,
                  reality:{enabled:true, handshake:{server:$sni, server_port:443},
                           private_key:$pk, short_id:[$sid]}}'
            ;;
        tls)
            jq -n --arg sni "$2" --arg alpn "$3" --arg c "$CERT_DIR/server.crt" --arg k "$CERT_DIR/server.key" \
                '{enabled:true, server_name:$sni, certificate_path:$c, key_path:$k}
                 + (if $alpn == "" then {} else {alpn:($alpn|split(","))} end)'
            ;;
        *) echo "null" ;;
    esac
}

transport_block() {
    # $1=tcp|ws|grpc|hu|-  $2=path  $3=service_name
    case "$1" in
        ws) jq -n --arg p "$2" '{type:"ws", path:$p, max_early_data:2048, early_data_header_name:"Sec-WebSocket-Protocol"}' ;;
        grpc) jq -n --arg s "$3" '{type:"grpc", service_name:$s}' ;;
        hu) jq -n --arg p "$2" '{type:"httpupgrade", path:$p}' ;;
        *) echo "null" ;;
    esac
}

build_inbound() {
    # 输入: 单个 node 的 JSON；输出: 入站 JSON 数组
    local nj_obj="$1" key tag port sni path svc ver method obfs base tls trans alpn tlsmode transkind
    local n_uuid n_pass n_ss
    key=$(echo "$nj_obj" | jq -r '.key')
    tag=$(echo "$nj_obj" | jq -r '.tag')
    port=$(echo "$nj_obj" | jq -r '.port')
    sni=$(echo "$nj_obj" | jq -r '.sni // ""')
    path=$(echo "$nj_obj" | jq -r '.path // ""')
    svc=$(echo "$nj_obj" | jq -r '.service_name // ""')
    ver=$(echo "$nj_obj" | jq -r '.version // 0')
    method=$(echo "$nj_obj" | jq -r '.method // ""')
    obfs=$(echo "$nj_obj" | jq -r '.obfs // ""')

    # 节点级凭据优先，缺省回落到全局凭据 (便于从旧版逐协议密码迁移)
    n_uuid=$(echo "$nj_obj" | jq -r '.uuid // ""')
    [ -z "$n_uuid" ] && n_uuid="$CR_UUID"
    n_pass=$(echo "$nj_obj" | jq -r '.password // ""')
    [ -z "$n_pass" ] && n_pass="$CR_PASS"
    n_ss=$(echo "$nj_obj" | jq -r '.password // ""')
    if [ -z "$n_ss" ]; then
        case "$key" in
            ss-2022 | shadowtls) n_ss="$CR_SS2022" ;;
            ss-aes) n_ss="$CR_SSPASS" ;;
            snell) n_ss="$CR_PSK" ;;
        esac
    fi

    tlsmode=$(proto_tls "$key")
    transkind=$(proto_trans "$key")
    alpn=""
    case "$key" in
        hysteria2 | hysteria | tuic) alpn="h3" ;;
        naive) alpn="h2,http/1.1" ;;
    esac
    [ "$tlsmode" == "tls" ] && [ -z "$sni" ] && sni="${CERT_DOMAIN:-bing.com}"
    [ "$tlsmode" == "reality" ] && [ -z "$sni" ] && sni="${R_DEST:-$DEFAULT_REALITY_DEST}"

    tls=$(tls_block "$tlsmode" "$sni" "$alpn")
    trans=$(transport_block "$transkind" "$path" "$svc")

    case "$key" in
        vless-reality)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$n_uuid" \
                '{type:"vless", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{uuid:$u, flow:"xtls-rprx-vision", name:"sba"}]}')
            ;;
        vless-*)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$n_uuid" \
                '{type:"vless", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{uuid:$u, name:"sba"}]}')
            ;;
        vmess-*)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$n_uuid" \
                '{type:"vmess", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{uuid:$u, alterId:0, name:"sba"}]}')
            ;;
        trojan-*)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$n_pass" \
                '{type:"trojan", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{password:$pw, name:"sba"}]}')
            ;;
        anytls | anytls-reality)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$n_pass" --argjson pad "$CR_PADDING" \
                '{type:"anytls", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{password:$pw, name:"sba"}], padding_scheme:$pad}')
            ;;
        hysteria2)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$n_pass" --arg ob "$obfs" --arg obpw "$CR_OBFS" \
                '{type:"hysteria2", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{password:$pw, name:"sba"}]}
                 + (if $ob == "" then {} else {obfs:{type:$ob, password:$obpw}} end)')
            ;;
        hysteria)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg pw "$n_pass" \
                '{type:"hysteria", tag:$t, listen:"::", listen_port:($p|tonumber),
                  up_mbps:100, down_mbps:500, users:[{auth_str:$pw, name:"sba"}]}')
            ;;
        tuic)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$n_uuid" --arg pw "$n_pass" \
                '{type:"tuic", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{uuid:$u, password:$pw, name:"sba"}], congestion_control:"bbr"}')
            ;;
        ss-2022)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg m "${method:-2022-blake3-aes-128-gcm}" --arg pw "$n_ss" \
                '{type:"shadowsocks", tag:$t, listen:"::", listen_port:($p|tonumber), method:$m, password:$pw}')
            ;;
        ss-aes)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg m "${method:-aes-256-gcm}" --arg pw "$n_ss" \
                '{type:"shadowsocks", tag:$t, listen:"::", listen_port:($p|tonumber), method:$m, password:$pw}')
            ;;
        shadowtls)
            jq -n --arg t "$tag" --arg p "$port" --arg sni "${sni:-$DEFAULT_REALITY_DEST}" \
                --arg pw "$n_ss" --arg u "$CR_USER" \
                '[{type:"shadowtls", tag:$t, listen:"::", listen_port:($p|tonumber), version:3,
                   users:[{name:$u, password:$pw}],
                   handshake:{server:$sni, server_port:443}, strict_mode:true,
                   detour:($t + "-ss")},
                  {type:"shadowsocks", tag:($t + "-ss"),
                   method:"2022-blake3-aes-128-gcm", password:$pw}]'
            return 0
            ;;
        snell)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg psk "$n_ss" --arg v "${ver:-5}" \
                '{type:"snell", tag:$t, listen:"::", listen_port:($p|tonumber), psk:$psk, version:($v|tonumber)}
                 + (if ($v|tonumber) == 6 then {mode:"default"} else {obfs_mode:"none"} end)')
            ;;
        naive)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$CR_USER" --arg pw "$n_pass" \
                '{type:"naive", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{username:$u, password:$pw}]}')
            ;;
        socks5)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$CR_USER" --arg pw "$n_pass" \
                '{type:"socks", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{username:$u, password:$pw}]}')
            ;;
        http)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$CR_USER" --arg pw "$n_pass" \
                '{type:"http", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{username:$u, password:$pw}]}')
            ;;
        mixed)
            base=$(jq -n --arg t "$tag" --arg p "$port" --arg u "$CR_USER" --arg pw "$n_pass" \
                '{type:"mixed", tag:$t, listen:"::", listen_port:($p|tonumber),
                  users:[{username:$u, password:$pw}]}')
            ;;
        *)
            err "无法生成未知协议的入站: $key"
            echo "[]"
            return 1
            ;;
    esac

    # listen_local=true 的节点只监听回环 (Argo 后端等，避免明文端口暴露到公网)
    local lo
    lo=$(echo "$nj_obj" | jq -r '.listen_local // false')
    jq -n --argjson base "$base" --argjson tls "$tls" --argjson trans "$trans" --arg lo "$lo" \
        '[$base
          + (if $tls == null then {} else {tls:$tls} end)
          + (if $trans == null then {} else {transport:$trans} end)
          + (if $lo == "true" then {listen:"127.0.0.1"} else {} end)]'
}

# ================= config.json 生成 =================

isp_summary() {
    [ -f "$ISP_FILE" ] || return 1
    jq -e '.enabled == true' "$ISP_FILE" >/dev/null 2>&1 || return 1
    local mode tag info
    mode=$(jq -r '.mode // "all"' "$ISP_FILE")
    tag=$(jq -r '.tag // "Residential-ISP-Node"' "$ISP_FILE")
    info=$(jq -r '(.info.type // "?") + " " + (.info.server // "?") + ":" + ((.info.port // 0)|tostring)' "$ISP_FILE")
    if [ "$mode" == "all" ]; then
        echo -e "${GREEN}全量接管${PLAIN} → ${info}"
    else
        local n
        n=$(jq -r '(.targets.tags // []) | length' "$ISP_FILE")
        echo -e "${YELLOW}按节点接管 (${n} 个)${PLAIN} → ${info}"
    fi
}

generate_config_json() {
    nodes_init || return 1
    load_state

    local parts inbounds cfg tmp
    parts=$(mktemp) || return 1
    while IFS= read -r obj; do
        [ -z "$obj" ] && continue
        build_inbound "$obj" >>"$parts" || {
            rm -f "$parts"
            return 1
        }
    done < <(jq -c '.nodes[]? | select(.enabled != false)' "$NODES_FILE")

    inbounds=$(jq -s 'add // []' "$parts" 2>/dev/null)
    rm -f "$parts"
    [ -z "$inbounds" ] && inbounds="[]"

    cfg=$(jq -n --argjson ib "$inbounds" '{
        log: {level:"info", timestamp:true},
        inbounds: $ib,
        outbounds: [{type:"direct", tag:"direct"}],
        route: {rules: [], final:"direct"}
    }')

    if [ -f "$ISP_FILE" ] && jq -e '.enabled == true' "$ISP_FILE" >/dev/null 2>&1; then
        cfg=$(echo "$cfg" | jq --slurpfile isp "$ISP_FILE" '
            ($isp[0]) as $i
            | ($i.tag // "Residential-ISP-Node") as $t
            | .outbounds = ((.outbounds // []) + ($i.outbounds // []))
            | if ($i.mode // "all") == "all"
              then .route.final = $t
              else .route.rules = ((if (($i.targets.tags // []) | length) > 0
                                    then [{inbound: $i.targets.tags, outbound: $t}]
                                    else [] end) + (.route.rules // []))
              end')
    fi

    mkdir -p "$CONFIG_DIR"
    tmp="${CONFIG_FILE}.tmp"
    printf '%s\n' "$cfg" | jq . >"$tmp" 2>/dev/null || {
        err "生成 config.json 失败"
        rm -f "$tmp"
        return 1
    }

    if [ -x "$SING_BOX_BIN" ]; then
        local out
        out=$("$SING_BOX_BIN" check -c "$tmp" 2>&1)
        if [ -n "$out" ]; then
            err "生成的配置未通过 sing-box 校验，已放弃写入："
            echo "$out" | head -5
            rm -f "$tmp"
            return 1
        fi
    fi

    [ -f "$CONFIG_FILE" ] && cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    mv -f "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    return 0
}

configure_systemd() {
    local ipt ip6t start_lines="" stop_lines="" hop_pairs
    ipt=$(command -v iptables 2>/dev/null || echo /usr/sbin/iptables)
    ip6t=$(command -v ip6tables 2>/dev/null || echo /usr/sbin/ip6tables)

    # Hysteria2 端口跳跃: 把区间内的 UDP 全部 REDIRECT 到监听端口
    hop_pairs=$(jq -r '.nodes[]? | select((.hop // "") != "") | "\(.hop) \(.port)"' "$NODES_FILE" 2>/dev/null)
    while read -r rng p; do
        [ -z "$rng" ] && continue
        start_lines+="ExecStartPost=-${ipt} -t nat -A PREROUTING -p udp --dport ${rng} -j REDIRECT --to-ports ${p}"$'\n'
        start_lines+="ExecStartPost=-${ip6t} -t nat -A PREROUTING -p udp --dport ${rng} -j REDIRECT --to-ports ${p}"$'\n'
        stop_lines+="ExecStopPost=-${ipt} -t nat -D PREROUTING -p udp --dport ${rng} -j REDIRECT --to-ports ${p}"$'\n'
        stop_lines+="ExecStopPost=-${ip6t} -t nat -D PREROUTING -p udp --dport ${rng} -j REDIRECT --to-ports ${p}"$'\n'
    done <<<"$hop_pairs"

    cat >"$SERVICE_FILE" <<EOF_SB
[Unit]
Description=Sing-box Service (SBA)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${SING_BOX_BIN} run -c ${CONFIG_FILE}
${start_lines}${stop_lines}Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_SB

    systemctl daemon-reload || return 1
    systemctl enable sing-box >/dev/null 2>&1 || true
    return 0
}

apply_config() {
    # 重新生成配置并重启服务；失败时自动回滚
    generate_config_json || return 1
    configure_systemd || return 1

    systemctl restart sing-box >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        ok "配置已生效 (节点 $(node_count) 个)"
        return 0
    fi

    err "sing-box 启动失败，最近日志："
    journalctl -u sing-box -n 15 --no-pager 2>/dev/null | tail -15
    if [ -f "${CONFIG_FILE}.bak" ]; then
        warn "正在回滚到上一次可用配置..."
        mv -f "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        systemctl restart sing-box >/dev/null 2>&1
    fi
    return 1
}

service_state() {
    if [ ! -f "$NODES_FILE" ]; then
        echo -e "${YELLOW}未安装${PLAIN}"
    elif systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}已安装但未运行${PLAIN}"
    fi
}

# ================= 旧版 (v1 五协议) 迁移 =================

legacy_present() {
    [ -f "$CONF_FILE" ] && [ ! -f "$NODES_FILE" ]
}

migrate_legacy() {
    # 把 sba.conf + extra_nodes.conf 里的端口/UUID/密码原样搬进 nodes.json，
    # 保留旧 tag，客户端与已有家宽规则都不用改。
    [ -f "$CONF_FILE" ] || return 1
    # shellcheck disable=SC1090
    source "$CONF_FILE" 2>/dev/null || return 1

    nodes_init || return 1
    nj_set '.cert.choice=$cc | .cert.domain=$d | .cert.acme_email=$ae
            | .cert.cf_email=$ce | .cert.cf_key=$ck | .cert.cf_token=$ct | .cert.cf_account_id=$ca
            | .reality.private_key=$rp | .reality.public_key=$rb | .reality.short_id=$rs
            | .reality.dest=(if $rd == "" then $dd else $rd end)
            | .creds.uuid=(if $u == "" then .creds.uuid else $u end)' \
        --arg cc "${CERT_CHOICE:-1}" --arg d "${DOMAIN:-bing.com}" --arg ae "${ACME_EMAIL:-}" \
        --arg ce "${CF_EMAIL:-}" --arg ck "${CF_KEY:-}" --arg ct "${CF_TOKEN:-}" --arg ca "${CF_ACCOUNT_ID:-}" \
        --arg rp "${REALITY_PRIVATE:-}" --arg rb "${REALITY_PUBLIC:-}" --arg rs "${REALITY_SHORT_ID:-}" \
        --arg rd "${REALITY_DEST:-}" --arg dd "$DEFAULT_REALITY_DEST" --arg u "${UUID_REALITY:-}" || return 1

    # 旧版 padding 有两种写法: 完整数组 [..] 或裸列表 "a", "b"
    if [ -n "${PADDING_SCHEME_JSON:-}" ]; then
        local pad_json="$PADDING_SCHEME_JSON"
        jq -e 'type=="array"' <<<"$pad_json" >/dev/null 2>&1 || pad_json="[${PADDING_SCHEME_JSON}]"
        jq -e 'type=="array"' <<<"$pad_json" >/dev/null 2>&1 &&
            nj_set '.creds.padding=$p' --argjson p "$pad_json"
    fi

    legacy_add_node "vless-reality" "reality-in" "${PORT_REALITY:-}" "${UUID_REALITY:-}" "" "${REALITY_DEST:-$DEFAULT_REALITY_DEST}" ""
    legacy_add_node "anytls" "anytls-in" "${PORT_ANYTLS:-}" "" "${PASS_ANYTLS:-}" "${DOMAIN:-bing.com}" ""
    legacy_add_node "anytls-reality" "any-reality-in" "${PORT_ANYREALITY:-}" "" "${PASS_ANYREALITY:-}" "${REALITY_DEST:-$DEFAULT_REALITY_DEST}" ""
    legacy_add_node "hysteria2" "hy2-in" "${PORT_HY2:-}" "" "${PASS_HY2:-}" "${DOMAIN:-bing.com}" "${PORT_HY2_RANGE:-}"
    legacy_add_node "tuic" "tuic-in" "${PORT_TUIC:-}" "${UUID_TUIC:-}" "${PASS_TUIC:-}" "${DOMAIN:-bing.com}" ""
    migrate_legacy_extra
    ok "已从旧版配置迁移 $(node_count) 个节点 (端口/UUID/密码均保持不变)"
}

insert_node() {
    # insert_node <key> <tag> <port> <uuid> <password> <sni> <hop>
    local key="$1" tag="$2" port="$3" uuid="$4" pass="$5" sni="$6" hop="$7"
    proto_exists "$key" || return 1
    valid_port "$port" || return 1
    valid_range "$hop" || hop=""

    local trans path="" svc="" ver=0 method=""
    trans=$(proto_trans "$key")
    case "$trans" in
        ws | hu) path="/$(rand_str 8)" ;;
        grpc) svc="$(rand_str 8)" ;;
    esac
    [ "$key" == "snell" ] && ver=5
    [ "$key" == "ss-2022" ] && method="2022-blake3-aes-128-gcm"
    [ "$key" == "ss-aes" ] && method="aes-256-gcm"
    tag=$(uniq_tag "${tag:-$(default_tag "$key")}")

    nj_set '.nodes += [{key:$k, tag:$t, port:($p|tonumber), enabled:true, sni:$sni,
            path:$path, service_name:$svc, hop:$hop, version:($v|tonumber), method:$m,
            obfs:"", uuid:$u, password:$pw, remark:""}]' \
        --arg k "$key" --arg t "$tag" --arg p "$port" --arg sni "$sni" --arg path "$path" \
        --arg svc "$svc" --arg hop "$hop" --arg v "$ver" --arg m "$method" \
        --arg u "$uuid" --arg pw "$pass"
}

legacy_add_node() { insert_node "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }

migrate_legacy_extra() {
    # extra_nodes.conf: 每行一条 base64，解码后为
    #   proto(1-5) \t port \t sni \t identifier(uuid) \t password
    [ -f "$EXTRA_NODES_FILE" ] || return 0
    local enc rec proto port sni ident pass key
    while IFS= read -r enc; do
        [ -z "${enc// /}" ] && continue
        rec=$(printf '%s' "$enc" | base64 -d 2>/dev/null) || continue
        # 用 awk 按制表符切，避免 read+IFS 把连续制表符(空字段)合并
        proto=$(awk -F'\t' '{print $1}' <<<"$rec")
        port=$(awk -F'\t' '{print $2}' <<<"$rec")
        sni=$(awk -F'\t' '{print $3}' <<<"$rec")
        ident=$(awk -F'\t' '{print $4}' <<<"$rec")
        pass=$(awk -F'\t' '{print $5}' <<<"$rec")
        case "$proto" in
            1) key="vless-reality" ;;
            2) key="anytls" ;;
            3) key="anytls-reality" ;;
            4) key="hysteria2" ;;
            5) key="tuic" ;;
            *) continue ;;
        esac
        # 旧版对只需单一凭据的协议可能把它写在任意一列，这里做一次归位
        case "$key" in
            anytls | anytls-reality | hysteria2)
                [ -z "$pass" ] && {
                    pass="$ident"
                    ident=""
                }
                ;;
            vless-reality)
                [ -z "$ident" ] && {
                    ident="$pass"
                    pass=""
                }
                ;;
        esac
        insert_node "$key" "$(default_tag "$key")" "$port" "$ident" "$pass" "$sni" ""
    done <"$EXTRA_NODES_FILE"
}

SEL_KEYS=()
COMMON_KEYS="vless-reality anytls hysteria2 tuic vmess-ws-tls"

list_protocols() {
    local i=1 k tls trans mark
    for k in $(proto_keys); do
        tls=$(proto_tls "$k")
        trans=$(proto_trans "$k")
        mark=""
        [ "$tls" == "tls" ] && mark="${YELLOW}[需证书]${PLAIN}"
        [ "$tls" == "reality" ] && mark="${GREEN}[免证书]${PLAIN}"
        printf " %b%2d%b) %-34b %b\n" "$GREEN" "$i" "$PLAIN" "$(proto_label "$k")" "$mark"
        i=$((i + 1))
    done
}

expand_sel() {
    # 把 "1,3 5-8" 展开成 "1 3 5 6 7 8"
    local raw="${1//,/ }" tok a b i out=""
    for tok in $raw; do
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a="${BASH_REMATCH[1]}"
            b="${BASH_REMATCH[2]}"
            [ "$a" -gt "$b" ] && { i="$a"; a="$b"; b="$i"; }
            for ((i = a; i <= b; i++)); do out="$out $i"; done
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then
            out="$out $tok"
        fi
    done
    echo "$out" | tr ' ' '\n' | grep -v '^$' | awk '!seen[$0]++' | tr '\n' ' '
}

select_protocols() {
    SEL_KEYS=()
    local all=() sel k n
    mapfile -t all < <(proto_keys)
    clear
    line
    echo -e "${CYAN}            选择要安装的节点协议            ${PLAIN}"
    line
    list_protocols
    line
    echo -e " ${GREEN}直接回车${PLAIN} = 全部安装 (共 ${#all[@]} 种，推荐)"
    echo -e " 输入编号   = 只装选中的，支持 ${YELLOW}1 3 5${PLAIN} / ${YELLOW}1-8${PLAIN} / ${YELLOW}1,4-6${PLAIN}"
    echo -e " 输入 ${YELLOW}c${PLAIN}     = 精选常用 5 种 (REALITY / AnyTLS / Hysteria2 / TUIC / VMess-WS)"
    echo ""
    read -rp "请选择 [回车=全部]: " sel
    if [ -z "${sel// /}" ]; then
        SEL_KEYS=("${all[@]}")
    elif [[ "$sel" =~ ^[cC]$ ]]; then
        for k in $COMMON_KEYS; do SEL_KEYS+=("$k"); done
    else
        for n in $(expand_sel "$sel"); do
            [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#all[@]}" ] && SEL_KEYS+=("${all[$((n - 1))]}")
        done
    fi
    [ ${#SEL_KEYS[@]} -eq 0 ] && { err "未选择任何协议"; return 1; }
    ok "已选择 ${#SEL_KEYS[@]} 种协议"
    return 0
}

ensure_core() {
    [ -x "$SING_BOX_BIN" ] && return 0
    download_core
}

save_cert_state() {
    nj_set '.cert.choice=$c | .cert.domain=$d | .cert.acme_email=$ae
            | .cert.cf_email=$ce | .cert.cf_key=$ck | .cert.cf_token=$ct | .cert.cf_account_id=$ca' \
        --arg c "${CERT_CHOICE:-1}" --arg d "${DOMAIN:-bing.com}" --arg ae "${ACME_EMAIL:-}" \
        --arg ce "${CF_EMAIL:-}" --arg ck "${CF_KEY:-}" --arg ct "${CF_TOKEN:-}" --arg ca "${CF_ACCOUNT_ID:-}"
}

ask_reality_dest() {
    local d
    read -r -p "REALITY / ShadowTLS 伪装域名 [回车=${DEFAULT_REALITY_DEST}]: " d
    d="${d:-$DEFAULT_REALITY_DEST}"
    valid_domain "$d" || d="$DEFAULT_REALITY_DEST"
    nj_set '.reality.dest=$d' --arg d "$d"
}

alloc_and_add_nodes() {
    local mode cur p k taken
    line
    msg "端口分配方式："
    msg " 1. 全部随机 (推荐)"
    msg " 2. 从指定起始端口连续分配"
    msg " 3. 逐个手动输入"
    read -r -p "请选择 [回车=1]: " mode
    mode="${mode:-1}"
    if [ "$mode" == "2" ]; then
        ask_port "起始端口" "$(pick_port 20000 50000)"
        cur="$ASK_PORT"
    fi

    for k in "${SEL_KEYS[@]}"; do
        case "$mode" in
            2)
                taken=" $(used_ports | tr '\n' ' ') "
                p="$cur"
                while [ "$p" -le 65535 ] && { [[ "$taken" == *" $p "* ]] || port_in_use "$p"; }; do
                    p=$((p + 1))
                done
                [ "$p" -gt 65535 ] && p=$(pick_port)
                cur=$((p + 1))
                ;;
            3)
                ask_port "$(proto_label "$k") 端口" "$(pick_port)"
                p="$ASK_PORT"
                ;;
            *) p=$(pick_port) ;;
        esac
        node_add "$k" "$p" || warn "$(proto_label "$k") 添加失败，已跳过"
    done
}

ask_hy2_extra() {
    # Hysteria2 端口跳跃 / obfs (仅在选了 hy2 时询问)
    local tags c rng
    mapfile -t tags < <(nj '.nodes[]? | select(.key=="hysteria2") | .tag')
    [ ${#tags[@]} -eq 0 ] && return 0
    line
    read -r -p "为 Hysteria2 开启端口跳跃 (UDP 端口段 REDIRECT)？[y/N]: " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        while true; do
            read -r -p "端口段 (格式 起始:结束，如 30000:31000): " rng
            valid_range "$rng" && break
            err "格式不正确"
        done
        nj_set '.nodes = [.nodes[] | if .key=="hysteria2" then .hop=$r else . end]' --arg r "$rng"
    fi
    read -r -p "为 Hysteria2 开启 salamander 混淆？[y/N]: " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        nj_set '.nodes = [.nodes[] | if .key=="hysteria2" then .obfs="salamander" else . end]'
    fi
    return 0
}

fresh_install() {
    clear
    if [ -f "$NODES_FILE" ]; then
        warn "检测到已有安装 (当前 $(node_count) 个节点)。"
        msg "重新安装会清空现有节点配置 (证书文件保留)。"
        local c
        read -r -p "确认继续？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return
        rm -f "$NODES_FILE"
    fi

    check_deps || {
        pause
        return
    }
    # 先装内核：家宽/CGNAT 下 GitHub 可能不通，避免参数白填一遍
    ensure_core || {
        err "sing-box 内核安装失败，请检查网络后重试。"
        pause
        return
    }

    select_protocols || {
        pause
        return
    }

    nodes_init || {
        pause
        return
    }

    local need_cert=0 k
    for k in "${SEL_KEYS[@]}"; do
        [ "$(proto_tls "$k")" == "tls" ] && need_cert=1
    done

    clear
    line
    echo -e "${CYAN}                 证书配置                 ${PLAIN}"
    line
    if [ "$need_cert" == "1" ]; then
        msg "已选协议中包含需要 TLS 证书的类型。"
        ask_cert_params || return
    else
        msg "已选协议无需 TLS 证书 (仅 REALITY / 无加密)，跳过证书申请。"
        CERT_CHOICE=1
        DOMAIN="bing.com"
    fi
    save_cert_state || return
    ask_reality_dest
    ensure_creds || return
    ensure_reality || return

    alloc_and_add_nodes
    ask_hy2_extra
    [ "$(node_count)" -eq 0 ] && {
        err "没有成功添加任何节点"
        pause
        return
    }

    if [ "$need_cert" == "1" ] || [ ! -s "$CERT_DIR/server.crt" ]; then
        warn "正在准备证书 ..."
        issue_cert || {
            err "证书生成/申请失败。"
            warn "已改用自签证书继续 (客户端需勾选跳过证书验证)。"
            CERT_CHOICE=1
            DOMAIN="bing.com"
            save_cert_state
            nj_set '.nodes = [.nodes[] | if .key|test("-tls$|^hysteria|^tuic$|^anytls$|^naive$") then .sni="bing.com" else . end]'
            issue_cert || {
                err "自签证书也失败了，请检查 openssl 是否可用。"
                pause
                return
            }
        }
        ok "证书就绪：$CERT_DIR/server.crt"
    fi

    apply_config || {
        pause
        return
    }
    install_shortcut
    ok "安装完成！共 $(node_count) 个节点，快捷命令：sba"
    pause
    show_links
}

# ================= 分享链接 =================

link_extract() {
    local o="$1"
    LK_KEY=$(echo "$o" | jq -r '.key')
    LK_TAG=$(echo "$o" | jq -r '.tag')
    LK_PORT=$(echo "$o" | jq -r '.port')
    LK_SNI=$(echo "$o" | jq -r '.sni // ""')
    LK_PATH=$(echo "$o" | jq -r '.path // ""')
    LK_SVC=$(echo "$o" | jq -r '.service_name // ""')
    LK_VER=$(echo "$o" | jq -r '.version // 0')
    LK_METHOD=$(echo "$o" | jq -r '.method // ""')
    LK_OBFS=$(echo "$o" | jq -r '.obfs // ""')
    LK_HOP=$(echo "$o" | jq -r '.hop // ""')
    LK_REMARK=$(echo "$o" | jq -r '.remark // ""')
    LK_TLSMODE=$(proto_tls "$LK_KEY")
    LK_TRANS=$(proto_trans "$LK_KEY")

    LK_UUID=$(echo "$o" | jq -r '.uuid // ""')
    [ -z "$LK_UUID" ] && LK_UUID="$CR_UUID"
    LK_PASS=$(echo "$o" | jq -r '.password // ""')
    [ -z "$LK_PASS" ] && LK_PASS="$CR_PASS"
    LK_SS=$(echo "$o" | jq -r '.password // ""')
    if [ -z "$LK_SS" ]; then
        case "$LK_KEY" in
            ss-2022 | shadowtls) LK_SS="$CR_SS2022" ;;
            ss-aes) LK_SS="$CR_SSPASS" ;;
            snell) LK_SS="$CR_PSK" ;;
        esac
    fi

    LK_INS=0
    [ "${CERT_CHOICE_SAVED:-1}" == "1" ] && LK_INS=1
    if [ "$LK_TLSMODE" == "tls" ] && [ "$LK_INS" == "0" ] && [ -n "$CERT_DOMAIN" ]; then
        LK_ADDR="$CERT_DOMAIN"
    else
        LK_ADDR="${PUBLIC_IP:-127.0.0.1}"
    fi
    LK_NAME="$LK_TAG"
    [ -n "$LK_REMARK" ] && LK_NAME="$LK_REMARK"
}

link_trans_query() {
    # 传输层查询串 (不含前导 &)
    case "$LK_TRANS" in
        ws) echo "type=ws&path=$(urlenc "$LK_PATH")&host=$(urlenc "${LK_SNI:-$LK_ADDR}")" ;;
        grpc) echo "type=grpc&serviceName=$(urlenc "$LK_SVC")&mode=gun" ;;
        hu) echo "type=httpupgrade&path=$(urlenc "$LK_PATH")&host=$(urlenc "${LK_SNI:-$LK_ADDR}")" ;;
        *) echo "type=tcp" ;;
    esac
}

link_sec_query() {
    # 加密层查询串 (不含前导 &)
    case "$LK_TLSMODE" in
        reality)
            echo "security=reality&sni=$(urlenc "$LK_SNI")&fp=chrome&pbk=${R_PUB}&sid=${R_SID}"
            ;;
        tls)
            local q="security=tls&sni=$(urlenc "${LK_SNI:-$LK_ADDR}")&fp=chrome"
            [ "$LK_INS" == "1" ] && q="${q}&allowInsecure=1"
            echo "$q"
            ;;
        *) echo "security=none" ;;
    esac
}

build_link() {
    # 输入: 单个 node JSON；输出: 一行或多行文本 (分享链接 / 参数说明)
    link_extract "$1"
    local q flow="" vm

    # Argo 后端节点不直连，改用 Cloudflare 隧道域名生成链接
    if [ -f "$ARGO_FILE" ] && [ -n "$LK_TAG" ] &&
        [ "$LK_TAG" == "$(jq -r '.node_tag // ""' "$ARGO_FILE" 2>/dev/null)" ]; then
        argo_link
        return 0
    fi

    case "$LK_KEY" in
        vless-*)
            [ "$LK_KEY" == "vless-reality" ] && flow="&flow=xtls-rprx-vision"
            q="$(link_trans_query)&$(link_sec_query)${flow}"
            echo "vless://${LK_UUID}@${LK_ADDR}:${LK_PORT}?${q}#$(urlenc "$LK_NAME")"
            ;;
        vmess-reality)
            # base64 型 vmess 链接无 reality 标准字段，附带 pbk/sid 供 NekoBox 等客户端识别
            vm=$(jq -nc --arg ps "$LK_NAME" --arg add "$LK_ADDR" --arg port "$LK_PORT" \
                --arg id "$LK_UUID" --arg sni "$LK_SNI" --arg pbk "$R_PUB" --arg sid "$R_SID" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto",
                  net:"tcp", type:"none", host:"", path:"", tls:"reality",
                  sni:$sni, alpn:"", fp:"chrome", pbk:$pbk, sid:$sid}')
            echo "vmess://$(b64_encode "$vm")"
            ;;
        vmess-*)
            local net="tcp" host="" vpath="" vtls="" vsni=""
            case "$LK_TRANS" in
                ws)
                    net="ws"
                    vpath="$LK_PATH"
                    host="${LK_SNI:-$LK_ADDR}"
                    ;;
                grpc)
                    net="grpc"
                    vpath="$LK_SVC"
                    ;;
                hu)
                    net="httpupgrade"
                    vpath="$LK_PATH"
                    host="${LK_SNI:-$LK_ADDR}"
                    ;;
            esac
            [ "$LK_TLSMODE" == "tls" ] && {
                vtls="tls"
                vsni="${LK_SNI:-$LK_ADDR}"
            }
            vm=$(jq -nc --arg ps "$LK_NAME" --arg add "$LK_ADDR" --arg port "$LK_PORT" \
                --arg id "$LK_UUID" --arg net "$net" --arg host "$host" --arg path "$vpath" \
                --arg tls "$vtls" --arg sni "$vsni" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto",
                  net:$net, type:"none", host:$host, path:$path, tls:$tls, sni:$sni, fp:"chrome"}')
            echo "vmess://$(b64_encode "$vm")"
            ;;
        trojan-*)
            q="$(link_trans_query)&$(link_sec_query)"
            echo "trojan://$(urlenc "$LK_PASS")@${LK_ADDR}:${LK_PORT}?${q}#$(urlenc "$LK_NAME")"
            ;;
        anytls | anytls-reality)
            q="sni=$(urlenc "$LK_SNI")"
            if [ "$LK_TLSMODE" == "reality" ]; then
                q="${q}&security=reality&pbk=${R_PUB}&sid=${R_SID}&fp=chrome"
            else
                [ "$LK_INS" == "1" ] && q="${q}&insecure=1"
            fi
            echo "anytls://$(urlenc "$LK_PASS")@${LK_ADDR}:${LK_PORT}?${q}#$(urlenc "$LK_NAME")"
            ;;
        hysteria2)
            q="sni=$(urlenc "${LK_SNI:-$LK_ADDR}")"
            [ "$LK_INS" == "1" ] && q="${q}&insecure=1"
            [ -n "$LK_OBFS" ] && q="${q}&obfs=${LK_OBFS}&obfs-password=$(urlenc "$CR_OBFS")"
            [ -n "$LK_HOP" ] && q="${q}&mport=${LK_HOP/:/-}"
            echo "hysteria2://$(urlenc "$LK_PASS")@${LK_ADDR}:${LK_PORT}?${q}#$(urlenc "$LK_NAME")"
            ;;
        hysteria)
            q="protocol=udp&auth=$(urlenc "$LK_PASS")&peer=$(urlenc "${LK_SNI:-$LK_ADDR}")&upmbps=100&downmbps=500&alpn=h3"
            [ "$LK_INS" == "1" ] && q="${q}&insecure=1"
            echo "hysteria://${LK_ADDR}:${LK_PORT}?${q}#$(urlenc "$LK_NAME")"
            ;;
        tuic)
            q="sni=$(urlenc "${LK_SNI:-$LK_ADDR}")&congestion_control=bbr&udp_relay_mode=native&alpn=h3"
            [ "$LK_INS" == "1" ] && q="${q}&allow_insecure=1"
            echo "tuic://${LK_UUID}:$(urlenc "$LK_PASS")@${LK_ADDR}:${LK_PORT}?${q}#$(urlenc "$LK_NAME")"
            ;;
        ss-2022 | ss-aes)
            echo "ss://$(b64_url "${LK_METHOD}:${LK_SS}")@${LK_ADDR}:${LK_PORT}#$(urlenc "$LK_NAME")"
            ;;
        shadowtls)
            q="plugin=$(urlenc "shadow-tls;version=3;host=${LK_SNI};password=${LK_SS}")"
            echo "ss://$(b64_url "2022-blake3-aes-128-gcm:${LK_SS}")@${LK_ADDR}:${LK_PORT}?${q}#$(urlenc "$LK_NAME")"
            ;;
        snell)
            # Snell 无标准分享链接；给出 Surge / Clash 可直接粘的配置行
            # 服务端 v5 的线路协议与 v4 相同，客户端填 version = 4
            echo "# ${LK_NAME} (Snell v${LK_VER} 服务端，客户端 version 填 $([ "$LK_VER" == "6" ] && echo 6 || echo 4))"
            echo "${LK_NAME} = snell, ${LK_ADDR}, ${LK_PORT}, psk=${LK_SS}, version=$([ "$LK_VER" == "6" ] && echo 6 || echo 4), reuse=true"
            ;;
        naive)
            echo "naive+https://$(urlenc "$CR_USER"):$(urlenc "$LK_PASS")@${LK_ADDR}:${LK_PORT}#$(urlenc "$LK_NAME")"
            ;;
        socks5 | mixed)
            echo "socks://$(b64_url "${CR_USER}:${LK_PASS}")@${LK_ADDR}:${LK_PORT}#$(urlenc "$LK_NAME")"
            ;;
        http)
            echo "http://$(urlenc "$CR_USER"):$(urlenc "$LK_PASS")@${LK_ADDR}:${LK_PORT}#$(urlenc "$LK_NAME")"
            ;;
        *)
            echo "# ${LK_TAG}: 暂不支持自动生成分享链接"
            ;;
    esac
}

all_links() {
    local o
    while IFS= read -r o; do
        [ -z "$o" ] && continue
        build_link "$o"
    done < <(jq -c '.nodes[]? | select(.enabled != false)' "$NODES_FILE" 2>/dev/null)
}

uri_links() { all_links | grep -E '^[a-z0-9+.-]+://'; }

save_links_file() {
    local f="${CONFIG_DIR}/links.txt"
    {
        echo "# SBA ${SBA_VERSION} 节点分享链接  生成时间: $(date '+%F %T')"
        all_links
        echo ""
        echo "# 聚合订阅 (Base64)"
        b64_encode "$(uri_links)"
    } >"$f" 2>/dev/null
    chmod 600 "$f" 2>/dev/null
    echo "$f"
}

show_links() {
    [ -f "$NODES_FILE" ] || {
        err "尚未安装，请先执行安装。"
        pause
        return
    }
    load_state
    get_public_ip
    clear
    line
    echo -e "${CYAN}               节点分享链接               ${PLAIN}"
    line
    local i=1 o key tag port
    while IFS= read -r o; do
        [ -z "$o" ] && continue
        key=$(echo "$o" | jq -r '.key')
        tag=$(echo "$o" | jq -r '.tag')
        port=$(echo "$o" | jq -r '.port')
        echo -e "${GREEN}[$i] $(proto_label "$key")${PLAIN} | tag: ${tag} | 端口: ${port}"
        build_link "$o"
        echo ""
        i=$((i + 1))
    done < <(jq -c '.nodes[]? | select(.enabled != false)' "$NODES_FILE" 2>/dev/null)

    [ "$i" == "1" ] && warn "当前没有启用的节点。"
    line
    echo -e "${YELLOW}聚合订阅 (Base64，可直接粘进客户端的「从剪贴板导入」)：${PLAIN}"
    b64_encode "$(uri_links)"
    echo ""
    [ "${CERT_CHOICE_SAVED:-1}" == "1" ] && warn "当前使用自签证书，TLS 类节点需在客户端勾选「跳过证书验证 / allowInsecure」。"
    ok "已保存到 $(save_links_file)"
    line
    local c
    read -r -p "输入节点编号显示二维码，回车返回: " c
    [[ "$c" =~ ^[0-9]+$ ]] && show_qr "$c"
    return 0
}

show_qr() {
    local idx="$1" o link
    o=$(jq -c --argjson n "$((idx - 1))" '[.nodes[]? | select(.enabled != false)] | .[$n] // empty' "$NODES_FILE" 2>/dev/null)
    [ -z "$o" ] && return 0
    link=$(build_link "$o" | grep -E '^[a-z0-9+.-]+://' | head -1)
    [ -z "$link" ] && {
        warn "该协议没有可用的分享链接。"
        pause
        return
    }
    if ! command -v qrencode >/dev/null 2>&1; then
        warn "正在安装 qrencode ..."
        pkg_install qrencode >/dev/null 2>&1
    fi
    clear
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$link"
    else
        err "qrencode 不可用，无法显示二维码。"
    fi
    echo "$link"
    pause
}

# ================= 节点管理 =================

node_table() {
    local i=1 o tag key port en hop st
    echo -e " ${CYAN}编号  标签                    协议                       端口     状态${PLAIN}"
    while IFS= read -r o; do
        [ -z "$o" ] && continue
        tag=$(echo "$o" | jq -r '.tag')
        key=$(echo "$o" | jq -r '.key')
        port=$(echo "$o" | jq -r '.port')
        en=$(echo "$o" | jq -r '.enabled')
        hop=$(echo "$o" | jq -r '.hop // ""')
        [ "$en" == "false" ] && st="${YELLOW}已停用${PLAIN}" || st="${GREEN}启用${PLAIN}"
        [ -n "$hop" ] && port="${port} (${hop})"
        printf " %-5s %-23s %-26s %-8s %b\n" "$i" "$tag" "$(proto_field "$key" 2)" "$port" "$st"
        i=$((i + 1))
    done < <(jq -c '.nodes[]?' "$NODES_FILE" 2>/dev/null)
    [ "$i" == "1" ] && warn " (暂无节点)"
}

pick_node_tag() {
    # $1=提示 -> 结果写入 PICK_TAG
    local tip="$1" n total
    PICK_TAG=""
    total=$(node_count)
    [ "$total" -eq 0 ] && {
        err "当前没有节点"
        return 1
    }
    read -r -p "$tip [1-${total}, 回车取消]: " n
    [ -z "$n" ] && return 1
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$total" ] || {
        err "编号无效"
        return 1
    }
    PICK_TAG=$(jq -r --argjson n "$((n - 1))" '.nodes[$n].tag' "$NODES_FILE")
    [ -n "$PICK_TAG" ] && [ "$PICK_TAG" != "null" ]
}

add_node_flow() {
    clear
    select_protocols || {
        pause
        return
    }
    local need_cert=0 k
    for k in "${SEL_KEYS[@]}"; do
        [ "$(proto_tls "$k")" == "tls" ] && need_cert=1
    done
    if [ "$need_cert" == "1" ] && [ ! -s "$CERT_DIR/server.crt" ]; then
        warn "所选协议需要证书，但当前没有证书，先生成自签证书。"
        CERT_CHOICE=1
        DOMAIN="bing.com"
        save_cert_state
        issue_cert || {
            err "证书生成失败"
            pause
            return
        }
    fi
    ensure_creds || return
    ensure_reality || return
    alloc_and_add_nodes
    apply_config && show_links
}

node_set() {
    # node_set <tag> <jq程序> [jq参数...]
    local t="$1" prog="$2"
    shift 2
    nj_set ".nodes = [.nodes[] | if .tag == \$__t then ($prog) else . end]" --arg __t "$t" "$@"
}

edit_node_flow() {
    local tag key o c v
    clear
    node_table
    pick_node_tag "请选择要修改的节点编号" || {
        pause
        return
    }
    tag="$PICK_TAG"
    o=$(node_json_by_tag "$tag")
    key=$(echo "$o" | jq -r '.key')
    clear
    line
    echo -e " 节点: ${GREEN}${tag}${PLAIN}  ($(proto_label "$key"))"
    line
    msg " 1. 修改端口"
    msg " 2. 修改 SNI / 伪装域名"
    msg " 3. 修改 UUID / 密码"
    msg " 4. 修改 WS / HTTPUpgrade 路径 或 gRPC serviceName"
    msg " 5. 启用 / 停用该节点"
    msg " 6. 设置 Hysteria2 端口跳跃区间"
    msg " 7. 设置备注 (显示在分享链接名称上)"
    msg " 8. 删除该节点"
    msg " 0. 返回"
    read -r -p "请选择: " c
    case "$c" in
        1)
            ask_port "新端口" "$(pick_port)"
            node_set "$tag" '.port = ($v|tonumber)' --arg v "$ASK_PORT" || return
            ;;
        2)
            read -r -p "新 SNI / 伪装域名: " v
            valid_domain "$v" || {
                err "域名格式不正确"
                pause
                return
            }
            node_set "$tag" '.sni = $v' --arg v "$v" || return
            ;;
        3)
            read -r -p "新 UUID (留空跳过): " v
            [ -n "$v" ] && node_set "$tag" '.uuid = $v' --arg v "$v"
            read -r -p "新 密码 / PSK (留空跳过): " v
            [ -n "$v" ] && node_set "$tag" '.password = $v' --arg v "$v"
            ;;
        4)
            read -r -p "新 路径 / serviceName: " v
            [ -z "$v" ] && return
            case "$(proto_trans "$key")" in
                grpc) node_set "$tag" '.service_name = $v' --arg v "${v#/}" ;;
                ws | hu) node_set "$tag" '.path = $v' --arg v "/${v#/}" ;;
                *)
                    warn "该协议没有传输层路径"
                    pause
                    return
                    ;;
            esac
            ;;
        5)
            node_set "$tag" '.enabled = (.enabled | not)' || return
            ;;
        6)
            [ "$key" == "hysteria2" ] || {
                err "端口跳跃仅支持 Hysteria2"
                pause
                return
            }
            read -r -p "端口段 (起始:结束，留空=关闭跳跃): " v
            if [ -z "$v" ]; then
                node_set "$tag" '.hop = ""'
            else
                valid_range "$v" || {
                    err "格式应为 30000:31000"
                    pause
                    return
                }
                node_set "$tag" '.hop = $v' --arg v "$v"
            fi
            ;;
        7)
            read -r -p "备注 (留空清除): " v
            node_set "$tag" '.remark = $v' --arg v "$v" || return
            ;;
        8)
            read -r -p "确认删除节点 ${tag}？[y/N]: " v
            [[ "$v" =~ ^[Yy]$ ]] || return
            node_del "$tag" || return
            ;;
        0 | "") return ;;
        *)
            err "无效选项"
            pause
            return
            ;;
    esac
    apply_config
    pause
}

rotate_creds() {
    local c
    clear
    warn "重置全局凭据后，所有客户端都需要重新导入节点链接。"
    read -r -p "确认重置 UUID / 密码 / SS 密钥 / PSK ？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    read -r -p "同时清除各节点的独立凭据 (旧版迁移遗留的逐协议密码)？[y/N]: " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        nj_set '.nodes = [.nodes[] | .uuid="" | .password=""]' || return
    fi
    nj_set '.creds.uuid="" | .creds.password="" | .creds.ss2022="" | .creds.ss_pass=""
            | .creds.snell_psk="" | .creds.obfs=""' || return
    ensure_creds || return
    apply_config && show_links
}

manage_nodes() {
    [ -f "$NODES_FILE" ] || {
        err "尚未安装，请先执行安装。"
        pause
        return
    }
    while true; do
        clear
        line
        echo -e "${CYAN}                 节点管理                 ${PLAIN}"
        line
        node_table
        line
        msg " 1. 添加节点 (可多选协议)"
        msg " 2. 修改 / 删除节点"
        msg " 3. 查看分享链接与二维码"
        msg " 4. 重置全局 UUID / 密码"
        msg " 5. 重新生成 config.json 并重启"
        msg " 0. 返回主菜单"
        line
        local c
        read -r -p "请输入选项: " c
        case "$c" in
            1) add_node_flow ;;
            2) edit_node_flow ;;
            3) show_links ;;
            4) rotate_creds ;;
            5)
                apply_config
                pause
                ;;
            0 | "") return ;;
            *)
                err "无效选项"
                sleep 1
                ;;
        esac
    done
}

# ================= Argo (Cloudflare Tunnel) =================

argo_asset() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "cloudflared-linux-amd64" ;;
        aarch64 | arm64) echo "cloudflared-linux-arm64" ;;
        armv7l | armv6l) echo "cloudflared-linux-arm" ;;
        i386 | i686) echo "cloudflared-linux-386" ;;
        *) echo "" ;;
    esac
}

install_cloudflared() {
    [ -x "$CLOUDFLARED_BIN" ] && return 0
    local asset url
    asset=$(argo_asset)
    [ -z "$asset" ] && {
        err "不支持的架构: $(uname -m)"
        return 1
    }
    # 直连 releases/latest/download，不走 GitHub API (家宽/CGNAT 下 API 常 403)
    url="${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
    warn "正在下载 cloudflared ..."
    curl "${CURL_OPTS[@]}" -o "${CLOUDFLARED_BIN}.tmp" "$url" || {
        err "cloudflared 下载失败"
        rm -f "${CLOUDFLARED_BIN}.tmp"
        return 1
    }
    chmod +x "${CLOUDFLARED_BIN}.tmp"
    mv -f "${CLOUDFLARED_BIN}.tmp" "$CLOUDFLARED_BIN"
    "$CLOUDFLARED_BIN" --version >/dev/null 2>&1 || {
        err "cloudflared 无法执行"
        return 1
    }
    ok "cloudflared 安装完成：$("$CLOUDFLARED_BIN" --version 2>/dev/null | head -1)"
}

argo_init() {
    [ -f "$ARGO_FILE" ] && jq -e . "$ARGO_FILE" >/dev/null 2>&1 && return 0
    mkdir -p "$CONFIG_DIR"
    jq -n '{enabled:false, mode:"temp", token:"", domain:"", port:0, node_tag:"", path:""}' >"$ARGO_FILE" || return 1
    chmod 600 "$ARGO_FILE"
}

ag() { jq -r "$1" "$ARGO_FILE" 2>/dev/null; }

ag_set() {
    local prog="$1"
    shift
    local tmp="${ARGO_FILE}.tmp"
    jq "$@" "$prog" "$ARGO_FILE" >"$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$ARGO_FILE"
    chmod 600 "$ARGO_FILE"
}

argo_ensure_node() {
    # Argo 后端必须是明文 (CF 隧道到本机走 HTTP)；这里固定用 vmess-ws 明文入站
    local tag port path
    tag=$(ag '.node_tag // ""')
    if [ -n "$tag" ] && [ -n "$(node_json_by_tag "$tag")" ]; then
        port=$(node_json_by_tag "$tag" | jq -r '.port')
        path=$(node_json_by_tag "$tag" | jq -r '.path')
        ag_set '.port=($p|tonumber) | .path=$pa' --arg p "$port" --arg pa "$path" || return 1
        return 0
    fi
    nodes_init || return 1
    ensure_creds || return 1
    port=$(pick_port 20000 60000)
    tag=$(uniq_tag "argo-in")
    insert_node "vmess-ws" "$tag" "$port" "" "" "" "" || return 1
    # Argo 后端只监听本机回环，避免直连暴露明文端口
    node_set "$tag" '.sni = "" | .listen_local = true' || return 1
    path=$(node_json_by_tag "$tag" | jq -r '.path')
    ag_set '.node_tag=$t | .port=($p|tonumber) | .path=$pa' \
        --arg t "$tag" --arg p "$port" --arg pa "$path" || return 1
    ok "已创建 Argo 后端节点: ${tag} (本机 ${port}${path})"
}

argo_service() {
    local mode port token args
    mode=$(ag '.mode // "temp"')
    port=$(ag '.port // 0')
    token=$(ag '.token // ""')
    if [ "$mode" == "token" ]; then
        [ -z "$token" ] && {
            err "缺少 Argo Token"
            return 1
        }
        args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${token}"
    else
        args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --logfile ${ARGO_LOG} --loglevel info --url http://localhost:${port}"
    fi

    cat >"$ARGO_SERVICE_FILE" <<EOF_ARGO
[Unit]
Description=SBA Argo Tunnel (cloudflared)
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} ${args}
Restart=always
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_ARGO
    chmod 600 "$ARGO_SERVICE_FILE"
    systemctl daemon-reload || return 1
    systemctl enable sba-argo >/dev/null 2>&1 || true
    return 0
}

argo_detect_domain() {
    # 临时隧道: 从 cloudflared 日志里抓 trycloudflare 域名
    local i d=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        d=$(grep -ohE '[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | tail -1)
        [ -n "$d" ] && break
        sleep 2
    done
    [ -z "$d" ] && return 1
    ag_set '.domain=$d' --arg d "$d" || return 1
    echo "$d"
}

argo_link() {
    # 用 LK_* (link_extract 设好的) + argo.json 生成 CDN 链接
    local dom vm ip
    dom=$(ag '.domain // ""')
    [ -z "$dom" ] && {
        echo "# ${LK_TAG}: Argo 域名尚未就绪，请稍后在 Argo 菜单中查看"
        return 0
    }
    ip=$(ag '.cdn_ip // ""')
    [ -z "$ip" ] && ip="$dom"
    vm=$(jq -nc --arg ps "Argo-${dom%%.*}" --arg add "$ip" --arg host "$dom" \
        --arg id "$LK_UUID" --arg path "${LK_PATH}?ed=2048" \
        '{v:"2", ps:$ps, add:$add, port:"443", id:$id, aid:"0", scy:"auto",
          net:"ws", type:"none", host:$host, path:$path, tls:"tls", sni:$host, fp:"chrome"}')
    echo "vmess://$(b64_encode "$vm")"
}

argo_apply() {
    install_cloudflared || return 1
    argo_init || return 1
    argo_ensure_node || return 1
    ag_set '.enabled=true' || return 1
    apply_config || return 1
    argo_service || return 1
    : >"$ARGO_LOG" 2>/dev/null
    systemctl restart sba-argo >/dev/null 2>&1
    sleep 3
    if ! systemctl is-active --quiet sba-argo 2>/dev/null; then
        err "cloudflared 启动失败，最近日志："
        journalctl -u sba-argo -n 15 --no-pager 2>/dev/null | tail -15
        return 1
    fi
    if [ "$(ag '.mode')" == "temp" ]; then
        warn "正在等待 Cloudflare 分配临时域名 ..."
        local d
        d=$(argo_detect_domain) || {
            err "未能获取 trycloudflare 域名，可稍后在 Argo 菜单里刷新。"
            return 1
        }
        ok "临时隧道域名: ${d}"
    fi
    return 0
}

show_argo_link() {
    local o tag
    tag=$(ag '.node_tag // ""')
    o=$(node_json_by_tag "$tag")
    [ -z "$o" ] && return 1
    load_state
    link_extract "$o"
    line
    echo -e "${YELLOW}Argo 节点 (VMess + WS + TLS over Cloudflare)：${PLAIN}"
    echo -e " 隧道域名: ${GREEN}$(ag '.domain')${PLAIN}   连接地址: $(ag '.cdn_ip // ""' | grep -q . && ag '.cdn_ip' || ag '.domain')"
    echo -e " 本机后端: 127.0.0.1:$(ag '.port')   路径: $(ag '.path')"
    argo_link
    line
}

argo_setup() {
    local mode="$1" tok dom ip port
    clear
    install_cloudflared || {
        pause
        return 1
    }
    argo_init || return 1
    argo_ensure_node || {
        pause
        return 1
    }
    port=$(ag '.port')

    if [ "$mode" == "token" ]; then
        line
        msg "固定隧道需要先在 Cloudflare Zero Trust 里建好 Tunnel："
        msg " 1) Networks → Tunnels → Create tunnel，复制安装命令里的 ${YELLOW}Token${PLAIN}"
        msg " 2) Public Hostname 的 Service 填 ${GREEN}http://localhost:${port}${PLAIN}"
        line
        while true; do
            read -r -p "请粘贴 Argo Token: " tok
            [ -n "${tok// /}" ] && break
            err "Token 不能为空"
        done
        while true; do
            read -r -p "隧道对应的域名 (如 argo.example.com): " dom
            valid_domain "$dom" && break
            err "域名格式不正确"
        done
        ag_set '.mode="token" | .token=$t | .domain=$d' --arg t "$tok" --arg d "$dom" || return 1
    else
        warn "临时隧道 (trycloudflare.com) 域名随机、重启即变，适合临时应急。"
        ag_set '.mode="temp" | .token="" | .domain=""' || return 1
    fi

    read -r -p "优选 IP / 优选域名 (回车 = 直接用隧道域名): " ip
    ag_set '.cdn_ip=$i' --arg i "${ip// /}"

    argo_apply || {
        pause
        return 1
    }
    show_argo_link
    pause
}

argo_state() {
    if [ ! -f "$ARGO_FILE" ] || ! jq -e '.enabled == true' "$ARGO_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}未启用${PLAIN}"
    elif systemctl is-active --quiet sba-argo 2>/dev/null; then
        echo -e "${GREEN}运行中${PLAIN} ($(ag '.mode'))  $(ag '.domain')"
    else
        echo -e "${RED}已配置但未运行${PLAIN}"
    fi
}

argo_uninstall() {
    local c
    read -r -p "确认卸载 Argo (同时删除后端节点)？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    systemctl disable --now sba-argo >/dev/null 2>&1
    rm -f "$ARGO_SERVICE_FILE" "$ARGO_LOG"
    systemctl daemon-reload >/dev/null 2>&1
    local tag
    tag=$(ag '.node_tag // ""')
    [ -n "$tag" ] && node_del "$tag"
    rm -f "$ARGO_FILE"
    apply_config
    ok "Argo 已卸载"
    pause
}

argo_menu() {
    argo_init
    while true; do
        clear
        line
        echo -e "${CYAN}          Argo (Cloudflare Tunnel)         ${PLAIN}"
        line
        echo -e " 当前状态: $(argo_state)"
        line
        msg " 1. 安装/切换为 ${GREEN}临时隧道${PLAIN} (trycloudflare，无需域名)"
        msg " 2. 安装/切换为 ${GREEN}固定隧道${PLAIN} (Token + 自有域名)"
        msg " 3. 查看 Argo 节点链接"
        msg " 4. 重启 Argo (临时隧道会换新域名)"
        msg " 5. 查看 cloudflared 日志"
        msg " 6. 修改优选 IP / 优选域名"
        msg " 7. 卸载 Argo"
        msg " 0. 返回主菜单"
        line
        local c ip
        read -r -p "请输入选项: " c
        case "$c" in
            1) argo_setup temp ;;
            2) argo_setup token ;;
            3)
                show_argo_link || {
                    err "尚未配置 Argo"
                }
                pause
                ;;
            4)
                : >"$ARGO_LOG" 2>/dev/null
                systemctl restart sba-argo >/dev/null 2>&1
                sleep 3
                [ "$(ag '.mode')" == "temp" ] && argo_detect_domain >/dev/null
                ok "已重启：$(argo_state)"
                show_argo_link
                pause
                ;;
            5)
                clear
                journalctl -u sba-argo -n 40 --no-pager 2>/dev/null | tail -40
                [ -s "$ARGO_LOG" ] && tail -20 "$ARGO_LOG"
                pause
                ;;
            6)
                read -r -p "优选 IP / 优选域名 (回车 = 用隧道域名): " ip
                ag_set '.cdn_ip=$i' --arg i "${ip// /}" && ok "已更新"
                pause
                ;;
            7) argo_uninstall ;;
            0 | "") return ;;
            *)
                err "无效选项"
                sleep 1
                ;;
        esac
    done
}

# ================= 证书 / 服务 / 卸载 =================

cert_info() {
    [ -s "$CERT_DIR/server.crt" ] || {
        warn "尚无证书文件"
        return 1
    }
    local sub dates
    sub=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -subject 2>/dev/null)
    dates=$(openssl x509 -in "$CERT_DIR/server.crt" -noout -dates 2>/dev/null | tr '\n' ' ')
    echo -e " 证书方式: $(nj '.cert.choice // "1"' | sed 's/^1$/自签/;s/^2$/Standalone/;s/^3$/Cloudflare DNS/')"
    echo -e " 绑定域名: $(nj '.cert.domain // ""')"
    echo -e " ${sub}"
    echo -e " ${dates}"
}

cert_menu() {
    while true; do
        clear
        line
        echo -e "${CYAN}                 证书管理                 ${PLAIN}"
        line
        cert_info
        line
        msg " 1. 更换证书方式 / 重新申请"
        msg " 2. 强制续期 (acme.sh renew)"
        msg " 0. 返回"
        line
        local c
        read -r -p "请输入选项: " c
        case "$c" in
            1)
                ask_cert_params back || continue
                save_cert_state || continue
                if issue_cert; then
                    # TLS 类节点的 SNI 跟随新域名
                    local keys k
                    for k in $(proto_keys); do
                        [ "$(proto_tls "$k")" == "tls" ] && keys="$keys $k"
                    done
                    nj_set '.nodes = [.nodes[] | if ($ks | index(.key)) then .sni=$d else . end]' \
                        --argjson ks "$(printf '%s\n' $keys | jq -R . | jq -sc .)" --arg d "${DOMAIN:-bing.com}"
                    ok "证书已更新"
                    apply_config
                else
                    err "证书申请失败"
                fi
                pause
                ;;
            2)
                if [ -x "$HOME/.acme.sh/acme.sh" ] && [ "$(nj '.cert.choice')" != "1" ]; then
                    "$HOME/.acme.sh/acme.sh" --renew -d "$(nj '.cert.domain')" --ecc --force
                    systemctl restart sing-box >/dev/null 2>&1
                    ok "续期完成"
                else
                    warn "当前是自签证书或未安装 acme.sh，无需续期。"
                fi
                pause
                ;;
            0 | "") return ;;
            *)
                err "无效选项"
                sleep 1
                ;;
        esac
    done
}

service_menu() {
    while true; do
        clear
        line
        echo -e "${CYAN}                 服务管理                 ${PLAIN}"
        line
        echo -e " sing-box: $(service_state)   内核版本: $(core_version)"
        echo -e " Argo:     $(argo_state)"
        line
        msg " 1. 启动    2. 停止    3. 重启"
        msg " 4. 查看运行状态"
        msg " 5. 查看实时日志 (Ctrl+C 退出)"
        msg " 6. 查看 config.json"
        msg " 7. 更新 sing-box 内核"
        msg " 8. 开启 BBR (当前: $(check_bbr_status))"
        msg " 0. 返回"
        line
        local c
        read -r -p "请输入选项: " c
        case "$c" in
            1)
                systemctl start sing-box
                sleep 1
                ok "$(service_state)"
                pause
                ;;
            2)
                systemctl stop sing-box
                sleep 1
                ok "已停止"
                pause
                ;;
            3)
                systemctl restart sing-box
                sleep 1
                ok "$(service_state)"
                pause
                ;;
            4)
                clear
                systemctl status sing-box --no-pager 2>&1 | head -25
                pause
                ;;
            5)
                clear
                journalctl -u sing-box -f --no-pager
                ;;
            6)
                clear
                [ -f "$CONFIG_FILE" ] && jq . "$CONFIG_FILE" | head -200 || err "配置不存在"
                pause
                ;;
            7)
                update_core
                pause
                ;;
            8) enable_bbr ;;
            0 | "") return ;;
            *)
                err "无效选项"
                sleep 1
                ;;
        esac
    done
}

uninstall_all() {
    clear
    warn "此操作将卸载 sing-box、Argo 隧道以及全部节点配置。"
    local c
    read -r -p "确认卸载？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    read -r -p "是否保留证书文件 (${CERT_DIR})？[Y/n]: " c
    local keep_cert=1
    [[ "$c" =~ ^[Nn]$ ]] && keep_cert=0

    systemctl disable --now sing-box >/dev/null 2>&1
    systemctl disable --now sba-argo >/dev/null 2>&1
    rm -f "$SERVICE_FILE" "$ARGO_SERVICE_FILE" "$ARGO_LOG"
    systemctl daemon-reload >/dev/null 2>&1

    rm -f "$SING_BOX_BIN" "$CLOUDFLARED_BIN"
    if [ "$keep_cert" == "1" ]; then
        rm -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" "$NODES_FILE" "$ISP_FILE" "$ARGO_FILE" \
            "${CONFIG_DIR}/links.txt" "$CONF_FILE" "$EXTRA_NODES_FILE"
    else
        rm -rf "$CONFIG_DIR"
    fi
    rm -f /usr/bin/sba
    ok "卸载完成。"
    exit 0
}

update_script() {
    clear
    warn "正在从仓库拉取最新脚本 ..."
    local tmp="/tmp/sba_new_$$.sh"
    if ! curl "${CURL_OPTS[@]}" -o "$tmp" "${REPO_RAW}/install.sh"; then
        err "下载失败，请检查网络。"
        rm -f "$tmp"
        pause
        return
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        err "下载到的脚本语法校验失败，已放弃更新。"
        rm -f "$tmp"
        pause
        return
    fi
    local newver
    newver=$(grep -m1 '^SBA_VERSION=' "$tmp" | cut -d'"' -f2)
    mv -f "$tmp" /usr/bin/sba
    chmod +x /usr/bin/sba
    ok "已更新到版本 ${newver:-未知}，请重新执行 sba。"
    exit 0
}

run_module() {
    # 优先用脚本同目录下的模块文件，其次从仓库拉取
    local name="$1" dir local_file tmp
    dir=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo .)")" 2>/dev/null && pwd)
    local_file="${dir}/${name}"
    if [ -f "$local_file" ]; then
        bash "$local_file"
        return $?
    fi
    tmp="/tmp/sba_${name}"
    if curl "${CURL_OPTS[@]}" -o "$tmp" "${REPO_RAW}/${name}"; then
        bash "$tmp"
        rm -f "$tmp"
        return 0
    fi
    err "无法获取模块 ${name}"
    pause
    return 1
}

# ================= 主菜单 =================

start_menu() {
    clear
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}   Sing-box 全协议一键脚本 (SBA) v${SBA_VERSION}${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e " 服务状态: $(service_state)    内核: ${CYAN}$(core_version)${PLAIN}"
    echo -e " 节点数量: ${CYAN}$(node_count)${PLAIN} / 可选协议 ${CYAN}$(proto_keys | wc -l | tr -d ' ')${PLAIN} 种"
    echo -e " 家宽接管: $(isp_summary || echo -e "${YELLOW}未开启${PLAIN}")"
    echo -e " Argo隧道: $(argo_state)"
    line
    msg " 1. ${GREEN}安装 / 重装${PLAIN} (默认全协议，支持勾选)"
    msg " 2. 节点管理 (增删改 / 分享链接 / 二维码)"
    msg " 3. Argo 隧道 (Cloudflare Tunnel)"
    msg " 4. 家宽流量接管 (ISP 模块)"
    msg " 5. 证书管理"
    msg " 6. 服务管理 / 内核更新 / BBR"
    msg " 7. Realm 端口转发"
    msg " 8. 更新脚本"
    msg " 9. ${RED}卸载${PLAIN}"
    msg " 0. 退出"
    line
}

main() {
    if [ "$EUID" -ne 0 ]; then
        err "必须使用 root 用户运行此脚本 (可先执行 sudo su -)。"
        exit 1
    fi
    check_deps || exit 1
    mkdir -p "$CONFIG_DIR"

    if legacy_present; then
        clear
        warn "检测到旧版 (v1) 配置 ${CONF_FILE}"
        msg "将把原有端口 / UUID / 密码原样迁移到新架构，客户端无需重新导入。"
        local c
        read -r -p "现在迁移吗？[Y/n]: " c
        if [[ ! "$c" =~ ^[Nn]$ ]]; then
            if migrate_legacy; then
                ensure_core && apply_config
            else
                err "迁移失败，可选择重新安装。"
            fi
            pause
        fi
    fi

    install_shortcut

    while true; do
        start_menu
        local choice
        read -r -p "请输入选项 [0-9]: " choice
        case "$choice" in
            1) fresh_install ;;
            2) manage_nodes ;;
            3) argo_menu ;;
            4) run_module "isp.sh" ;;
            5) cert_menu ;;
            6) service_menu ;;
            7) run_module "realm.sh" ;;
            8) update_script ;;
            9) uninstall_all ;;
            0)
                echo ""
                exit 0
                ;;
            *)
                err "请输入正确的数字 [0-9]"
                sleep 1
                ;;
        esac
    done
}

# SBA_SOURCE_ONLY=1 时只加载函数，供测试使用
[ "${SBA_SOURCE_ONLY:-0}" == "1" ] || main "$@"
