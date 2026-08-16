#!/bin/bash

# ==========================================
# Sing-box 五协议管理脚本 (SBA)
#
# 支持协议:
#   1. VLESS + REALITY
#   2. AnyTLS
#   3. Any-Reality
#   4. Hysteria2
#   5. TUIC v5
#
# 新增协议节点:
#   可为同一协议增加多个节点
#   每个节点可单独设置端口和 SNI 域名
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
EXTRA_NODES_FILE="${CONFIG_DIR}/extra_nodes.conf"
SING_BOX_BIN="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

GH_PROXY="${GH_PROXY:-}"
if [ -n "$GH_PROXY" ] && [[ "$GH_PROXY" != */ ]]; then
    GH_PROXY="${GH_PROXY}/"
fi

REPO_RAW="${GH_PROXY}https://raw.githubusercontent.com/JBl9527/singbox-all/main"
GH_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
GH_DL="${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download"

DEFAULT_REALITY_DEST="addons.mozilla.org"
DEFAULT_PADDING='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'

CURL_OPTS=(-fsSL --connect-timeout 8 --max-time 30)

PUBLIC_IP=""
USED_PORTS=()
CHOSEN_PORTS=()

[[ $EUID -ne 0 ]] && {
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
}

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

    if [ -n "$self" ] && [ -f "$self" ] && [[ "$self" != "/bin/bash" && "$self" != "/usr/bin/bash" ]]; then
        cp "$self" /usr/bin/sba 2>/dev/null &&
            chmod +x /usr/bin/sba &&
            return 0
    fi

    curl "${CURL_OPTS[@]}" \
        -o /usr/bin/sba \
        "${REPO_RAW}/install.sh" 2>/dev/null &&
        chmod +x /usr/bin/sba

    return 0
}

apt_install() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}本脚本仅支持 Debian/Ubuntu apt 系统。${PLAIN}"
        return 1
    fi

    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || {
        echo -e "${RED}apt-get update 失败。${PLAIN}"
        return 1
    }

    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 || {
        echo -e "${RED}依赖安装失败: $*${PLAIN}"
        return 1
    }

    return 0
}

check_deps_extra() {
    local missing=()

    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
    command -v base64 >/dev/null 2>&1 || missing+=(coreutils)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}⟳ 安装扩展组件: ${missing[*]} ...${PLAIN}"
        apt_install "${missing[@]}" || return 1
    fi

    return 0
}

b64_encode() {
    printf '%s' "$1" | base64 -w 0 2>/dev/null ||
        printf '%s' "$1" | base64 | tr -d '\n'
}

b64_decode() {
    printf '%s' "$1" | base64 -d 2>/dev/null
}

# ================= 校验类函数 =================

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        [ "$1" -ge 1 ] &&
        [ "$1" -le 65535 ]
}

valid_range() {
    [[ "$1" =~ ^[0-9]+[:-][0-9]+$ ]] || return 1

    local a b
    a="${1%%[:-]*}"
    b="${1##*[:-]}"

    valid_port "$a" &&
        valid_port "$b" &&
        [ "$a" -lt "$b" ]
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local part
    IFS='.' read -r -a parts <<< "$1"

    for part in "${parts[@]}"; do
        [ "$part" -le 255 ] || return 1
    done

    return 0
}

port_in_use() {
    command -v ss >/dev/null 2>&1 || return 1

    ss -lntuH 2>/dev/null |
        awk '{print $5}' |
        grep -Eq "(^|[.:])${1}$"
}

# ================= 端口分配 =================

get_unique_port() {
    local p

    while true; do
        p=$(shuf -i 10000-65535 -n 1)

        [[ " ${USED_PORTS[*]} " == *" $p "* ]] && continue
        port_in_use "$p" && continue

        USED_PORTS+=("$p")
        REPLY="$p"
        return 0
    done
}

generate_random_ports() {
    USED_PORTS=()

    get_unique_port
    RND_REALITY="$REPLY"

    get_unique_port
    RND_ANYTLS="$REPLY"

    get_unique_port
    RND_ANYREALITY="$REPLY"

    get_unique_port
    RND_HY2="$REPLY"

    get_unique_port
    RND_TUIC="$REPLY"
}

get_extra_ports() {
    [ -f "$EXTRA_NODES_FILE" ] || return 0

    local encoded decoded proto port sni id pass

    while IFS= read -r encoded || [ -n "$encoded" ]; do
        [ -z "$encoded" ] && continue

        decoded=$(b64_decode "$encoded" 2>/dev/null) || continue

        IFS=$'\t' read -r proto port sni id pass <<< "$decoded"

        valid_port "$port" && echo "$port"
    done < "$EXTRA_NODES_FILE"
}

collect_all_ports() {
    USED_PORTS=()

    [ -n "${PORT_REALITY:-}" ] && USED_PORTS+=("$PORT_REALITY")
    [ -n "${PORT_ANYTLS:-}" ] && USED_PORTS+=("$PORT_ANYTLS")
    [ -n "${PORT_ANYREALITY:-}" ] && USED_PORTS+=("$PORT_ANYREALITY")
    [ -n "${PORT_HY2:-}" ] && USED_PORTS+=("$PORT_HY2")
    [ -n "${PORT_TUIC:-}" ] && USED_PORTS+=("$PORT_TUIC")

    local p
    while read -r p; do
        [ -n "$p" ] && USED_PORTS+=("$p")
    done < <(get_extra_ports)
}

ask_port() {
    local prompt="$1"
    local default="$2"
    local p c

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
        REPLY="$p"
        return 0
    done
}

ask_new_node_port() {
    local p c

    while true; do
        read -r -p "请输入新增节点端口: " p

        if ! valid_port "$p"; then
            echo -e "${RED}端口必须是 1-65535 的数字。${PLAIN}"
            continue
        fi

        if [[ " ${USED_PORTS[*]} " == *" $p "* ]]; then
            echo -e "${RED}端口 $p 已被当前 Sing-box 配置使用，请更换。${PLAIN}"
            continue
        fi

        if port_in_use "$p"; then
            echo -e "${YELLOW}警告: 系统上端口 $p 当前已被占用。${PLAIN}"
            ss -lntupH 2>/dev/null | grep -E "[:.]${p}[[:space:]]" || true

            read -r -p "仍然使用该端口吗？[y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] || continue
        fi

        REPLY="$p"
        return 0
    done
}

# ================= 网络基础 =================

get_public_ip() {
    [ -n "$PUBLIC_IP" ] && return 0

    local url

    for url in ifconfig.me ipv4.icanhazip.com api.ipify.org; do
        PUBLIC_IP=$(
            curl -s4 \
                --connect-timeout 5 \
                --max-time 8 \
                "https://${url}" 2>/dev/null |
                tr -d '[:space:]'
        )

        if valid_ipv4 "$PUBLIC_IP"; then
            return 0
        fi

        PUBLIC_IP=""
    done

    echo -e "${YELLOW}自动获取公网 IPv4 失败。${PLAIN}"

    while true; do
        read -r -p "请手动输入本机公网 IP: " PUBLIC_IP

        if valid_ipv4 "$PUBLIC_IP"; then
            return 0
        fi

        echo -e "${RED}IPv4 地址格式不正确，请重试。${PLAIN}"
    done
}

check_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null |
        grep -q "bbr"; then
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

    if [ "$kmaj" -lt 4 ] ||
        {
            [ "$kmaj" -eq 4 ] &&
                [ "$kmin" -lt 9 ]
        }; then
        echo -e "${RED}内核 $kver 低于 4.9，不支持 BBR，请先升级内核。${PLAIN}"
        pause
        return
    fi

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null |
        grep -q "bbr"; then
        echo -e "${GREEN}系统已开启 BBR。${PLAIN}"
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

        if sysctl -p >/dev/null 2>&1 &&
            sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
            echo -e "${GREEN}✔ BBR 开启成功！${PLAIN}"
        else
            echo -e "${RED}BBR 开启失败，请检查内核模块 tcp_bbr。${PLAIN}"
        fi
    fi

    pause
}

