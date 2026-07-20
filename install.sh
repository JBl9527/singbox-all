#!/bin/bash

# ==========================================
# Sing-box 五协议管理脚本 (SBA) — 修复版
#
# GitHub 直连不通时先执行：
#   export GH_PROXY="https://你的加速前缀/"
# 再运行本脚本。
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"
CONF_FILE="${CONFIG_DIR}/sba.conf"
SING_BOX_BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

GH_PROXY="${GH_PROXY:-}"
REPO_RAW="${GH_PROXY}https://raw.githubusercontent.com/JBl9527/singbox-all/main"
GH_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
GH_DL="${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download"

DEFAULT_REALITY_DEST="addons.mozilla.org"
DEFAULT_PADDING='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'

CURL_OPTS=(-fsSL --connect-timeout 8 --max-time 30)

PUBLIC_IP=""
USED_PORTS=()
CHOSEN_PORTS=()

[[ $EUID -ne 0 ]] && { echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"; exit 1; }

# ================= 小工具 =================

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键继续..." || true
    echo ""
}

install_shortcut() {
    [ -f /usr/bin/sba ] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    local self
    self=$(readlink -f "$0" 2>/dev/null)
    if [ -n "$self" ] && [ -f "$self" ] && [[ "$self" != *"/bash" ]]; then
        cp "$self" /usr/bin/sba 2>/dev/null && chmod +x /usr/bin/sba && return 0
    fi
    curl "${CURL_OPTS[@]}" -o /usr/bin/sba "${REPO_RAW}/install.sh" 2>/dev/null && chmod +x /usr/bin/sba
    return 0
}

apt_install() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}本脚本仅支持 Debian/Ubuntu (apt) 系统。${PLAIN}"
        return 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
}

check_deps_extra() {
    local missing=()
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}⟳ 安装扩展组件: ${missing[*]} ...${PLAIN}"
        apt_install "${missing[@]}"
    fi
}

# ================= 校验类函数 =================

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_range() {
    [[ "$1" =~ ^[0-9]+[:-][0-9]+$ ]] || return 1
    local a="${1%%[:-]*}" b="${1##*[:-]}"
    valid_port "$a" && valid_port "$b" && [ "$a" -lt "$b" ]
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

port_in_use() {
    ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${1}$"
}

# ================= 端口分配 =================

get_unique_port() {
    local p
    while true; do
        p=$(shuf -i 10000-65535 -n 1)
        [[ " ${USED_PORTS[*]} " == *" $p "* ]] && continue
        port_in_use "$p" && continue
        USED_PORTS+=("$p")
        REPLY=$p
        return 0
    done
}

generate_random_ports() {
    USED_PORTS=()
    get_unique_port; RND_REALITY=$REPLY
    get_unique_port; RND_ANYTLS=$REPLY
    get_unique_port; RND_ANYREALITY=$REPLY
    get_unique_port; RND_HY2=$REPLY
    get_unique_port; RND_TUIC=$REPLY
}

ask_port() {
    local prompt="$1" default="$2" p c
    while true; do
        read -r -p "${prompt} [默认 ${default}]: " p
        p=${p:-$default}
        if ! valid_port "$p"; then
            echo -e "${RED}端口必须是 1-65535 的数字，请重试。${PLAIN}"
            continue
        fi
        if [[ " ${CHOSEN_PORTS[*]} " == *" $p "* ]]; then
            echo -e "${RED}端口 $p 已被本次配置中的其他协议使用，请换一个。${PLAIN}"
            continue
        fi
        if [ "$p" != "$default" ] && port_in_use "$p"; then
            echo -e "${YELLOW}警告: 系统上端口 $p 已被占用。${PLAIN}"
            read -r -p "仍要使用吗？[y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] || continue
        fi
        CHOSEN_PORTS+=("$p")
        REPLY=$p
        return 0
    done
}

# ================= 网络基础 =================

get_public_ip() {
    [ -n "$PUBLIC_IP" ] && return 0
    local url
    for url in ifconfig.me ipv4.icanhazip.com api.ipify.org; do
        PUBLIC_IP=$(curl -s4 --connect-timeout 5 --max-time 8 "https://${url}" 2>/dev/null | tr -d '[:space:]')
        [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
        PUBLIC_IP=""
    done
    echo -e "${YELLOW}自动获取公网 IPv4 失败。${PLAIN}"
    read -r -p "请手动输入本机公网 IP: " PUBLIC_IP
    [[ -n "$PUBLIC_IP" ]]
}

check_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo -e "${GREEN}已开启${PLAIN}"
    else
        echo -e "${RED}未开启${PLAIN}"
    fi
}

enable_bbr() {
    clear
    local kver kmaj kmin
    kver=$(uname -r)
    kmaj=${kver%%.*}
    kmin=$(echo "$kver" | cut -d. -f2)
    if [ "$kmaj" -lt 4 ] || { [ "$kmaj" -eq 4 ] && [ "$kmin" -lt 9 ]; }; then
        echo -e "${RED}内核 $kver 低于 4.9，不支持 BBR，请先升级内核。${PLAIN}"
        pause; return
    fi
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo -e "${GREEN}系统已开启 BBR。${PLAIN}"
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        if sysctl -p >/dev/null 2>&1 && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
            echo -e "${GREEN}✔ BBR 开启成功！${PLAIN}"
        else
            echo -e "${RED}BBR 开启失败，请检查内核模块 (modprobe tcp_bbr)。${PLAIN}"
        fi
    fi
    pause
}

# ================= Sing-box 核心 =================

get_latest_version() {
    LATEST_VERSION=$(curl -s --connect-timeout 8 --max-time 15 "$GH_API" | jq -r '.tag_name // empty' | sed 's/^v//')
    [[ "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || LATEST_VERSION=""
}

download_core() {
    check_deps_extra
    get_latest_version
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}获取 sing-box 最新版本号失败（GitHub API 不可达或被限流）。${PLAIN}"
        echo -e "${YELLOW}如处于受限网络，请设置 GH_PROXY 后重试。${PLAIN}"
        return 1
    fi
    local arch dl_arch tmpdir
    arch=$(uname -m)
    case "$arch" in
        x86_64)  dl_arch="amd64" ;;
        aarch64) dl_arch="arm64" ;;
        *) echo -e "${RED}不支持的架构: $arch${PLAIN}"; return 1 ;;
    esac
    tmpdir=$(mktemp -d) || return 1
    echo -e "${YELLOW}下载 sing-box v${LATEST_VERSION} (linux-${dl_arch})...${PLAIN}"
    if ! curl "${CURL_OPTS[@]}" --max-time 180 -o "$tmpdir/sb.tgz" \
        "${GH_DL}/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${dl_arch}.tar.gz"; then
        echo -e "${RED}核心下载失败！${PLAIN}"
        rm -rf "$tmpdir"; return 1
    fi
    if ! tar -xzf "$tmpdir/sb.tgz" -C "$tmpdir"; then
        echo -e "${RED}解压失败，安装包可能已损坏。${PLAIN}"
        rm -rf "$tmpdir"; return 1
    fi
    # 先落盘 .new 再 mv，避免覆盖运行中的二进制导致 ETXTBSY
    install -m 755 "$tmpdir/sing-box-${LATEST_VERSION}-linux-${dl_arch}/sing-box" "${SING_BOX_BIN}.new"
    mv -f "${SING_BOX_BIN}.new" "$SING_BOX_BIN"
    rm -rf "$tmpdir"
    echo -e "${GREEN}✔ 核心已就绪: v${LATEST_VERSION}${PLAIN}"
    return 0
}

validate_config() {
    [ -x "$SING_BOX_BIN" ] || return 1
    [ -f "$CONFIG_DIR/config.json" ] || return 1
    if "$SING_BOX_BIN" check -c "$CONFIG_DIR/config.json" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${RED}配置校验失败：${PLAIN}"
    "$SING_BOX_BIN" check -c "$CONFIG_DIR/config.json" 2>&1 | tail -10
    return 1
}

silent_update_core() {
    clear
    local current="未安装"
    [ -x "$SING_BOX_BIN" ] && current=$("$SING_BOX_BIN" version 2>/dev/null | awk 'NR==1{print $3}')
    echo -e "${YELLOW}当前版本: ${current}${PLAIN}"
    [ -f "$SING_BOX_BIN" ] && cp -a "$SING_BOX_BIN" "${SING_BOX_BIN}.bak"
    if ! download_core; then
        [ -f "${SING_BOX_BIN}.bak" ] && mv -f "${SING_BOX_BIN}.bak" "$SING_BOX_BIN"
        pause; return
    fi
    if validate_config; then
        systemctl restart sing-box
        rm -f "${SING_BOX_BIN}.bak"
        echo -e "${GREEN}✔ 已更新至 v${LATEST_VERSION} 并重启服务。${PLAIN}"
    else
        echo -e "${RED}新核心与现有配置不兼容，已回滚到原版本。${PLAIN}"
        mv -f "${SING_BOX_BIN}.bak" "$SING_BOX_BIN"
        systemctl restart sing-box
    fi
    pause
}

# ================= 证书 =================

prompt_domain() {
    local d
    while true; do
        read -r -p "请输入域名: " d
        if valid_domain "$d"; then
            DOMAIN="$d"; return 0
        fi
        echo -e "${RED}域名格式不正确，请重试。${PLAIN}"
    done
}