# ================= Sing-box 核心 =================

get_latest_version() {
    LATEST_VERSION=$(
        curl "${CURL_OPTS[@]}" \
            "${GH_PROXY}${GH_API}" 2>/dev/null |
            jq -r '.tag_name // empty' |
            sed 's/^v//'
    )

    [[ "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        LATEST_VERSION=""
}

download_core() {
    check_deps_extra || return 1

    get_latest_version

    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}获取 sing-box 最新版本号失败（GitHub API 不可达或被限流）。${PLAIN}"
        echo -e "${YELLOW}如处于受限网络，请设置 GH_PROXY 后重试。${PLAIN}"
        return 1
    fi

    local arch dl_arch tmpdir

    arch=$(uname -m)

    case "$arch" in
        x86_64)
            dl_arch="amd64"
            ;;
        aarch64)
            dl_arch="arm64"
            ;;
        *)
            echo -e "${RED}不支持的架构: $arch${PLAIN}"
            return 1
            ;;
    esac

    tmpdir=$(mktemp -d) || return 1

    echo -e "${YELLOW}下载 sing-box v${LATEST_VERSION} (linux-${dl_arch})...${PLAIN}"

    if ! curl "${CURL_OPTS[@]}" \
        --max-time 180 \
        -o "$tmpdir/sb.tgz" \
        "${GH_DL}/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${dl_arch}.tar.gz"; then
        echo -e "${RED}核心下载失败！${PLAIN}"
        rm -rf "$tmpdir"
        return 1
    fi

    if ! tar -xzf "$tmpdir/sb.tgz" -C "$tmpdir"; then
        echo -e "${RED}解压失败，安装包可能已损坏。${PLAIN}"
        rm -rf "$tmpdir"
        return 1
    fi

    if [ ! -x "$tmpdir/sing-box-${LATEST_VERSION}-linux-${dl_arch}/sing-box" ]; then
        echo -e "${RED}解压后未找到 sing-box 可执行文件。${PLAIN}"
        rm -rf "$tmpdir"
        return 1
    fi

    # 先写入 .new，再 mv，避免覆盖运行中的二进制导致 ETXTBSY
    install -m 755 \
        "$tmpdir/sing-box-${LATEST_VERSION}-linux-${dl_arch}/sing-box" \
        "${SING_BOX_BIN}.new" || {
        rm -rf "$tmpdir"
        return 1
    }

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
    "$SING_BOX_BIN" check -c "$CONFIG_DIR/config.json" 2>&1 | tail -20
    return 1
}

silent_update_core() {
    clear

    local current="未安装"
    [ -x "$SING_BOX_BIN" ] &&
        current=$("$SING_BOX_BIN" version 2>/dev/null | awk 'NR==1{print $3}')

    echo -e "${YELLOW}当前版本: ${current}${PLAIN}"

    [ -f "$SING_BOX_BIN" ] &&
        cp -a "$SING_BOX_BIN" "${SING_BOX_BIN}.bak"

    if ! download_core; then
        [ -f "${SING_BOX_BIN}.bak" ] &&
            mv -f "${SING_BOX_BIN}.bak" "$SING_BOX_BIN"
        pause
        return
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
            DOMAIN="$d"
            return 0
        fi

        echo -e "${RED}域名格式不正确，请重试。${PLAIN}"
    done
}

ask_cert_params() {
    local allow_back="${1:-}"

    while true; do
        echo "1. 生成临时自签证书 (有效期10年，适合无域名场景)"
        echo "2. 申请永久证书 (Standalone，要求域名已解析到本机且 80 端口可用)"
        echo "3. 申请永久证书 (Cloudflare DNS API)"

        [ -n "$allow_back" ] && echo "0. 返回"

        read -r -p "请输入选项: " CERT_CHOICE

        if [ -n "$allow_back" ] && [ "$CERT_CHOICE" == "0" ]; then
            return 1
        fi

        case "$CERT_CHOICE" in
            1 | 2 | 3)
                break
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                ;;
        esac
    done

    case "$CERT_CHOICE" in
        1)
            DOMAIN="bing.com"
            ACME_EMAIL=""
            CF_EMAIL=""
            CF_KEY=""
            CF_TOKEN=""
            CF_ACCOUNT_ID=""
            ;;

        2)
            prompt_domain
            read -r -p "ACME 注册邮箱 [留空则自动生成]: " ACME_EMAIL
            CF_EMAIL=""
            CF_KEY=""
            CF_TOKEN=""
            CF_ACCOUNT_ID=""
            ;;

        3)
            prompt_domain

            local use_token
            read -r -p "使用 CF API Token？(推荐，权限更小) [Y/n]: " use_token

            if [[ ! "$use_token" =~ ^[Nn]$ ]]; then
                read -r -p "CF API Token: " CF_TOKEN
                read -r -p "CF Account ID (可留空): " CF_ACCOUNT_ID

                CF_EMAIL=""
                CF_KEY=""
            else
                read -r -p "CF 账号邮箱: " CF_EMAIL
                read -r -p "CF Global API Key: " CF_KEY

                CF_TOKEN=""
                CF_ACCOUNT_ID=""
            fi
            ;;
    esac

    return 0
}

install_acme() {
    apt_install socat cron || return 1

    if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
        local email="${ACME_EMAIL:-sba_cert_${RANDOM}@gmail.com}"

        echo -e "${YELLOW}安装 acme.sh (注册邮箱: ${email})...${PLAIN}"

        if ! curl -s \
            --connect-timeout 8 \
            --max-time 120 \
            https://get.acme.sh |
            sh -s email="$email"; then
            return 1
        fi
    fi

    [ -x "$HOME/.acme.sh/acme.sh" ]
}

precheck_standalone() {
    get_public_ip || return 1

    local resolved c
    resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')

    if [ -n "$PUBLIC_IP" ] &&
        [ -n "$resolved" ] &&
        [ "$resolved" != "$PUBLIC_IP" ]; then
        echo -e "${YELLOW}警告: $DOMAIN 解析到 $resolved，与本机 $PUBLIC_IP 不一致，申请可能失败。${PLAIN}"
        read -r -p "仍要继续吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return 1
    fi

    if port_in_use 80; then
        echo -e "${YELLOW}警告: 80 端口已被占用，Standalone 验证需要 80 端口：${PLAIN}"
        ss -lntupH 2>/dev/null | grep -E '[:.]80[[:space:]]' || true

        read -r -p "仍要继续吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return 1
    fi

    return 0
}

issue_cert() {
    mkdir -p "$CERT_DIR" || return 1

    case "$CERT_CHOICE" in
        1)
            openssl req \
                -x509 \
                -nodes \
                -days 3650 \
                -newkey rsa:2048 \
                -keyout "$CERT_DIR/server.key" \
                -out "$CERT_DIR/server.crt" \
                -subj "/C=US/ST=State/L=City/O=Organization/CN=bing.com" ||
                return 1
            ;;

        2 | 3)
            install_acme || {
                echo -e "${RED}acme.sh 安装失败${PLAIN}"
                return 1
            }

            "$HOME/.acme.sh/acme.sh" \
                --set-default-ca \
                --server letsencrypt >/dev/null 2>&1

            if [ "$CERT_CHOICE" == "2" ]; then
                precheck_standalone || return 1

                echo -e "${YELLOW}申请证书 (Standalone)...${PLAIN}"

                # 不加 --force，避免已有有效证书时重复触发频率限制
                "$HOME/.acme.sh/acme.sh" \
                    --issue \
                    -d "$DOMAIN" \
                    --standalone \
                    -k ec-256 || return 1
            else
                if [ -n "$CF_TOKEN" ]; then
                    export CF_Token="$CF_TOKEN"
                    [ -n "$CF_ACCOUNT_ID" ] &&
                        export CF_Account_ID="$CF_ACCOUNT_ID"
                else
                    export CF_Key="$CF_KEY"
                    export CF_Email="$CF_EMAIL"
                fi

                echo -e "${YELLOW}申请证书 (Cloudflare DNS)...${PLAIN}"

                "$HOME/.acme.sh/acme.sh" \
                    --issue \
                    --dns dns_cf \
                    -d "$DOMAIN" \
                    -k ec-256 || return 1
            fi

            # 证书续期后自动重启 sing-box
            "$HOME/.acme.sh/acme.sh" \
                --installcert \
                -d "$DOMAIN" \
                --ecc \
                --fullchain-file "$CERT_DIR/server.crt" \
                --key-file "$CERT_DIR/server.key" \
                --reloadcmd "systemctl restart sing-box >/dev/null 2>&1 || true" ||
                return 1
            ;;
        *)
            echo -e "${RED}未知证书类型。${PLAIN}"
            return 1
            ;;
    esac

    [ -f "$CERT_DIR/server.crt" ] || return 1
    [ -f "$CERT_DIR/server.key" ] || return 1

    chmod 600 "$CERT_DIR/server.key"
    chmod 644 "$CERT_DIR/server.crt"

    return 0
}

# ================= 配置保存 =================

save_config() {
    mkdir -p "$CONFIG_DIR"

    {
        printf 'CERT_CHOICE=%q\n' "${CERT_CHOICE:-}"
        printf 'DOMAIN=%q\n' "${DOMAIN:-}"
        printf 'ACME_EMAIL=%q\n' "${ACME_EMAIL:-}"
        printf 'CF_EMAIL=%q\n' "${CF_EMAIL:-}"
        printf 'CF_KEY=%q\n' "${CF_KEY:-}"
        printf 'CF_TOKEN=%q\n' "${CF_TOKEN:-}"
        printf 'CF_ACCOUNT_ID=%q\n' "${CF_ACCOUNT_ID:-}"

        printf 'PORT_REALITY=%q\n' "${PORT_REALITY:-}"
        printf 'PORT_ANYTLS=%q\n' "${PORT_ANYTLS:-}"
        printf 'PORT_ANYREALITY=%q\n' "${PORT_ANYREALITY:-}"
        printf 'PORT_HY2=%q\n' "${PORT_HY2:-}"
        printf 'PORT_HY2_RANGE=%q\n' "${PORT_HY2_RANGE:-}"
        printf 'PORT_TUIC=%q\n' "${PORT_TUIC:-}"

        printf 'PADDING_SCHEME_JSON=%q\n' "${PADDING_SCHEME_JSON:-}"

        printf 'UUID_REALITY=%q\n' "${UUID_REALITY:-}"
        printf 'PASS_ANYTLS=%q\n' "${PASS_ANYTLS:-}"
        printf 'PASS_ANYREALITY=%q\n' "${PASS_ANYREALITY:-}"
        printf 'PASS_HY2=%q\n' "${PASS_HY2:-}"
        printf 'UUID_TUIC=%q\n' "${UUID_TUIC:-}"
        printf 'PASS_TUIC=%q\n' "${PASS_TUIC:-}"

        printf 'REALITY_PRIVATE=%q\n' "${REALITY_PRIVATE:-}"
        printf 'REALITY_PUBLIC=%q\n' "${REALITY_PUBLIC:-}"
        printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID:-}"
        printf 'REALITY_DEST=%q\n' "${REALITY_DEST:-}"
    } > "$CONF_FILE"

    chmod 600 "$CONF_FILE"
}

padding_as_array() {
    local raw="${PADDING_SCHEME_JSON:-}"

    [ -n "$raw" ] || raw="$DEFAULT_PADDING"

    # 兼容完整 JSON 数组，例如:
    # ["stop=8","0=30-30"]
    if printf '%s\n' "$raw" |
        jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
        printf '%s\n' "$raw" | jq -c .
        return 0
    fi

    # 兼容 JSON 片段，例如:
    # "stop=8", "0=30-30"
    if printf '[%s]\n' "$raw" |
        jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
        printf '[%s]\n' "$raw" | jq -c .
        return 0
    fi

    return 1
}

set_padding_value() {
    local raw="$1"

    if [ -z "$raw" ]; then
        PADDING_SCHEME_JSON="$DEFAULT_PADDING"
        return 0
    fi

    if printf '%s\n' "$raw" |
        jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
        PADDING_SCHEME_JSON=$(printf '%s\n' "$raw" | jq -c .)
        return 0
    fi

    if printf '[%s]\n' "$raw" |
        jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
        PADDING_SCHEME_JSON=$(printf '[%s]\n' "$raw" | jq -c .)
        return 0
    fi

    return 1
}

# ================= 节点 JSON 生成 =================

make_inbound_json() {
    local protocol="$1"
    local tag="$2"
    local port="$3"
    local sni="$4"
    local identifier="$5"
    local password="$6"

    local padding_json
    padding_json=$(padding_as_array) || {
        echo -e "${RED}Padding 配置不是合法 JSON 数组。${PLAIN}" >&2
        return 1
    }

    case "$protocol" in
        1)
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg sni "$sni" \
                --arg uuid "$identifier" \
                --arg private_key "$REALITY_PRIVATE" \
                --arg short_id "$REALITY_SHORT_ID" \
                '
                {
                    type: "vless",
                    tag: $tag,
                    listen: "::",
                    listen_port: ($port | tonumber),
                    users: [
                        {
                            uuid: $uuid,
                            flow: "xtls-rprx-vision"
                        }
                    ],
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        reality: {
                            enabled: true,
                            handshake: {
                                server: $sni,
                                server_port: 443
                            },
                            private_key: $private_key,
                            short_id: [$short_id]
                        }
                    }
                }'
            ;;

        2)
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg sni "$sni" \
                --arg password "$password" \
                --arg cert "${CERT_DIR}/server.crt" \
                --arg key "${CERT_DIR}/server.key" \
                --argjson padding "$padding_json" \
                '
                {
                    type: "anytls",
                    tag: $tag,
                    listen: "::",
                    listen_port: ($port | tonumber),
                    users: [
                        {
                            password: $password
                        }
                    ],
                    padding_scheme: $padding,
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        certificate_path: $cert,
                        key_path: $key
                    }
                }'
            ;;

        3)
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg sni "$sni" \
                --arg password "$password" \
                --arg private_key "$REALITY_PRIVATE" \
                --arg short_id "$REALITY_SHORT_ID" \
                --argjson padding "$padding_json" \
                '
                {
                    type: "anytls",
                    tag: $tag,
                    listen: "::",
                    listen_port: ($port | tonumber),
                    users: [
                        {
                            password: $password
                        }
                    ],
                    padding_scheme: $padding,
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        reality: {
                            enabled: true,
                            handshake: {
                                server: $sni,
                                server_port: 443
                            },
                            private_key: $private_key,
                            short_id: [$short_id]
                        }
                    }
                }'
            ;;

        4)
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg sni "$sni" \
                --arg password "$password" \
                --arg cert "${CERT_DIR}/server.crt" \
                --arg key "${CERT_DIR}/server.key" \
                '
                {
                    type: "hysteria2",
                    tag: $tag,
                    listen: "::",
                    listen_port: ($port | tonumber),
                    users: [
                        {
                            password: $password
                        }
                    ],
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        alpn: ["h3"],
                        certificate_path: $cert,
                        key_path: $key
                    }
                }'
            ;;

        5)
            jq -n \
                --arg tag "$tag" \
                --arg port "$port" \
                --arg sni "$sni" \
                --arg uuid "$identifier" \
                --arg password "$password" \
                --arg cert "${CERT_DIR}/server.crt" \
                --arg key "${CERT_DIR}/server.key" \
                '
                {
                    type: "tuic",
                    tag: $tag,
                    listen: "::",
                    listen_port: ($port | tonumber),
                    users: [
                        {
                            uuid: $uuid,
                            password: $password
                        }
                    ],
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        alpn: ["h3", "spdy/3.1"],
                        certificate_path: $cert,
                        key_path: $key
                    }
                }'
            ;;

        *)
            echo -e "${RED}未知协议编号: ${protocol}${PLAIN}" >&2
            return 1
            ;;
    esac
}