# $1 传 "back" 时允许 0 返回
ask_cert_params() {
    local allow_back="${1:-}"
    while true; do
        echo "1. 生成临时自签证书 (有效期10年，适合无域名场景)"
        echo "2. 申请永久证书 (Standalone，要求域名已解析到本机且 80 端口可用)"
        echo "3. 申请永久证书 (Cloudflare DNS API)"
        [ -n "$allow_back" ] && echo "0. 返回"
        read -r -p "请输入选项: " CERT_CHOICE
        if [ -n "$allow_back" ] && [ "$CERT_CHOICE" == "0" ]; then return 1; fi
        case "$CERT_CHOICE" in 1|2|3) break ;; *) echo -e "${RED}无效选项${PLAIN}" ;; esac
    done
    case "$CERT_CHOICE" in
        1) DOMAIN="bing.com" ;;
        2)
            prompt_domain
            read -r -p "ACME 注册邮箱 [留空则自动生成]: " ACME_EMAIL
            ;;
        3)
            prompt_domain
            local use_token
            read -r -p "使用 CF API Token？(推荐，权限更小) [Y/n]: " use_token
            if [[ ! "$use_token" =~ ^[Nn]$ ]]; then
                read -r -p "CF API Token: " CF_TOKEN
                read -r -p "CF Account ID (可留空): " CF_ACCOUNT_ID
                CF_EMAIL=""; CF_KEY=""
            else
                read -r -p "CF 账号邮箱: " CF_EMAIL
                read -r -p "CF Global API Key: " CF_KEY
                CF_TOKEN=""; CF_ACCOUNT_ID=""
            fi
            ;;
    esac
    return 0
}

install_acme() {
    apt_install socat cron
    if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
        local email="${ACME_EMAIL:-sba_cert_${RANDOM}@gmail.com}"
        echo -e "${YELLOW}安装 acme.sh (注册邮箱: ${email})...${PLAIN}"
        curl -s --connect-timeout 8 --max-time 120 https://get.acme.sh | sh -s email="$email"
    fi
    [ -x "$HOME/.acme.sh/acme.sh" ]
}

precheck_standalone() {
    get_public_ip
    local resolved c
    resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$PUBLIC_IP" ] && [ -n "$resolved" ] && [ "$resolved" != "$PUBLIC_IP" ]; then
        echo -e "${YELLOW}警告: $DOMAIN 解析到 $resolved，与本机 $PUBLIC_IP 不一致，申请可能失败。${PLAIN}"
        read -r -p "仍要继续吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return 1
    fi
    if port_in_use 80; then
        echo -e "${YELLOW}警告: 80 端口已被占用，Standalone 验证需要 80 端口：${PLAIN}"
        ss -lntupH 2>/dev/null | grep ':80 ' || true
        read -r -p "仍要继续吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

issue_cert() {
    mkdir -p "$CERT_DIR"
    case "$CERT_CHOICE" in
        1)
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
                -subj "/C=US/ST=State/L=City/O=Organization/CN=bing.com" || return 1
            ;;
        2|3)
            install_acme || { echo -e "${RED}acme.sh 安装失败${PLAIN}"; return 1; }
            "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
            if [ "$CERT_CHOICE" == "2" ]; then
                precheck_standalone || return 1
                echo -e "${YELLOW}申请证书 (Standalone)...${PLAIN}"
                # 不加 --force：已有有效证书时 acme.sh 自动跳过，避免触发 LE 频率限制
                "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone -k ec-256 || return 1
            else
                if [ -n "$CF_TOKEN" ]; then
                    export CF_Token="$CF_TOKEN"
                    [ -n "$CF_ACCOUNT_ID" ] && export CF_Account_ID="$CF_ACCOUNT_ID"
                else
                    export CF_Key="$CF_KEY"
                    export CF_Email="$CF_EMAIL"
                fi
                echo -e "${YELLOW}申请证书 (Cloudflare DNS)...${PLAIN}"
                "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" -k ec-256 || return 1
            fi
            # reloadcmd 确保证书续期后 sing-box 自动重载
            "$HOME/.acme.sh/acme.sh" --installcert -d "$DOMAIN" --ecc \
                --fullchain-file "$CERT_DIR/server.crt" \
                --key-file "$CERT_DIR/server.key" \
                --reloadcmd "systemctl restart sing-box >/dev/null 2>&1 || true" || return 1
            ;;
    esac
    chmod 600 "$CERT_DIR/server.key"
    return 0
}

# ================= 配置生成 =================

save_config() {
    cat > "$CONF_FILE" <<EOF_SBA_CONF
CERT_CHOICE="${CERT_CHOICE}"
DOMAIN="${DOMAIN}"
ACME_EMAIL="${ACME_EMAIL}"
CF_EMAIL="${CF_EMAIL}"
CF_KEY="${CF_KEY}"
CF_TOKEN="${CF_TOKEN}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID}"
PORT_REALITY="${PORT_REALITY}"
PORT_ANYTLS="${PORT_ANYTLS}"
PORT_ANYREALITY="${PORT_ANYREALITY}"
PORT_HY2="${PORT_HY2}"
PORT_HY2_RANGE="${PORT_HY2_RANGE}"
PORT_TUIC="${PORT_TUIC}"
PADDING_SCHEME_JSON='${PADDING_SCHEME_JSON}'
UUID_REALITY="${UUID_REALITY}"
PASS_ANYTLS="${PASS_ANYTLS}"
PASS_ANYREALITY="${PASS_ANYREALITY}"
PASS_HY2="${PASS_HY2}"
UUID_TUIC="${UUID_TUIC}"
PASS_TUIC="${PASS_TUIC}"
REALITY_PRIVATE="${REALITY_PRIVATE}"
REALITY_PUBLIC="${REALITY_PUBLIC}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
REALITY_DEST="${REALITY_DEST}"
EOF_SBA_CONF
    chmod 600 "$CONF_FILE"
}

generate_config_json() {
    local FINAL_DEST=${REALITY_DEST:-$DEFAULT_REALITY_DEST}
    local tmp="${CONFIG_DIR}/config.json.tmp"
    cat > "$tmp" <<EOF_SINGBOX_JSON
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": ${PORT_REALITY},
      "users": [ { "uuid": "${UUID_REALITY}", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "${FINAL_DEST}", "reality": { "enabled": true, "handshake": { "server": "${FINAL_DEST}", "server_port": 443 }, "private_key": "${REALITY_PRIVATE}", "short_id": ["${REALITY_SHORT_ID}"] } }
    },
    {
      "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": ${PORT_ANYTLS},
      "users": [ { "password": "${PASS_ANYTLS}" } ],
      "padding_scheme": [ ${PADDING_SCHEME_JSON} ],
      "tls": { "enabled": true, "certificate_path": "${CERT_DIR}/server.crt", "key_path": "${CERT_DIR}/server.key" }
    },
    {
      "type": "anytls", "tag": "any-reality-in", "listen": "::", "listen_port": ${PORT_ANYREALITY},
      "users": [ { "password": "${PASS_ANYREALITY}" } ],
      "padding_scheme": [ ${PADDING_SCHEME_JSON} ],
      "tls": { "enabled": true, "server_name": "${FINAL_DEST}", "reality": { "enabled": true, "handshake": { "server": "${FINAL_DEST}", "server_port": 443 }, "private_key": "${REALITY_PRIVATE}", "short_id": ["${REALITY_SHORT_ID}"] } }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": ${PORT_HY2},
      "users": [ { "password": "${PASS_HY2}" } ],
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "${CERT_DIR}/server.crt", "key_path": "${CERT_DIR}/server.key" }
    },
    {
      "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": ${PORT_TUIC},
      "users": [ { "uuid": "${UUID_TUIC}", "password": "${PASS_TUIC}" } ],
      "tls": { "enabled": true, "alpn": ["h3", "spdy/3.1"], "certificate_path": "${CERT_DIR}/server.crt", "key_path": "${CERT_DIR}/server.key" }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF_SINGBOX_JSON

    if "$SING_BOX_BIN" check -c "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "${CONFIG_DIR}/config.json"
        chmod 600 "${CONFIG_DIR}/config.json"
        return 0
    fi
    echo -e "${RED}生成的配置未通过 sing-box 校验：${PLAIN}"
    "$SING_BOX_BIN" check -c "$tmp" 2>&1 | tail -10
    rm -f "$tmp"
    return 1
}

configure_systemd() {
    local ipt ip6t start_lines="" stop_lines=""
    ipt=$(command -v iptables || echo "/usr/sbin/iptables")
    ip6t=$(command -v ip6tables || echo "/usr/sbin/ip6tables")
    if [ -n "$PORT_HY2_RANGE" ]; then
        start_lines="ExecStartPost=-${ipt} -t nat -A PREROUTING -p udp --dport ${PORT_HY2_RANGE} -j REDIRECT --to-ports ${PORT_HY2}
ExecStartPost=-${ip6t} -t nat -A PREROUTING -p udp --dport ${PORT_HY2_RANGE} -j REDIRECT --to-ports ${PORT_HY2}"
        stop_lines="ExecStopPost=-${ipt} -t nat -D PREROUTING -p udp --dport ${PORT_HY2_RANGE} -j REDIRECT --to-ports ${PORT_HY2}
ExecStopPost=-${ip6t} -t nat -D PREROUTING -p udp --dport ${PORT_HY2_RANGE} -j REDIRECT --to-ports ${PORT_HY2}"
    fi

    cat > "$SERVICE_FILE" <<EOF_SINGBOX_SERVICE
[Unit]
Description=Sing-box Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=${SING_BOX_BIN} run -c ${CONFIG_DIR}/config.json
${start_lines}
${stop_lines}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_SINGBOX_SERVICE

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
}

# ================= 安装 =================