generate_config_json() {
    mkdir -p "$CONFIG_DIR"

    local final_dest="${REALITY_DEST:-$DEFAULT_REALITY_DEST}"
    local tmp="${CONFIG_DIR}/config.json.tmp"
    local base config
    local encoded decoded
    local proto port sni identifier password
    local index=0
    local inbound

    [ -x "$SING_BOX_BIN" ] || {
        echo -e "${RED}未找到 sing-box 核心。${PLAIN}"
        return 1
    }

    [ -n "$UUID_REALITY" ] || return 1
    [ -n "$REALITY_PRIVATE" ] || return 1
    [ -n "$REALITY_SHORT_ID" ] || return 1

    base=$(
        make_inbound_json \
            1 \
            "reality-in" \
            "$PORT_REALITY" \
            "$final_dest" \
            "$UUID_REALITY" \
            ""
    ) || return 1

    config=$(
        jq -n \
            --argjson inbound "$base" \
            '
            {
                log: {
                    level: "info",
                    timestamp: true
                },
                inbounds: [$inbound],
                outbounds: [
                    {
                        type: "direct",
                        tag: "direct"
                    }
                ]
            }'
    ) || return 1

    inbound=$(
        make_inbound_json \
            2 \
            "anytls-in" \
            "$PORT_ANYTLS" \
            "${DOMAIN:-$final_dest}" \
            "" \
            "$PASS_ANYTLS"
    ) || return 1

    config=$(jq --argjson inbound "$inbound" '.inbounds += [$inbound]' <<< "$config") || return 1

    inbound=$(
        make_inbound_json \
            3 \
            "any-reality-in" \
            "$PORT_ANYREALITY" \
            "$final_dest" \
            "" \
            "$PASS_ANYREALITY"
    ) || return 1

    config=$(jq --argjson inbound "$inbound" '.inbounds += [$inbound]' <<< "$config") || return 1

    inbound=$(
        make_inbound_json \
            4 \
            "hy2-in" \
            "$PORT_HY2" \
            "${DOMAIN:-$final_dest}" \
            "" \
            "$PASS_HY2"
    ) || return 1

    config=$(jq --argjson inbound "$inbound" '.inbounds += [$inbound]' <<< "$config") || return 1

    inbound=$(
        make_inbound_json \
            5 \
            "tuic-in" \
            "$PORT_TUIC" \
            "${DOMAIN:-$final_dest}" \
            "$UUID_TUIC" \
            "$PASS_TUIC"
    ) || return 1

    config=$(jq --argjson inbound "$inbound" '.inbounds += [$inbound]' <<< "$config") || return 1

    # 加载额外节点
    if [ -f "$EXTRA_NODES_FILE" ]; then
        while IFS= read -r encoded || [ -n "$encoded" ]; do
            [ -z "$encoded" ] && continue

            decoded=$(b64_decode "$encoded" 2>/dev/null) || {
                echo -e "${YELLOW}警告：跳过一条无法解码的额外节点记录。${PLAIN}"
                continue
            }

            IFS=$'\t' read -r proto port sni identifier password <<< "$decoded"

            case "$proto" in
                1 | 2 | 3 | 4 | 5)
                    ;;
                *)
                    echo -e "${YELLOW}警告：跳过未知协议的额外节点记录。${PLAIN}"
                    continue
                    ;;
            esac

            if ! valid_port "$port" || ! valid_domain "$sni"; then
                echo -e "${YELLOW}警告：跳过参数不合法的额外节点记录。${PLAIN}"
                continue
            fi

            index=$((index + 1))

            inbound=$(
                make_inbound_json \
                    "$proto" \
                    "extra-${proto}-${index}" \
                    "$port" \
                    "$sni" \
                    "$identifier" \
                    "$password"
            ) || return 1

            config=$(jq --argjson inbound "$inbound" '.inbounds += [$inbound]' <<< "$config") || return 1
        done < "$EXTRA_NODES_FILE"
    fi

    printf '%s\n' "$config" > "$tmp"

    if "$SING_BOX_BIN" check -c "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "${CONFIG_DIR}/config.json"
        chmod 600 "${CONFIG_DIR}/config.json"
        return 0
    fi

    echo -e "${RED}生成的配置未通过 sing-box 校验：${PLAIN}"
    "$SING_BOX_BIN" check -c "$tmp" 2>&1 | tail -20

    rm -f "$tmp"
    return 1
}

# ================= systemd =================

configure_systemd() {
    local ipt ip6t start_lines="" stop_lines=""

    ipt=$(command -v iptables 2>/dev/null || echo "/usr/sbin/iptables")
    ip6t=$(command -v ip6tables 2>/dev/null || echo "/usr/sbin/ip6tables")

    if [ -n "${PORT_HY2_RANGE:-}" ]; then
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

    systemctl daemon-reload || return 1
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
}

# ================= 额外节点管理 =================

protocol_name() {
    case "$1" in
        1) echo "VLESS + REALITY" ;;
        2) echo "AnyTLS" ;;
        3) echo "Any-Reality" ;;
        4) echo "Hysteria2" ;;
        5) echo "TUIC v5" ;;
        *) echo "未知协议" ;;
    esac
}

ask_sni() {
    local default_sni="$1"
    local sni

    while true; do
        read -r -p "请输入 SNI 域名 [默认 ${default_sni}]: " sni
        sni=${sni:-$default_sni}

        if valid_domain "$sni"; then
            REPLY="$sni"
            return 0
        fi

        echo -e "${RED}SNI 域名格式不正确，请重试。${PLAIN}"
    done
}

append_extra_node() {
    local proto="$1"
    local port="$2"
    local sni="$3"
    local identifier="$4"
    local password="$5"

    mkdir -p "$CONFIG_DIR"

    local record encoded
    record="${proto}"$'\t'"${port}"$'\t'"${sni}"$'\t'"${identifier}"$'\t'"${password}"
    encoded=$(b64_encode "$record")

    printf '%s\n' "$encoded" >> "$EXTRA_NODES_FILE"
    chmod 600 "$EXTRA_NODES_FILE"
}

count_extra_nodes() {
    [ -f "$EXTRA_NODES_FILE" ] || {
        echo 0
        return
    }

    grep -cve '^[[:space:]]*$' "$EXTRA_NODES_FILE" 2>/dev/null || echo 0
}