fresh_install() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        开始全新安装 Sing-box 服务         ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    if [ -f "$CONF_FILE" ]; then
        local c
        read -r -p "检测到已有安装，重装将覆盖现有配置，继续？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}本脚本仅支持 Debian/Ubuntu (apt) 系统。${PLAIN}"
        pause; return
    fi

    echo -e "\n${GREEN}安装基础依赖...${PLAIN}"
    apt_install curl wget jq openssl socat uuid-runtime cron iptables qrencode iproute2

    echo -e "\n${YELLOW}=== 1. 证书配置 ===${PLAIN}"
    ask_cert_params

    echo -e "\n${YELLOW}=== 2. 协议端口 ===${PLAIN}"
    generate_random_ports
    CHOSEN_PORTS=()
    ask_port "VLESS-REALITY 端口" "$RND_REALITY";  PORT_REALITY=$REPLY
    ask_port "标准 AnyTLS 端口" "$RND_ANYTLS";     PORT_ANYTLS=$REPLY
    ask_port "Any-Reality 端口" "$RND_ANYREALITY"; PORT_ANYREALITY=$REPLY
    ask_port "Hysteria2 端口" "$RND_HY2";          PORT_HY2=$REPLY

    local rng
    while true; do
        read -r -p "Hy2 跳跃端口段 (如 20000-30000，直接回车不跳跃): " rng
        [ -z "$rng" ] && { PORT_HY2_RANGE=""; break; }
        if valid_range "$rng"; then
            PORT_HY2_RANGE=$(echo "$rng" | tr '-' ':')
            break
        fi
        echo -e "${RED}格式不正确，应为 起始-结束 且 起始<结束。${PLAIN}"
    done

    ask_port "TUIC v5 端口" "$RND_TUIC";           PORT_TUIC=$REPLY

    echo -e "\n${YELLOW}=== 3. REALITY 伪装域名 ===${PLAIN}"
    local dest
    read -r -p "伪装目标域名 [默认: ${DEFAULT_REALITY_DEST}]: " dest
    REALITY_DEST=${dest:-$DEFAULT_REALITY_DEST}

    echo -e "\n${YELLOW}=== 4. AnyTLS Padding ===${PLAIN}"
    local pad
    read -r -p "自定义 padding (直接回车使用内置配置): " pad
    if [ -z "$pad" ]; then
        PADDING_SCHEME_JSON="$DEFAULT_PADDING"
    elif echo "[ ${pad} ]" | jq -e . >/dev/null 2>&1; then
        PADDING_SCHEME_JSON="$pad"
    else
        echo -e "${RED}输入不是合法 JSON 片段，已改用内置配置。${PLAIN}"
        PADDING_SCHEME_JSON="$DEFAULT_PADDING"
    fi

    echo -e "\n${GREEN}下载 Sing-box 核心...${PLAIN}"
    if ! download_core; then
        echo -e "${RED}安装中止。${PLAIN}"
        pause; return
    fi

    echo -e "\n${GREEN}签发证书...${PLAIN}"
    if ! issue_cert; then
        echo -e "${RED}证书签发失败，安装中止（请检查域名解析 / 80 端口 / CF 凭证）。${PLAIN}"
        pause; return
    fi

    UUID_REALITY=$(uuidgen)
    PASS_ANYTLS=$(openssl rand -hex 12)
    PASS_ANYREALITY=$(openssl rand -hex 12)
    PASS_HY2=$(openssl rand -hex 12)
    UUID_TUIC=$(uuidgen)
    PASS_TUIC=$(openssl rand -hex 12)

    local keypair
    keypair=$("$SING_BOX_BIN" generate reality-keypair)
    REALITY_PRIVATE=$(echo "$keypair" | awk '/PrivateKey/{print $NF}')
    REALITY_PUBLIC=$(echo "$keypair" | awk '/PublicKey/{print $NF}')
    REALITY_SHORT_ID=$("$SING_BOX_BIN" generate rand --hex 8)

    mkdir -p "$CONFIG_DIR"
    save_config
    if ! generate_config_json; then
        echo -e "${RED}配置生成失败，安装中止。${PLAIN}"
        pause; return
    fi
    configure_systemd

    if systemctl is-active --quiet sing-box; then
        echo -e "\n${GREEN}✔ Sing-box 安装成功并已运行。${PLAIN}"
    else
        echo -e "\n${RED}服务未能启动，请用 journalctl -u sing-box -n 50 查看日志。${PLAIN}"
    fi
    echo -e "${YELLOW}提示: 若启用防火墙/云安全组，请放行上述端口（Hy2 及跳跃段为 UDP）。${PLAIN}"
    sleep 2
    show_links
}

# ================= 证书管理 =================

standalone_cert_manager() {
    clear
    [ -f "$CONF_FILE" ] || { echo -e "${RED}未检测到配置！${PLAIN}"; sleep 2; return; }
    source "$CONF_FILE"
    local OLD_DOMAIN="$DOMAIN"
    local OLD_CHOICE="$CERT_CHOICE"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          独立证书申请与修复模块          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "当前域名: ${GREEN}${DOMAIN:-无}${PLAIN}   当前类型: ${GREEN}${CERT_CHOICE:-未知}${PLAIN}"
    echo ""

    ask_cert_params "back" || return
    save_config

    if ! issue_cert; then
        echo -e "${RED}证书签发失败。${PLAIN}"
        pause; return
    fi

    # 从域名证书切回自签时，移除旧域名的续期任务，避免以后覆盖证书文件
    if [ "$CERT_CHOICE" == "1" ] && [ "$OLD_CHOICE" != "1" ] && [ -x "$HOME/.acme.sh/acme.sh" ]; then
        "$HOME/.acme.sh/acme.sh" --remove -d "$OLD_DOMAIN" --ecc >/dev/null 2>&1
    fi

    systemctl restart sing-box
    echo -e "${GREEN}✔ 证书已更新并重启服务。${PLAIN}"
    sleep 1
    show_links
}