add_protocol_node() {
    clear

    [ -f "$CONF_FILE" ] || {
        echo -e "${RED}请先完成基础安装，再新增协议节点。${PLAIN}"
        pause
        return
    }

    [ -x "$SING_BOX_BIN" ] || {
        echo -e "${RED}未检测到 sing-box 核心。${PLAIN}"
        pause
        return
    }

    check_deps_extra || {
        pause
        return
    }

    source "$CONF_FILE"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}              新增协议节点                ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo "1. VLESS + REALITY"
    echo "2. AnyTLS"
    echo "3. Any-Reality"
    echo "4. Hysteria2"
    echo "5. TUIC v5"
    echo "0. 返回"
    echo -e "${CYAN}==========================================${PLAIN}"

    local proto
    read -r -p "请选择协议 [0-5]: " proto

    [ "$proto" == "0" ] && return

    case "$proto" in
        1 | 2 | 3 | 4 | 5)
            ;;
        *)
            echo -e "${RED}无效选项。${PLAIN}"
            pause
            return
            ;;
    esac

    collect_all_ports
    ask_new_node_port
    local port="$REPLY"

    local default_sni
    if [ "$proto" == "1" ] || [ "$proto" == "3" ]; then
        default_sni="${REALITY_DEST:-$DEFAULT_REALITY_DEST}"
    else
        default_sni="${DOMAIN:-$DEFAULT_REALITY_DEST}"
    fi

    ask_sni "$default_sni"
    local sni="$REPLY"

    if [ "$proto" != "1" ] &&
        [ "$proto" != "3" ] &&
        [ "${CERT_CHOICE:-1}" != "1" ] &&
        [ "$sni" != "${DOMAIN:-}" ]; then
        echo -e "${YELLOW}警告：当前使用正式证书，SNI ${sni} 与证书域名 ${DOMAIN} 不一致。${PLAIN}"
        echo -e "${YELLOW}客户端进行证书验证时可能失败。${PLAIN}"

        local confirm
        read -r -p "仍要继续新增该节点吗？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return
    fi

    local identifier="" password=""

    case "$proto" in
        1)
            identifier=$(uuidgen 2>/dev/null)
            [ -n "$identifier" ] || {
                echo -e "${RED}uuidgen 执行失败。${PLAIN}"
                pause
                return
            }
            ;;

        2 | 3 | 4)
            password=$(openssl rand -hex 12 2>/dev/null)
            [ -n "$password" ] || {
                echo -e "${RED}生成密码失败。${PLAIN}"
                pause
                return
            }
            ;;

        5)
            identifier=$(uuidgen 2>/dev/null)
            password=$(openssl rand -hex 12 2>/dev/null)

            [ -n "$identifier" ] && [ -n "$password" ] || {
                echo -e "${RED}生成 TUIC 节点凭据失败。${PLAIN}"
                pause
                return
            }
            ;;
    esac

    local old_size=0
    [ -f "$EXTRA_NODES_FILE" ] &&
        old_size=$(stat -c '%s' "$EXTRA_NODES_FILE" 2>/dev/null || echo 0)

    append_extra_node "$proto" "$port" "$sni" "$identifier" "$password"

    if ! generate_config_json; then
        echo -e "${RED}新增节点后配置校验失败，正在回滚。${PLAIN}"

        if [ "$old_size" -gt 0 ]; then
            truncate -s "$old_size" "$EXTRA_NODES_FILE"
        else
            rm -f "$EXTRA_NODES_FILE"
        fi

        generate_config_json >/dev/null 2>&1
        pause
        return
    fi

    if ! configure_systemd; then
        echo -e "${RED}配置已写入，但服务重启失败。${PLAIN}"
        echo -e "${YELLOW}请执行：journalctl -u sing-box -n 50 --no-pager${PLAIN}"
        pause
        return
    fi

    echo -e "${GREEN}✔ 新增节点成功。${PLAIN}"
    echo -e "协议: ${GREEN}$(protocol_name "$proto")${PLAIN}"
    echo -e "端口: ${GREEN}${port}${PLAIN}"
    echo -e "SNI:  ${GREEN}${sni}${PLAIN}"
    echo ""

    case "$proto" in
        1)
            echo -e "UUID: ${GREEN}${identifier}${PLAIN}"
            ;;
        2 | 3 | 4)
            echo -e "密码: ${GREEN}${password}${PLAIN}"
            ;;
        5)
            echo -e "UUID: ${GREEN}${identifier}${PLAIN}"
            echo -e "密码: ${GREEN}${password}${PLAIN}"
            ;;
    esac

    sleep 2
    show_links
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
        echo -e "${RED}本脚本仅支持 Debian/Ubuntu apt 系统。${PLAIN}"
        pause
        return
    fi

    echo -e "\n${GREEN}安装基础依赖...${PLAIN}"

    apt_install \
        curl \
        wget \
        jq \
        openssl \
        socat \
        uuid-runtime \
        cron \
        iptables \
        qrencode \
        iproute2 ||
        {
            pause
            return
        }

    echo -e "\n${YELLOW}=== 1. 证书配置 ===${PLAIN}"

    ask_cert_params || return

    echo -e "\n${YELLOW}=== 2. 协议端口 ===${PLAIN}"

    generate_random_ports
    CHOSEN_PORTS=()

    ask_port "VLESS-REALITY 端口" "$RND_REALITY"
    PORT_REALITY="$REPLY"

    ask_port "标准 AnyTLS 端口" "$RND_ANYTLS"
    PORT_ANYTLS="$REPLY"

    ask_port "Any-Reality 端口" "$RND_ANYREALITY"
    PORT_ANYREALITY="$REPLY"

    ask_port "Hysteria2 端口" "$RND_HY2"
    PORT_HY2="$REPLY"

    local rng

    while true; do
        read -r -p "Hy2 跳跃端口段 (如 20000-30000，直接回车不跳跃): " rng

        if [ -z "$rng" ]; then
            PORT_HY2_RANGE=""
            break
        fi

        if valid_range "$rng"; then
            PORT_HY2_RANGE=$(echo "$rng" | tr '-' ':')
            break
        fi

        echo -e "${RED}格式不正确，应为 起始-结束 且 起始<结束。${PLAIN}"
    done

    ask_port "TUIC v5 端口" "$RND_TUIC"
    PORT_TUIC="$REPLY"

    echo -e "\n${YELLOW}=== 3. REALITY 伪装域名 ===${PLAIN}"

    local dest

    while true; do
        read -r -p "伪装目标域名 [默认: ${DEFAULT_REALITY_DEST}]: " dest
        REALITY_DEST=${dest:-$DEFAULT_REALITY_DEST}

        if valid_domain "$REALITY_DEST"; then
            break
        fi

        echo -e "${RED}伪装目标域名格式不正确，请重试。${PLAIN}"
    done

    echo -e "\n${YELLOW}=== 4. AnyTLS Padding ===${PLAIN}"

    local pad

    read -r -p "自定义 padding（可输入 JSON 片段或完整 JSON 数组，直接回车使用内置配置）: " pad

    if ! set_padding_value "$pad"; then
        echo -e "${RED}输入不是合法 JSON 字符串数组，已改用内置配置。${PLAIN}"
        PADDING_SCHEME_JSON="$DEFAULT_PADDING"
    fi

    echo -e "\n${GREEN}下载 Sing-box 核心...${PLAIN}"

    if ! download_core; then
        echo -e "${RED}安装中止。${PLAIN}"
        pause
        return
    fi

    echo -e "\n${GREEN}签发证书...${PLAIN}"

    if ! issue_cert; then
        echo -e "${RED}证书签发失败，安装中止。${PLAIN}"
        echo -e "${YELLOW}请检查域名解析、80 端口或 Cloudflare 凭证。${PLAIN}"
        pause
        return
    fi

    UUID_REALITY=$(uuidgen 2>/dev/null)
    PASS_ANYTLS=$(openssl rand -hex 12 2>/dev/null)
    PASS_ANYREALITY=$(openssl rand -hex 12 2>/dev/null)
    PASS_HY2=$(openssl rand -hex 12 2>/dev/null)
    UUID_TUIC=$(uuidgen 2>/dev/null)
    PASS_TUIC=$(openssl rand -hex 12 2>/dev/null)

    if [ -z "$UUID_REALITY" ] ||
        [ -z "$PASS_ANYTLS" ] ||
        [ -z "$PASS_ANYREALITY" ] ||
        [ -z "$PASS_HY2" ] ||
        [ -z "$UUID_TUIC" ] ||
        [ -z "$PASS_TUIC" ]; then
        echo -e "${RED}节点凭据生成失败。${PLAIN}"
        pause
        return
    fi

    local keypair
    keypair=$("$SING_BOX_BIN" generate reality-keypair 2>/dev/null)

    REALITY_PRIVATE=$(echo "$keypair" | awk '/PrivateKey/{print $NF}')
    REALITY_PUBLIC=$(echo "$keypair" | awk '/PublicKey/{print $NF}')
    REALITY_SHORT_ID=$("$SING_BOX_BIN" generate rand --hex 8 2>/dev/null)

    if [ -z "$REALITY_PRIVATE" ] ||
        [ -z "$REALITY_PUBLIC" ] ||
        [ -z "$REALITY_SHORT_ID" ]; then
        echo -e "${RED}REALITY 密钥生成失败。${PLAIN}"
        pause
        return
    fi

    mkdir -p "$CONFIG_DIR"
    rm -f "$EXTRA_NODES_FILE"

    save_config

    if ! generate_config_json; then
        echo -e "${RED}配置生成失败，安装中止。${PLAIN}"
        pause
        return
    fi

    if ! configure_systemd; then
        echo -e "${RED}systemd 服务启动失败。${PLAIN}"
        echo -e "${YELLOW}请执行 journalctl -u sing-box -n 50 查看日志。${PLAIN}"
        pause
        return
    fi

    if systemctl is-active --quiet sing-box; then
        echo -e "\n${GREEN}✔ Sing-box 安装成功并已运行。${PLAIN}"
    else
        echo -e "\n${RED}服务未能启动，请执行 journalctl -u sing-box -n 50 查看日志。${PLAIN}"
    fi

    echo -e "${YELLOW}提示: 若启用防火墙/云安全组，请放行上述端口。${PLAIN}"
    echo -e "${YELLOW}Hy2 及 Hy2 跳跃端口段使用 UDP。${PLAIN}"

    sleep 2
    show_links
}