# ================= 参数修改 =================

modify_parameters() {
    clear
    [ -f "$CONF_FILE" ] || { echo -e "${RED}未检测到配置！${PLAIN}"; sleep 2; return; }
    check_deps_extra
    source "$CONF_FILE"
    [ -z "$REALITY_DEST" ] && REALITY_DEST="$DEFAULT_REALITY_DEST"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}            修改节点参数                  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "1. REALITY 端口 (当前: $PORT_REALITY)"
    echo -e "2. AnyTLS 端口 (当前: $PORT_ANYTLS)"
    echo -e "3. Any-Reality 端口 (当前: $PORT_ANYREALITY)"
    echo -e "4. Hysteria2 端口 (当前: $PORT_HY2${PORT_HY2_RANGE:+, 跳跃: $PORT_HY2_RANGE})"
    echo -e "5. TUIC v5 端口 (当前: $PORT_TUIC)"
    echo -e "6. AnyTLS/Any-Reality Padding"
    echo -e "7. REALITY 伪装域名 (当前: $REALITY_DEST)"
    echo -e "0. 返回主菜单"
    local choice np nr npad ndest others
    read -r -p "请选择 [0-7]: " choice
    [ "$choice" == "0" ] && return

    case "$choice" in
        1|2|3|5)
            read -r -p "新端口: " np
            if ! valid_port "$np"; then echo -e "${RED}端口无效。${PLAIN}"; sleep 1; return; fi
            case "$choice" in
                1) others="$PORT_ANYTLS $PORT_ANYREALITY $PORT_HY2 $PORT_TUIC" ;;
                2) others="$PORT_REALITY $PORT_ANYREALITY $PORT_HY2 $PORT_TUIC" ;;
                3) others="$PORT_REALITY $PORT_ANYTLS $PORT_HY2 $PORT_TUIC" ;;
                5) others="$PORT_REALITY $PORT_ANYTLS $PORT_ANYREALITY $PORT_HY2" ;;
            esac
            if [[ " $others " == *" $np "* ]]; then
                echo -e "${RED}端口与其他协议冲突。${PLAIN}"; sleep 1; return
            fi
            case "$choice" in
                1) PORT_REALITY=$np ;; 2) PORT_ANYTLS=$np ;;
                3) PORT_ANYREALITY=$np ;; 5) PORT_TUIC=$np ;;
            esac
            ;;
        4)
            read -r -p "新 Hy2 主监听端口: " np
            if ! valid_port "$np"; then echo -e "${RED}端口无效。${PLAIN}"; sleep 1; return; fi
            if [[ " $PORT_REALITY $PORT_ANYTLS $PORT_ANYREALITY $PORT_TUIC " == *" $np "* ]]; then
                echo -e "${RED}端口与其他协议冲突。${PLAIN}"; sleep 1; return
            fi
            PORT_HY2=$np
            read -r -p "新跳跃段 (如 20000-30000；输入 none 清除；回车保持不变): " nr
            if [ "$nr" == "none" ]; then
                PORT_HY2_RANGE=""
            elif [ -n "$nr" ]; then
                if valid_range "$nr"; then
                    PORT_HY2_RANGE=$(echo "$nr" | tr '-' ':')
                else
                    echo -e "${RED}跳跃段格式不正确，该项未修改。${PLAIN}"
                fi
            fi
            ;;
        6)
            read -r -p "新 Padding (留空恢复内置): " npad
            if [ -z "$npad" ]; then
                PADDING_SCHEME_JSON="$DEFAULT_PADDING"
            elif echo "[ ${npad} ]" | jq -e . >/dev/null 2>&1; then
                PADDING_SCHEME_JSON="$npad"
            else
                echo -e "${RED}非法 JSON，未修改。${PLAIN}"; sleep 1; return
            fi
            ;;
        7)
            read -r -p "新伪装域名: " ndest
            if valid_domain "$ndest"; then
                REALITY_DEST=$ndest
            else
                echo -e "${RED}域名格式不正确。${PLAIN}"; sleep 1; return
            fi
            ;;
        *) return ;;
    esac

    cp "$CONF_FILE" "${CONF_FILE}.bak"
    save_config
    if generate_config_json; then
        configure_systemd
        rm -f "${CONF_FILE}.bak"
        echo -e "${GREEN}✔ 修改成功，服务已重启（注意：重启会中断现有连接）。${PLAIN}"
        sleep 1
        show_links
    else
        echo -e "${RED}新配置未通过校验，已回滚。${PLAIN}"
        mv -f "${CONF_FILE}.bak" "$CONF_FILE"
        source "$CONF_FILE"
        generate_config_json >/dev/null 2>&1
        pause
    fi
}

# ================= 节点信息 =================

show_links() {
    [ -f "$CONF_FILE" ] || { echo -e "${RED}未找到配置！${PLAIN}"; sleep 1; return; }
    source "$CONF_FILE"
    check_deps_extra
    get_public_ip || { sleep 2; return; }

    local FINAL_DEST=${REALITY_DEST:-$DEFAULT_REALITY_DEST}
    local INSECURE_FLAG="0"
    [ "$CERT_CHOICE" == "1" ] && INSECURE_FLAG="1"

    VLESS_LINK="vless://${UUID_REALITY}@${PUBLIC_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${FINAL_DEST}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${PUBLIC_IP}-VLESS-REALITY"

    local HY2_EXTRA=""
    [ -n "$PORT_HY2_RANGE" ] && HY2_EXTRA="&ports=${PORT_HY2_RANGE/:/-}"
    HY2_LINK="hy2://${PASS_HY2}@${PUBLIC_IP}:${PORT_HY2}?insecure=${INSECURE_FLAG}&sni=${DOMAIN}${HY2_EXTRA}#${PUBLIC_IP}-Hysteria2"

    TUIC_LINK="tuic://${UUID_TUIC}:${PASS_TUIC}@${PUBLIC_IP}:${PORT_TUIC}?sni=${DOMAIN}&alpn=h3&allow_insecure=${INSECURE_FLAG}#${PUBLIC_IP}-TUIC"

    ANYTLS_LINK="anytls://${PASS_ANYTLS}@${PUBLIC_IP}:${PORT_ANYTLS}?security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&insecure=${INSECURE_FLAG}&allowInsecure=${INSECURE_FLAG}&type=tcp&headerType=none#${PUBLIC_IP}-AnyTLS"

    ANYREALITY_LINK="anytls://${PASS_ANYREALITY}@${PUBLIC_IP}:${PORT_ANYREALITY}?security=reality&sni=${FINAL_DEST}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${PUBLIC_IP}-AnyReality"

    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${GREEN}[1] VLESS + REALITY:${PLAIN}\n${VLESS_LINK}\n"
    echo -e "${GREEN}[2] 标准 AnyTLS:${PLAIN}\n${ANYTLS_LINK}\n"
    echo -e "${GREEN}[3] Any-Reality:${PLAIN}\n${ANYREALITY_LINK}\n"
    echo -e "${GREEN}[4] Hysteria2:${PLAIN}\n${HY2_LINK}\n"
    echo -e "${GREEN}[5] TUIC v5:${PLAIN}\n${TUIC_LINK}\n"
    echo -e "${CYAN}===========================================${PLAIN}"

    local q
    while true; do
        read -r -p "输入节点序号 [1-5] 显示二维码，回车返回主菜单: " q
        case "$q" in
            1) qrencode -t ANSIUTF8 "$VLESS_LINK" ;;
            2) qrencode -t ANSIUTF8 "$ANYTLS_LINK" ;;
            3) qrencode -t ANSIUTF8 "$ANYREALITY_LINK" ;;
            4) qrencode -t ANSIUTF8 "$HY2_LINK" ;;
            5) qrencode -t ANSIUTF8 "$TUIC_LINK" ;;
            "") return ;;
            *) echo -e "${RED}无效输入${PLAIN}" ;;
        esac
    done
}

# ================= 卸载 =================

uninstall_singbox() {
    clear
    local c c2 c3
    read -r -p "确认要彻底卸载 Sing-box 吗？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return

    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    # 双保险：清理可能残留的端口跳跃规则
    if [ -n "$PORT_HY2_RANGE" ] && [ -n "$PORT_HY2" ]; then
        local ipt ip6t
        ipt=$(command -v iptables); ip6t=$(command -v ip6tables)
        [ -n "$ipt" ]  && $ipt  -t nat -D PREROUTING -p udp --dport "$PORT_HY2_RANGE" -j REDIRECT --to-ports "$PORT_HY2" 2>/dev/null
        [ -n "$ip6t" ] && $ip6t -t nat -D PREROUTING -p udp --dport "$PORT_HY2_RANGE" -j REDIRECT --to-ports "$PORT_HY2" 2>/dev/null
    fi

    rm -rf "$CONFIG_DIR" "$SING_BOX_BIN" "${SING_BOX_BIN}.bak"

    if [ -x "$HOME/.acme.sh/acme.sh" ]; then
        read -r -p "是否同时卸载 acme.sh 及其证书续期任务？[y/N]: " c2
        if [[ "$c2" =~ ^[Yy]$ ]]; then
            "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1
            rm -rf "$HOME/.acme.sh"
        fi
    fi

    read -r -p "是否删除 sba 快捷指令？[y/N]: " c3
    [[ "$c3" =~ ^[Yy]$ ]] && rm -f /usr/bin/sba

    echo -e "${GREEN}✔ 卸载完成！${PLAIN}"
    sleep 2
}

# ================= 脚本自更新 =================