# ================= 证书管理 =================

standalone_cert_manager() {
    clear

    [ -f "$CONF_FILE" ] || {
        echo -e "${RED}未检测到配置！${PLAIN}"
        sleep 2
        return
    }

    source "$CONF_FILE"

    local old_domain="$DOMAIN"
    local old_choice="$CERT_CHOICE"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          独立证书申请与修复模块          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "当前域名: ${GREEN}${DOMAIN:-无}${PLAIN}   当前类型: ${GREEN}${CERT_CHOICE:-未知}${PLAIN}"
    echo ""

    cp -f "$CONF_FILE" "${CONF_FILE}.cert.bak"

    ask_cert_params "back" || {
        rm -f "${CONF_FILE}.cert.bak"
        return
    }

    if ! issue_cert; then
        echo -e "${RED}证书签发失败，恢复原证书配置。${PLAIN}"
        mv -f "${CONF_FILE}.cert.bak" "$CONF_FILE"
        pause
        return
    fi

    save_config
    rm -f "${CONF_FILE}.cert.bak"

    # 从域名证书切回自签时，移除旧域名续期任务
    if [ "$CERT_CHOICE" == "1" ] &&
        [ "$old_choice" != "1" ] &&
        [ -x "$HOME/.acme.sh/acme.sh" ] &&
        [ -n "$old_domain" ]; then
        "$HOME/.acme.sh/acme.sh" \
            --remove \
            -d "$old_domain" \
            --ecc >/dev/null 2>&1
    fi

    if ! systemctl restart sing-box; then
        echo -e "${RED}证书已更新，但 sing-box 重启失败。${PLAIN}"
        pause
        return
    fi

    echo -e "${GREEN}✔ 证书已更新并重启服务。${PLAIN}"
    sleep 1
    show_links
}

# ================= 参数修改 =================

modify_parameters() {
    clear

    [ -f "$CONF_FILE" ] || {
        echo -e "${RED}未检测到配置！${PLAIN}"
        sleep 2
        return
    }

    check_deps_extra || {
        pause
        return
    }

    source "$CONF_FILE"

    [ -z "$REALITY_DEST" ] &&
        REALITY_DEST="$DEFAULT_REALITY_DEST"

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

    local choice np nr npad ndest others oldport

    read -r -p "请选择 [0-7]: " choice
    [ "$choice" == "0" ] && return

    case "$choice" in
        1 | 2 | 3 | 5)
            read -r -p "新端口: " np

            if ! valid_port "$np"; then
                echo -e "${RED}端口无效。${PLAIN}"
                sleep 1
                return
            fi

            case "$choice" in
                1)
                    oldport="$PORT_REALITY"
                    others="$PORT_ANYTLS $PORT_ANYREALITY $PORT_HY2 $PORT_TUIC"
                    ;;
                2)
                    oldport="$PORT_ANYTLS"
                    others="$PORT_REALITY $PORT_ANYREALITY $PORT_HY2 $PORT_TUIC"
                    ;;
                3)
                    oldport="$PORT_ANYREALITY"
                    others="$PORT_REALITY $PORT_ANYTLS $PORT_HY2 $PORT_TUIC"
                    ;;
                5)
                    oldport="$PORT_TUIC"
                    others="$PORT_REALITY $PORT_ANYTLS $PORT_ANYREALITY $PORT_HY2"
                    ;;
            esac

            local extra_port
            while read -r extra_port; do
                [ -n "$extra_port" ] &&
                    others="${others} ${extra_port}"
            done < <(get_extra_ports)

            if [[ " $others " == *" $np "* ]]; then
                echo -e "${RED}端口与其他协议或额外节点冲突。${PLAIN}"
                sleep 1
                return
            fi

            if [ "$np" != "$oldport" ] &&
                port_in_use "$np"; then
                echo -e "${YELLOW}警告：端口 $np 当前已被系统占用。${PLAIN}"

                local confirm
                read -r -p "仍要使用该端口吗？[y/N]: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || return
            fi

            case "$choice" in
                1) PORT_REALITY="$np" ;;
                2) PORT_ANYTLS="$np" ;;
                3) PORT_ANYREALITY="$np" ;;
                5) PORT_TUIC="$np" ;;
            esac
            ;;

        4)
            read -r -p "新 Hy2 主监听端口: " np

            if ! valid_port "$np"; then
                echo -e "${RED}端口无效。${PLAIN}"
                sleep 1
                return
            fi

            local hy2_others="$PORT_REALITY $PORT_ANYTLS $PORT_ANYREALITY $PORT_TUIC"
            local extra_port

            while read -r extra_port; do
                [ -n "$extra_port" ] &&
                    hy2_others="${hy2_others} ${extra_port}"
            done < <(get_extra_ports)

            if [[ " $hy2_others " == *" $np "* ]]; then
                echo -e "${RED}端口与其他协议或额外节点冲突。${PLAIN}"
                sleep 1
                return
            fi

            PORT_HY2="$np"

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
            read -r -p "新 Padding（留空恢复内置）: " npad

            if ! set_padding_value "$npad"; then
                echo -e "${RED}非法 JSON，未修改。${PLAIN}"
                sleep 1
                return
            fi
            ;;

        7)
            read -r -p "新伪装域名: " ndest

            if valid_domain "$ndest"; then
                REALITY_DEST="$ndest"
            else
                echo -e "${RED}域名格式不正确。${PLAIN}"
                sleep 1
                return
            fi
            ;;

        *)
            return
            ;;
    esac

    cp "$CONF_FILE" "${CONF_FILE}.bak"

    save_config

    if generate_config_json; then
        if configure_systemd; then
            rm -f "${CONF_FILE}.bak"

            echo -e "${GREEN}✔ 修改成功，服务已重启。${PLAIN}"
            echo -e "${YELLOW}注意：重启会中断现有连接。${PLAIN}"

            sleep 1
            show_links
        else
            echo -e "${RED}服务重启失败，正在恢复原配置。${PLAIN}"

            mv -f "${CONF_FILE}.bak" "$CONF_FILE"
            source "$CONF_FILE"
            generate_config_json >/dev/null 2>&1
            systemctl restart sing-box >/dev/null 2>&1 || true

            pause
        fi
    else
        echo -e "${RED}新配置未通过校验，已回滚。${PLAIN}"

        mv -f "${CONF_FILE}.bak" "$CONF_FILE"
        source "$CONF_FILE"
        generate_config_json >/dev/null 2>&1

        pause
    fi
}

# ================= 节点链接 =================

build_vless_link() {
    local ip="$1"
    local port="$2"
    local uuid="$3"
    local sni="$4"
    local label="$5"

    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$uuid" \
        "$ip" \
        "$port" \
        "$sni" \
        "$REALITY_PUBLIC" \
        "$REALITY_SHORT_ID" \
        "$label"
}

build_anytls_link() {
    local ip="$1"
    local port="$2"
    local password="$3"
    local sni="$4"
    local insecure="$5"
    local label="$6"

    printf 'anytls://%s@%s:%s?security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&insecure=%s&allowInsecure=%s&type=tcp&headerType=none#%s' \
        "$password" \
        "$ip" \
        "$port" \
        "$sni" \
        "$insecure" \
        "$insecure" \
        "$label"
}

build_anyreality_link() {
    local ip="$1"
    local port="$2"
    local password="$3"
    local sni="$4"
    local label="$5"

    printf 'anytls://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$password" \
        "$ip" \
        "$port" \
        "$sni" \
        "$REALITY_PUBLIC" \
        "$REALITY_SHORT_ID" \
        "$label"
}

build_hy2_link() {
    local ip="$1"
    local port="$2"
    local password="$3"
    local sni="$4"
    local insecure="$5"
    local range="$6"
    local label="$7"

    local extra=""

    [ -n "$range" ] &&
        extra="&ports=${range/:/-}"

    printf 'hy2://%s@%s:%s?insecure=%s&sni=%s%s#%s' \
        "$password" \
        "$ip" \
        "$port" \
        "$insecure" \
        "$sni" \
        "$extra" \
        "$label"
}

build_tuic_link() {
    local ip="$1"
    local port="$2"
    local uuid="$3"
    local password="$4"
    local sni="$5"
    local insecure="$6"
    local label="$7"

    printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&allow_insecure=%s#%s' \
        "$uuid" \
        "$password" \
        "$ip" \
        "$port" \
        "$sni" \
        "$insecure" \
        "$label"
}