update_script() {
    clear
    local target self tmp
    target="/usr/bin/sba"
    self=$(readlink -f "$0" 2>/dev/null)
    if [ -n "$self" ] && [ -f "$self" ] && [[ "$self" != "/usr/bin/sba" && "$self" != *"/bash" ]]; then
        target="$self"
    fi
    # 临时文件放在目标同目录，保证 mv 是原子 rename，不破坏运行中的脚本
    tmp="${target}.update.tmp"

    echo -e "${YELLOW}拉取最新主脚本...${PLAIN}"
    if ! curl "${CURL_OPTS[@]}" -o "$tmp" "${REPO_RAW}/install.sh?t=$(date +%s)"; then
        echo -e "${RED}下载失败，请检查网络或设置 GH_PROXY。${PLAIN}"
        rm -f "$tmp"; pause; return
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        echo -e "${RED}下载的脚本语法校验失败，已取消更新（可能是仓库文件损坏）。${PLAIN}"
        rm -f "$tmp"; pause; return
    fi
    chmod +x "$tmp"
    mv -f "$tmp" "$target"
    if [ "$target" != "/usr/bin/sba" ]; then
        cp -f "$target" /usr/bin/sba && chmod +x /usr/bin/sba
    fi
    echo -e "${GREEN}✅ 更新成功，重新加载...${PLAIN}"
    sleep 1
    exec bash "$target"
}

# ================= 远程模块调用 =================

run_remote_module() {
    local name="$1" file="$2" tmp rc
    tmp=$(mktemp /tmp/sba_module.XXXXXX) || return 1
    clear
    echo -e "${YELLOW}正在拉取 ${name} 模块...${PLAIN}"
    # 关键：判断 curl 退出码，失败绝不执行残留文件
    if ! curl "${CURL_OPTS[@]}" --max-time 60 -o "$tmp" "${REPO_RAW}/${file}?t=$(date +%s)"; then
        echo -e "${RED}拉取失败！请检查网络、GH_PROXY 设置或确认仓库中已上传 ${file}。${PLAIN}"
        rm -f "$tmp"; pause; return
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        echo -e "${RED}模块语法校验失败，已中止（可能是仓库文件损坏）。${PLAIN}"
        rm -f "$tmp"; pause; return
    fi
    bash "$tmp"
    rc=$?
    rm -f "$tmp"
    if [ $rc -ne 0 ]; then
        echo -e "\n${RED}⚠️ ${name} 模块退出码 ${rc}，请检查上方输出。${PLAIN}"
        pause
    fi
}

# ================= 主菜单 =================

start_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}     Sing-box 五协议管理脚本 (SBA)        ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    local bbr_txt svc_txt
    bbr_txt=$(check_bbr_status)
    if [ -f "$CONF_FILE" ]; then
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            svc_txt="${GREEN}运行中${PLAIN}"
        else
            svc_txt="${RED}已安装但服务未运行${PLAIN}"
        fi
    else
        svc_txt="${YELLOW}未安装${PLAIN}"
    fi
    echo -e "状态: ${svc_txt}   |   BBR: ${bbr_txt}"
    echo -e "------------------------------------------"
    echo -e "${GREEN}1.${PLAIN}  更新 Sing-box 核心"
    echo -e "${GREEN}2.${PLAIN}  全新安装 / 强制重装 Sing-box"
    echo -e "${GREEN}3.${PLAIN}  修改端口、伪装域名等参数"
    echo -e "${GREEN}4.${PLAIN}  独立申请或修复证书"
    echo -e "${GREEN}5.${PLAIN}  查看节点链接与二维码"
    echo -e "${GREEN}6.${PLAIN}  开启 BBR 加速"
    echo -e "${GREEN}7.${PLAIN}  彻底卸载 Sing-box"
    echo -e "${GREEN}8.${PLAIN}  更新主管理脚本 (SBA)"
    echo -e "------------------------------------------"
    echo -e "${GREEN}9.${PLAIN}  ➡️ 端口转发模块 (远程调用 Realm)"
    echo -e "${GREEN}10.${PLAIN} ➡️ 家宽接管模块 (远程调用 ISP)"
    echo -e "${GREEN}0.${PLAIN}  退出"
    echo -e "${CYAN}==========================================${PLAIN}"
    local mc
    read -r -p "请输入选项: " mc
    case "$mc" in
        1) [ -f "$CONF_FILE" ] && silent_update_core || { echo -e "${RED}请先安装。${PLAIN}"; sleep 1; } ;;
        2) fresh_install ;;
        3) modify_parameters ;;
        4) standalone_cert_manager ;;
        5) show_links ;;
        6) enable_bbr ;;
        7) uninstall_singbox ;;
        8) update_script ;;
        9) run_remote_module "端口转发(Realm)" "realm.sh" ;;
        10) run_remote_module "家宽接管(ISP)" "isp.sh" ;;
        0) exit 0 ;;
        *) ;;
    esac
}

install_shortcut
while true; do
    start_menu
done