show_links() {
    [ -f "$CONF_FILE" ] || {
        echo -e "${RED}未找到配置！${PLAIN}"
        sleep 1
        return
    }

    source "$CONF_FILE"

    check_deps_extra || {
        pause
        return
    }

    get_public_ip || {
        sleep 2
        return
    }

    local final_dest="${REALITY_DEST:-$DEFAULT_REALITY_DEST}"
    local insecure="0"

    [ "$CERT_CHOICE" == "1" ] &&
        insecure="1"

    local -a LINK_NAMES=()
    local -a LINKS=()

    LINK_NAMES+=("VLESS + REALITY")
    LINKS+=(
        "$(build_vless_link \
            "$PUBLIC_IP" \
            "$PORT_REALITY" \
            "$UUID_REALITY" \
            "$final_dest" \
            "${PUBLIC_IP}-VLESS-REALITY")"
    )

    LINK_NAMES+=("标准 AnyTLS")
    LINKS+=(
        "$(build_anytls_link \
            "$PUBLIC_IP" \
            "$PORT_ANYTLS" \
            "$PASS_ANYTLS" \
            "${DOMAIN:-$final_dest}" \
            "$insecure" \
            "${PUBLIC_IP}-AnyTLS")"
    )

    LINK_NAMES+=("Any-Reality")
    LINKS+=(
        "$(build_anyreality_link \
            "$PUBLIC_IP" \
            "$PORT_ANYREALITY" \
            "$PASS_ANYREALITY" \
            "$final_dest" \
            "${PUBLIC_IP}-AnyReality")"
    )

    LINK_NAMES+=("Hysteria2")
    LINKS+=(
        "$(build_hy2_link \
            "$PUBLIC_IP" \
            "$PORT_HY2" \
            "$PASS_HY2" \
            "${DOMAIN:-$final_dest}" \
            "$insecure" \
            "${PORT_HY2_RANGE:-}" \
            "${PUBLIC_IP}-Hysteria2")"
    )

    LINK_NAMES+=("TUIC v5")
    LINKS+=(
        "$(build_tuic_link \
            "$PUBLIC_IP" \
            "$PORT_TUIC" \
            "$UUID_TUIC" \
            "$PASS_TUIC" \
            "${DOMAIN:-$final_dest}" \
            "$insecure" \
            "${PUBLIC_IP}-TUIC")"
    )

    local extra_index=0
    local encoded decoded
    local proto port sni identifier password
    local label link

    if [ -f "$EXTRA_NODES_FILE" ]; then
        while IFS= read -r encoded || [ -n "$encoded" ]; do
            [ -z "$encoded" ] && continue

            decoded=$(b64_decode "$encoded" 2>/dev/null) || continue

            IFS=$'\t' read -r proto port sni identifier password <<< "$decoded"

            case "$proto" in
                1 | 2 | 3 | 4 | 5)
                    ;;
                *)
                    continue
                    ;;
            esac

            valid_port "$port" || continue
            valid_domain "$sni" || continue

            extra_index=$((extra_index + 1))
            label="${PUBLIC_IP}-$(protocol_name "$proto")-节点${extra_index}"

            case "$proto" in
                1)
                    link=$(
                        build_vless_link \
                            "$PUBLIC_IP" \
                            "$port" \
                            "$identifier" \
                            "$sni" \
                            "$label"
                    )
                    ;;

                2)
                    link=$(
                        build_anytls_link \
                            "$PUBLIC_IP" \
                            "$port" \
                            "$password" \
                            "$sni" \
                            "$insecure" \
                            "$label"
                    )
                    ;;

                3)
                    link=$(
                        build_anyreality_link \
                            "$PUBLIC_IP" \
                            "$port" \
                            "$password" \
                            "$sni" \
                            "$label"
                    )
                    ;;

                4)
                    link=$(
                        build_hy2_link \
                            "$PUBLIC_IP" \
                            "$port" \
                            "$password" \
                            "$sni" \
                            "$insecure" \
                            "" \
                            "$label"
                    )
                    ;;

                5)
                    link=$(
                        build_tuic_link \
                            "$PUBLIC_IP" \
                            "$port" \
                            "$identifier" \
                            "$password" \
                            "$sni" \
                            "$insecure" \
                            "$label"
                    )
                    ;;
            esac

            LINK_NAMES+=("$(protocol_name "$proto") - 节点${extra_index}")
            LINKS+=("$link")
        done < "$EXTRA_NODES_FILE"
    fi

    clear

    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${CYAN}              节点链接列表                 ${PLAIN}"
    echo -e "${CYAN}===========================================${PLAIN}"

    local i
    for ((i = 0; i < ${#LINKS[@]}; i++)); do
        echo -e "${GREEN}[$((i + 1))] ${LINK_NAMES[$i]}:${PLAIN}"
        echo "${LINKS[$i]}"
        echo ""
    done

    echo -e "${CYAN}===========================================${PLAIN}"

    local q

    while true; do
        read -r -p "输入节点序号 [1-${#LINKS[@]}] 显示二维码，回车返回主菜单: " q

        if [ -z "$q" ]; then
            return
        fi

        if [[ "$q" =~ ^[0-9]+$ ]] &&
            [ "$q" -ge 1 ] &&
            [ "$q" -le "${#LINKS[@]}" ]; then
            clear
            echo -e "${GREEN}${LINK_NAMES[$((q - 1))]} 二维码:${PLAIN}"
            echo ""

            qrencode -t ANSIUTF8 "${LINKS[$((q - 1))]}"

            echo ""
            read -r -p "按回车返回节点列表..." _
            clear

            echo -e "${CYAN}===========================================${PLAIN}"
            for ((i = 0; i < ${#LINKS[@]}; i++)); do
                echo -e "${GREEN}[$((i + 1))] ${LINK_NAMES[$i]}:${PLAIN}"
                echo "${LINKS[$i]}"
                echo ""
            done
            echo -e "${CYAN}===========================================${PLAIN}"
        else
            echo -e "${RED}无效输入。${PLAIN}"
        fi
    done
}

# ================= 卸载 =================

uninstall_singbox() {
    clear

    local c c2 c3

    read -r -p "确认要彻底卸载 Sing-box 吗？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return

    [ -f "$CONF_FILE" ] &&
        source "$CONF_FILE"

    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1

    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    # 清理 Hy2 跳跃端口规则
    if [ -n "${PORT_HY2_RANGE:-}" ] &&
        [ -n "${PORT_HY2:-}" ]; then
        local ipt ip6t

        ipt=$(command -v iptables 2>/dev/null)
        ip6t=$(command -v ip6tables 2>/dev/null)

        [ -n "$ipt" ] &&
            "$ipt" \
                -t nat \
                -D PREROUTING \
                -p udp \
                --dport "$PORT_HY2_RANGE" \
                -j REDIRECT \
                --to-ports "$PORT_HY2" 2>/dev/null

        [ -n "$ip6t" ] &&
            "$ip6t" \
                -t nat \
                -D PREROUTING \
                -p udp \
                --dport "$PORT_HY2_RANGE" \
                -j REDIRECT \
                --to-ports "$PORT_HY2" 2>/dev/null
    fi

    rm -rf "$CONFIG_DIR"
    rm -f "$SING_BOX_BIN"
    rm -f "${SING_BOX_BIN}.bak"
    rm -f "${SING_BOX_BIN}.new"

    if [ -x "$HOME/.acme.sh/acme.sh" ]; then
        read -r -p "是否同时卸载 acme.sh 及其证书续期任务？[y/N]: " c2

        if [[ "$c2" =~ ^[Yy]$ ]]; then
            "$HOME/.acme.sh/acme.sh" \
                --uninstall >/dev/null 2>&1
            rm -rf "$HOME/.acme.sh"
        fi
    fi

    read -r -p "是否删除 sba 快捷指令？[y/N]: " c3
    [[ "$c3" =~ ^[Yy]$ ]] &&
        rm -f /usr/bin/sba

    echo -e "${GREEN}✔ 卸载完成！${PLAIN}"
    sleep 2
}

# ================= 脚本自更新 =================

update_script() {
    clear

    local target self tmp

    target="/usr/bin/sba"
    self=$(readlink -f "$0" 2>/dev/null)

    if [ -n "$self" ] &&
        [ -f "$self" ] &&
        [[ "$self" != "/usr/bin/sba" ]] &&
        [[ "$self" != "/bin/bash" ]] &&
        [[ "$self" != "/usr/bin/bash" ]]; then
        target="$self"
    fi

    # 临时文件放在目标同目录，保证 mv 是原子替换
    tmp="${target}.update.tmp"

    echo -e "${YELLOW}拉取最新主脚本...${PLAIN}"

    if ! curl "${CURL_OPTS[@]}" \
        -o "$tmp" \
        "${REPO_RAW}/install.sh?t=$(date +%s)"; then
        echo -e "${RED}下载失败，请检查网络或设置 GH_PROXY。${PLAIN}"
        rm -f "$tmp"
        pause
        return
    fi

    if ! bash -n "$tmp" 2>/dev/null; then
        echo -e "${RED}下载的脚本语法校验失败，已取消更新。${PLAIN}"
        rm -f "$tmp"
        pause
        return
    fi

    chmod +x "$tmp"
    mv -f "$tmp" "$target"

    if [ "$target" != "/usr/bin/sba" ]; then
        cp -f "$target" /usr/bin/sba
        chmod +x /usr/bin/sba
    fi

    echo -e "${GREEN}✅ 更新成功，重新加载...${PLAIN}"
    sleep 1

    exec bash "$target"
}

# ================= 远程模块调用 =================

run_remote_module() {
    local name="$1"
    local file="$2"
    local tmp
    local rc

    tmp=$(mktemp /tmp/sba_module.XXXXXX) || return 1

    clear
    echo -e "${YELLOW}正在拉取 ${name} 模块...${PLAIN}"

    # 下载失败时绝不执行残留文件
    if ! curl "${CURL_OPTS[@]}" \
        --max-time 60 \
        -o "$tmp" \
        "${REPO_RAW}/${file}?t=$(date +%s)"; then
        echo -e "${RED}拉取失败！${PLAIN}"
        echo -e "${YELLOW}请检查网络、GH_PROXY 设置或确认仓库中存在 ${file}。${PLAIN}"
        rm -f "$tmp"
        pause
        return
    fi

    if ! bash -n "$tmp" 2>/dev/null; then
        echo -e "${RED}模块语法校验失败，已中止。${PLAIN}"
        rm -f "$tmp"
        pause
        return
    fi

    bash "$tmp"
    rc=$?

    rm -f "$tmp"

    if [ "$rc" -ne 0 ]; then
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

    local bbr_txt svc_txt extra_count

    bbr_txt=$(check_bbr_status)
    extra_count=0

    [ -f "$EXTRA_NODES_FILE" ] &&
        extra_count=$(count_extra_nodes)

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
    echo -e "额外节点: ${GREEN}${extra_count}${PLAIN} 个"
    echo -e "------------------------------------------"
    echo -e "${GREEN}1.${PLAIN}   更新 Sing-box 核心"
    echo -e "${GREEN}2.${PLAIN}   全新安装 / 强制重装 Sing-box"
    echo -e "${GREEN}3.${PLAIN}   修改端口、伪装域名等参数"
    echo -e "${GREEN}4.${PLAIN}   独立申请或修复证书"
    echo -e "${GREEN}5.${PLAIN}   查看节点链接与二维码"
    echo -e "${GREEN}6.${PLAIN}   开启 BBR 加速"
    echo -e "${GREEN}7.${PLAIN}   彻底卸载 Sing-box"
    echo -e "${GREEN}8.${PLAIN}   更新主管理脚本 (SBA)"
    echo -e "${GREEN}9.${PLAIN}   ➡️ 端口转发模块 (远程调用 Realm)"
    echo -e "${GREEN}10.${PLAIN}  ➡️ 家宽接管模块 (远程调用 ISP)"
    echo -e "${GREEN}11.${PLAIN}  新增协议节点"
    echo -e "${GREEN}0.${PLAIN}   退出"
    echo -e "------------------------------------------"
    echo -e "${CYAN}==========================================${PLAIN}"

    local mc
    read -r -p "请输入选项: " mc

    case "$mc" in
        1)
            if [ -f "$CONF_FILE" ]; then
                silent_update_core
            else
                echo -e "${RED}请先安装。${PLAIN}"
                sleep 1
            fi
            ;;

        2)
            fresh_install
            ;;

        3)
            modify_parameters
            ;;

        4)
            standalone_cert_manager
            ;;

        5)
            show_links
            ;;

        6)
            enable_bbr
            ;;

        7)
            uninstall_singbox
            ;;

        8)
            update_script
            ;;

        9)
            run_remote_module "端口转发(Realm)" "realm.sh"
            ;;

        10)
            run_remote_module "家宽接管(ISP)" "isp.sh"
            ;;

        11)
            add_protocol_node
            ;;

        0)
            exit 0
            ;;

        *)
            ;;
    esac
}

# ================= 启动 =================

install_shortcut

while true; do
    start_menu
done
