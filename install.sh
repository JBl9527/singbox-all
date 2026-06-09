#!/bin/bash

# ==========================================
# Sing-box 五协议终极版 + Realm 动态转发整合版
# 特性: 一键脚本升级 / 随机端口 / 证书双模 / 分区菜单 / 独立的转发模块
# 增强: Realm 端口转发 / 自动检测公网IP动态命名节点 / 禁用强制云端覆盖
# ==========================================

SCRIPT_URL="https://raw.githubusercontent.com/JBl9527/sing-box-all/main/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- Sing-box 核心配置路径 ---
CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"
CONF_FILE="${CONFIG_DIR}/sba.conf"
SING_BOX_BIN="/usr/local/bin/sing-box"

# --- Realm 核心配置路径 ---
REALM_DIR="/root/realm"
REALM_BIN="${REALM_DIR}/realm"
REALM_CONF_DIR="/root/.realm"
REALM_CONF_FILE="${REALM_CONF_DIR}/config.toml"
REALM_SERVICE_FILE="/etc/systemd/system/realm.service"

PUBLIC_IP="" 

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# ================= 公共基础函数 =================

get_public_ip() {
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ipv4.icanhazip.com || curl -s4 api.ipify.org)
        if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP="自动获取失败IP"; fi
    fi
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
    echo -e "${YELLOW}正在检测当前系统 BBR 状态...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo -e "${GREEN}您的系统已经开启了 BBR 加速，无需重复开启！${PLAIN}"
    else
        echo -e "${YELLOW}正在为您的 VPS 注入 BBR 加速内核参数...${PLAIN}"
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            echo -e "${GREEN}✔ BBR 加速开启成功！${PLAIN}"
        else
            echo -e "${RED}❌ BBR 开启失败！部分虚拟化架构不支持。${PLAIN}"
        fi
    fi
    sleep 2
    start_menu
}

# ================= Sing-box 核心模块 =================

check_deps_extra() {
    if ! command -v jq >/dev/null 2>&1 || ! command -v qrencode >/dev/null 2>&1; then
        echo -e "${YELLOW}⟳ 正在检测并安装高阶扩展组件 (jq, qrencode)...${PLAIN}"
        apt-get update -y > /dev/null 2>&1
        apt-get install -y jq qrencode > /dev/null 2>&1
    fi
}

generate_random_ports() {
    USED_PORTS=()
    get_unique_port() {
        local p
        while true; do
            p=$(shuf -i 10000-65535 -n 1)
            if [[ ! " ${USED_PORTS[@]} " =~ " ${p} " ]]; then
                USED_PORTS+=($p)
                echo "$p"
                break
            fi
        done
    }
    RND_REALITY=$(get_unique_port)
    RND_ANYTLS=$(get_unique_port)
    RND_ANYREALITY=$(get_unique_port)
    RND_HY2=$(get_unique_port)
    RND_TUIC=$(get_unique_port)
}

save_config() {
    cat > "$CONF_FILE" <<EOF
CERT_CHOICE="${CERT_CHOICE}"
DOMAIN="${DOMAIN}"
ACME_EMAIL="${ACME_EMAIL}"
CF_EMAIL="${CF_EMAIL}"
CF_KEY="${CF_KEY}"
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
EOF
}

# 【修复一】禁用官方更新，防止覆盖丢失融合版脚本
update_script() {
    clear
    echo -e "${RED}⚠️ 注意：当前为您定制的 Sing-box + Realm 终极融合版！${PLAIN}"
    echo -e "${YELLOW}为防止原作者的普通脚本覆盖掉您的“端口转发”菜单，已屏蔽此更新功能。${PLAIN}"
    echo -e "${CYAN}如果需要更新代码，请手动替换本脚本。${PLAIN}"
    sleep 3
    start_menu
}

# 【修复二】快捷命令生成，直接复制本地脚本，不再从 Github 拉取原版
install_sba_shortcut() {
    if [ -f "$0" ] && [[ "$0" != *"bash"* ]] && [[ "$0" != *"sh"* ]]; then
        cp -f "$0" /usr/bin/sba
        chmod +x /usr/bin/sba
    else
        echo -e "${YELLOW}提示：建议将本脚本文件直接保存到 /usr/bin/sba 以实现快捷呼出。${PLAIN}"
    fi
}

silent_update_core() {
    clear
    echo -e "${YELLOW}正在检测并下载最新版 Sing-box 核心...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) DL_ARCH="amd64" ;; aarch64) DL_ARCH="arm64" ;; *) echo -e "${RED}不支持的架构${PLAIN}"; exit 1 ;; esac
    
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    if [ $? -ne 0 ]; then echo -e "${RED}下载失败！${PLAIN}"; sleep 2; start_menu; return; fi
    
    systemctl stop sing-box > /dev/null 2>&1
    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${DL_ARCH}
    systemctl restart sing-box
    echo -e "${GREEN}✔ Sing-box 核心已成功更新至 v${LATEST_VERSION}！${PLAIN}"
    install_sba_shortcut
    sleep 3
    start_menu
}

fresh_install() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        开始全新重装 Sing-box 服务        ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    echo -e "\n${YELLOW}=== 1. 安全证书配置 ===${PLAIN}"
    echo "1. 生成临时自签证书 (有效期10年，适合无域名场景)"
    echo "2. 使用 自定义邮箱 申请永久证书 (Standalone 模式，需放行 80 端口)"
    echo "3. 使用 Cloudflare API 申请永久证书 (DNS 模式，无需放行 80 端口)"
    read -p "请输入选项 [1-3]: " CERT_CHOICE
    
    if [ "$CERT_CHOICE" == "2" ]; then
        read -p "请输入解析到本机的域名: " DOMAIN
        read -p "请输入 ACME 注册邮箱(用于接通知): " ACME_EMAIL
    elif [ "$CERT_CHOICE" == "3" ]; then
        read -p "请输入托管在 CF 上的域名: " DOMAIN
        read -p "请输入 CF 账号的登录邮箱: " CF_EMAIL
        read -p "请输入 CF Global API Key: " CF_KEY
    else
        CERT_CHOICE="1"; DOMAIN="bing.com"
    fi

    generate_random_ports

    echo -e "\n${YELLOW}=== 2. 协议端口设置 (已自动生成不重复的随机端口) ===${PLAIN}"
    read -p "VLESS-REALITY 端口 [默认 $RND_REALITY]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-$RND_REALITY}
    read -p "标准 AnyTLS 端口 [默认 $RND_ANYTLS]: " PORT_ANYTLS
    PORT_ANYTLS=${PORT_ANYTLS:-$RND_ANYTLS}
    read -p "究极 Any-Reality 端口 [默认 $RND_ANYREALITY]: " PORT_ANYREALITY
    PORT_ANYREALITY=${PORT_ANYREALITY:-$RND_ANYREALITY}
    read -p "Hysteria2 端口 [默认 $RND_HY2]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-$RND_HY2}
    read -p "Hy2 跳跃端口段 (如 20000:30000，直接回车不跳跃): " PORT_HY2_RANGE
    PORT_HY2_RANGE=$(echo "$PORT_HY2_RANGE" | tr '-' ':')
    read -p "TUIC v5 端口 [默认 $RND_TUIC]: " PORT_TUIC
    PORT_TUIC=${PORT_TUIC:-$RND_TUIC}

    echo -e "\n${YELLOW}=== 3. REALITY 伪装域名配置 ===${PLAIN}"
    read -p "请输入 REALITY 伪装目标域名 [默认: www.microsoft.com]: " INPUT_DEST
    REALITY_DEST=${INPUT_DEST:-"www.microsoft.com"}

    echo -e "\n${YELLOW}=== 4. AnyTLS Padding 设置 ===${PLAIN}"
    read -p "请输入自定义 padding-scheme (直接回车使用内置最强配置): " CUSTOM_PADDING
    if [ -z "$CUSTOM_PADDING" ]; then
        PADDING_SCHEME_JSON='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'
    else PADDING_SCHEME_JSON="$CUSTOM_PADDING"; fi
    
    echo -e "\n${GREEN}正在安装基础依赖组件...${PLAIN}\n"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget jq openssl socat uuid-runtime cron iptables qrencode > /dev/null 2>&1
    mkdir -p "$CERT_DIR"

    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) DL_ARCH="amd64" ;; aarch64) DL_ARCH="arm64" ;; *) exit 1 ;; esac
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${DL_ARCH}

    if [ "$CERT_CHOICE" == "1" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN"
    elif [ "$CERT_CHOICE" == "2" ]; then
        rm -rf ~/.acme.sh 
        curl -s https://get.acme.sh | sh -s email="sba_cert_${RANDOM}@gmail.com"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/server.crt" --key-file "$CERT_DIR/server.key"
    elif [ "$CERT_CHOICE" == "3" ]; then
        rm -rf ~/.acme.sh 
        curl -s https://get.acme.sh | sh -s email="sba_cert_${RANDOM}@gmail.com"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        export CF_Key="$CF_KEY"
        export CF_Email="$CF_EMAIL"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -k ec-256 --force
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/server.crt" --key-file "$CERT_DIR/server.key"
    fi

    UUID_REALITY=$(uuidgen); PASS_ANYTLS=$(openssl rand -base64 12)
    PASS_ANYREALITY=$(openssl rand -base64 12); PASS_HY2=$(openssl rand -base64 12)
    UUID_TUIC=$(uuidgen); PASS_TUIC=$(openssl rand -base64 12)
    
    REALITY_KEYPAIR=$($SING_BOX_BIN generate reality-keypair)
    REALITY_PRIVATE=$(echo "$REALITY_KEYPAIR" | grep PrivateKey | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$REALITY_KEYPAIR" | grep PublicKey | awk '{print $2}')
    REALITY_SHORT_ID=$($SING_BOX_BIN generate rand --hex 8)

    save_config
    generate_config_json
    configure_systemd
    install_sba_shortcut
    show_links
}

standalone_cert_manager() {
    clear
    if [ ! -f "$CONF_FILE" ]; then echo -e "${RED}未检测到配置！${PLAIN}"; sleep 2; start_menu; return; fi
    source "$CONF_FILE"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          独立证书申请与修复模块          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${YELLOW}当前绑定的域名: ${GREEN}${DOMAIN:-无}${PLAIN}"
    echo -e "------------------------------------------"
    echo "1. 重新生成 临时自签证书"
    echo "2. 使用 Standalone 模式申请 永久域名证书"
    echo "3. 使用 Cloudflare API 申请 永久域名证书"
    echo "0. 返回主菜单"
    read -p "请输入选项 [0-3]: " RE_CERT_CHOICE

    if [ "$RE_CERT_CHOICE" == "0" ]; then start_menu; return; fi

    if [ "$RE_CERT_CHOICE" == "2" ]; then
        read -p "请输入域名 (默认 $DOMAIN): " NEW_DOMAIN; DOMAIN=${NEW_DOMAIN:-$DOMAIN}
        read -p "请输入接收通知邮箱 (默认 $ACME_EMAIL): " NEW_EMAIL; ACME_EMAIL=${NEW_EMAIL:-$ACME_EMAIL}
        CERT_CHOICE="2"
    elif [ "$RE_CERT_CHOICE" == "3" ]; then
        read -p "请输入域名 (默认 $DOMAIN): " NEW_DOMAIN; DOMAIN=${NEW_DOMAIN:-$DOMAIN}
        read -p "请输入 CF 账号登录邮箱 (默认 $CF_EMAIL): " NEW_CF_EMAIL; CF_EMAIL=${NEW_CF_EMAIL:-$CF_EMAIL}
        read -p "请输入 CF Global API Key: " NEW_CF_KEY; CF_KEY=${NEW_CF_KEY:-$CF_KEY}
        CERT_CHOICE="3"
    elif [ "$RE_CERT_CHOICE" == "1" ]; then
        CERT_CHOICE="1"; DOMAIN="bing.com"
    else
        echo -e "${RED}无效！${PLAIN}"; sleep 1; standalone_cert_manager; return
    fi

    save_config
    mkdir -p "$CERT_DIR"
    systemctl stop sing-box > /dev/null 2>&1

    if [ "$CERT_CHOICE" == "1" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN"
    elif [ "$CERT_CHOICE" == "2" ]; then
        rm -rf ~/.acme.sh
        curl -s https://get.acme.sh | sh -s email="sba_cert_${RANDOM}@gmail.com"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/server.crt" --key-file "$CERT_DIR/server.key"
    elif [ "$CERT_CHOICE" == "3" ]; then
        rm -rf ~/.acme.sh
        curl -s https://get.acme.sh | sh -s email="sba_cert_${RANDOM}@gmail.com"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        export CF_Key="$CF_KEY"
        export CF_Email="$CF_EMAIL"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -k ec-256 --force
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/server.crt" --key-file "$CERT_DIR/server.key"
    fi

    systemctl restart sing-box
    sleep 1; show_links
}

generate_config_json() {
    local FINAL_DEST=${REALITY_DEST:-"www.microsoft.com"}
    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": $PORT_REALITY,
      "users": [ { "uuid": "$UUID_REALITY", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "$FINAL_DEST", "reality": { "enabled": true, "handshake": { "server": "$FINAL_DEST", "server_port": 443 }, "private_key": "$REALITY_PRIVATE", "short_id": ["$REALITY_SHORT_ID"] } }
    },
    {
      "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": $PORT_ANYTLS,
      "users": [ { "password": "$PASS_ANYTLS" } ],
      "padding_scheme": [ $PADDING_SCHEME_JSON ],
      "tls": { "enabled": true, "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
    },
    {
      "type": "anytls", "tag": "any-reality-in", "listen": "::", "listen_port": $PORT_ANYREALITY,
      "users": [ { "password": "$PASS_ANYREALITY" } ],
      "padding_scheme": [ $PADDING_SCHEME_JSON ],
      "tls": { 
          "enabled": true, "server_name": "$FINAL_DEST", 
          "reality": { "enabled": true, "handshake": { "server": "$FINAL_DEST", "server_port": 443 }, "private_key": "$REALITY_PRIVATE", "short_id": ["$REALITY_SHORT_ID"] } 
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $PORT_HY2,
      "users": [ { "password": "$PASS_HY2" } ],
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
    },
    {
      "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": $PORT_TUIC,
      "users": [ { "uuid": "$UUID_TUIC", "password": "$PASS_TUIC" } ],
      "tls": { "enabled": true, "alpn": ["h3", "spdy/3.1"], "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" } ]
}
EOF
}

configure_systemd() {
    IPTABLES_START=""; IPTABLES_STOP=""
    if [ -n "$PORT_HY2_RANGE" ]; then
        IPTABLES_START="ExecStartPost=-/sbin/iptables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2\nExecStartPost=-/sbin/ip6tables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
        IPTABLES_STOP="ExecStopPost=-/sbin/iptables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2\nExecStopPost=-/sbin/ip6tables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
    fi

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$SING_BOX_BIN run -c $CONFIG_DIR/config.json
${IPTABLES_START}
${IPTABLES_STOP}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box > /dev/null 2>&1
    systemctl restart sing-box
}

modify_parameters() {
    clear
    if [ ! -f "$CONF_FILE" ]; then echo -e "${RED}未检测到配置！${PLAIN}"; sleep 2; start_menu; return; fi
    source "$CONF_FILE"

    [ -z "$REALITY_DEST" ] && REALITY_DEST="www.microsoft.com"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        动态修改节点参数 (无损重载)         ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "1. 修改 REALITY 端口 (当前: $PORT_REALITY)"
    echo -e "2. 修改 AnyTLS 端口 (当前: $PORT_ANYTLS)"
    echo -e "3. 修改 Any-Reality 端口 (当前: $PORT_ANYREALITY)"
    echo -e "4. 修改 Hysteria2 端口 (当前: $PORT_HY2)"
    echo -e "5. 修改 TUIC v5 端口 (当前: $PORT_TUIC)"
    echo -e "6. 修改 AnyTLS/Any-Reality Padding Scheme"
    echo -e "7. ${YELLOW}修改 REALITY 伪装域名 (当前: $REALITY_DEST)${PLAIN}"
    echo -e "0. 返回主菜单"
    read -p "请选择 [0-7]: " MOD_CHOICE

    case "$MOD_CHOICE" in
        1) read -p "新 REALITY 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_REALITY=$NEW_PORT ;;
        2) read -p "新 AnyTLS 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_ANYTLS=$NEW_PORT ;;
        3) read -p "新 Any-Reality 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_ANYREALITY=$NEW_PORT ;;
        4) read -p "新 Hy2 主监听端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_HY2=$NEW_PORT
           read -p "新 Hy2 跳跃段(清空填none): " NEW_RANGE
           if [ "$NEW_RANGE" == "none" ]; then PORT_HY2_RANGE=""; elif [ -n "$NEW_RANGE" ]; then PORT_HY2_RANGE=$(echo "$NEW_RANGE" | tr '-' ':'); fi ;;
        5) read -p "新 TUIC 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_TUIC=$NEW_PORT ;;
        6) read -p "新 Padding: " NEW_PAD; [ -n "$NEW_PAD" ] && PADDING_SCHEME_JSON=$NEW_PAD ;;
        7) read -p "请输入全新 REALITY 伪装域名 (如 apple.com): " NEW_DEST; [ -n "$NEW_DEST" ] && REALITY_DEST=$NEW_DEST ;;
        0) start_menu; return ;;
        *) echo -e "${RED}无效！${PLAIN}"; sleep 1; modify_parameters; return ;;
    esac

    systemctl stop sing-box
    save_config
    generate_config_json
    configure_systemd
    echo -e "${GREEN}修改成功！参数已生效并已联动全套协议。${PLAIN}"; sleep 1; show_links
}

show_links() {
    if [ ! -f "$CONF_FILE" ]; then echo "未找到配置！"; sleep 1; return; fi
    source "$CONF_FILE"
    check_deps_extra
    get_public_ip

    local FINAL_DEST=${REALITY_DEST:-"www.microsoft.com"}
    INSECURE_FLAG="0"
    if [ "$CERT_CHOICE" == "1" ]; then INSECURE_FLAG="1"; fi

    VLESS_LINK="vless://${UUID_REALITY}@${PUBLIC_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${FINAL_DEST}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${PUBLIC_IP}-VLESS-REALITY"
    
    HY2_PORT_DISPLAY=${PORT_HY2}
    if [ -n "$PORT_HY2_RANGE" ]; then HY2_PORT_DISPLAY=${PORT_HY2_RANGE/-/:}; fi
    HY2_LINK="hy2://${PASS_HY2}@${PUBLIC_IP}:${HY2_PORT_DISPLAY}?insecure=${INSECURE_FLAG}&sni=${DOMAIN}#${PUBLIC_IP}-Hysteria2"
    
    TUIC_LINK="tuic://${UUID_TUIC}:${PASS_TUIC}@${PUBLIC_IP}:${PORT_TUIC}?sni=${DOMAIN}&alpn=h3&allow_insecure=${INSECURE_FLAG}#${PUBLIC_IP}-TUIC"
    
    ANYTLS_LINK="anytls://${PASS_ANYTLS}@${PUBLIC_IP}:${PORT_ANYTLS}?security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&insecure=${INSECURE_FLAG}&allowInsecure=${INSECURE_FLAG}&type=tcp&headerType=none#${PUBLIC_IP}-AnyTLS"
    
    ANYREALITY_LINK="anytls://${PASS_ANYREALITY}@${PUBLIC_IP}:${PORT_ANYREALITY}?security=reality&sni=${FINAL_DEST}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${PUBLIC_IP}-AnyReality"

    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}↓↓↓ 您的当前核心节点一键分享链接 ↓↓↓${PLAIN}\n"
    
    echo -e "${GREEN}[1] VLESS + REALITY:${PLAIN}\n${VLESS_LINK}\n"
    echo -e "${GREEN}[2] 标准 AnyTLS:${PLAIN}\n${ANYTLS_LINK}\n"
    echo -e "${GREEN}[3] 究极 Any-Reality:${PLAIN}\n${ANYREALITY_LINK}\n"
    echo -e "${GREEN}[4] Hysteria2:${PLAIN}\n${HY2_LINK}\n"
    echo -e "${GREEN}[5] TUIC v5:${PLAIN}\n${TUIC_LINK}\n"
    
    echo -e "${CYAN}===========================================${PLAIN}"
    read -p "需要显示二维码请输入节点数字 [1-5]，回车返回主菜单: " QR_CHOICE

    case "$QR_CHOICE" in
        1) qrencode -t ANSIUTF8 "$VLESS_LINK" ;;
        2) qrencode -t ANSIUTF8 "$ANYTLS_LINK" ;;
        3) qrencode -t ANSIUTF8 "$ANYREALITY_LINK" ;;
        4) qrencode -t ANSIUTF8 "$HY2_LINK" ;;
        5) qrencode -t ANSIUTF8 "$TUIC_LINK" ;;
        *) start_menu; return ;;
    esac

    echo ""
    read -n 1 -s -r -p "扫码完毕？按任意键返回主菜单..."
    start_menu
}

uninstall_singbox() {
    clear
    read -p "确认要彻底卸载 Sing-box 吗？[y/N]: " UNINSTALL_CONFIRM
    if [[ "$UNINSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop sing-box > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
        rm -rf "$CONFIG_DIR"
        rm -f "$SING_BOX_BIN"
        echo -e "${GREEN}卸载完成！${PLAIN}"
        sleep 2
    fi
    start_menu
}


# ================= Realm 端口转发独立模块 =================

get_realm_status() {
    if systemctl is-active --quiet realm; then echo -e "${GREEN}运行中${PLAIN}"; else echo -e "${RED}未运行${PLAIN}"; fi
}

install_realm() {
    echo -e "${YELLOW}>>> 正在部署 Realm 转发服务...${PLAIN}"
    mkdir -p "$REALM_DIR" "$REALM_CONF_DIR"
    [ ! -f "$REALM_CONF_FILE" ] && cat <<EOF > "$REALM_CONF_FILE"
[network]
no_tcp = false
use_udp = true

EOF

    local version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$version" ] && version="v2.6.0"
    local arch=$(uname -m)
    local filename=""
    case "$arch" in
        x86_64) filename="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64) filename="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) echo -e "${RED}不支持架构: $arch${PLAIN}"; sleep 2; return ;;
    esac

    wget -qO "/tmp/realm.tar.gz" "https://github.com/zhboner/realm/releases/download/${version}/${filename}"
    tar -xzf /tmp/realm.tar.gz -C "$REALM_DIR" && rm -f /tmp/realm.tar.gz
    chmod +x "$REALM_BIN"

    cat <<EOF > "$REALM_SERVICE_FILE"
[Unit]
Description=Realm Forwarding Service
After=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_BIN} -c ${REALM_CONF_FILE}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable realm >/dev/null 2>&1; systemctl restart realm
    echo -e "${GREEN}✔ Realm 转发服务安装完成并已启动！${PLAIN}"
    sleep 2
}

realm_add_forward() {
    if [ ! -f "$REALM_BIN" ]; then install_realm; fi
    clear
    echo -e "${YELLOW}>>> 添加单端口转发 (Realm)${PLAIN}"
    read -p "请输入本机监听端口: " lp
    read -p "请输入目标落地 IP/域名: " rip
    read -p "请输入目标落地端口: " rp
    
    get_public_ip
    read -p "请输入此节点协议名称(如 VLESS, Hy2，回车默认填Realm): " protocol
    protocol=${protocol:-Realm}
    node_name="${PUBLIC_IP}-${protocol}"

    cat <<EOF >> "$REALM_CONF_FILE"

# 节点名称: $node_name
[[endpoints]]
listen = "[::]:$lp"
remote = "$rip:$rp"
EOF
    systemctl restart realm
    echo -e "${GREEN}✔ 转发规则添加成功！${PLAIN}"
    echo -e "自动命名节点: ${YELLOW}${node_name}${PLAIN}  |  本机中转端口: ${YELLOW}${lp}${PLAIN}"
    sleep 3
}

realm_add_range() {
    if [ ! -f "$REALM_BIN" ]; then install_realm; fi
    clear
    echo -e "${YELLOW}>>> 添加端口段转发 (Realm)${PLAIN}"
    read -p "请输入起始端口: " sp
    read -p "请输入结束端口: " ep
    read -p "请输入目标落地 IP/域名: " rip
    read -p "请输入目标落地基准端口: " rbp

    get_public_ip
    read -p "请输入此节点协议名称(如 VLESS, Hy2，回车默认填Realm): " protocol
    protocol=${protocol:-Realm}

    local rp=$rbp
    for ((p=$sp; p<=$ep; p++)); do
        if ! grep -q "listen = \"[::]:$p\"" "$REALM_CONF_FILE"; then
            cat <<EOF >> "$REALM_CONF_FILE"

# 节点名称: ${PUBLIC_IP}-${protocol}-端口${p}
[[endpoints]]
listen = "[::]:$p"
remote = "$rip:$rp"
EOF
        fi
        ((rp++))
    done
    systemctl restart realm
    echo -e "${GREEN}✔ 端口段转发规则添加成功！${PLAIN}"
    sleep 2
}

realm_delete_forward() {
    if [ ! -f "$REALM_CONF_FILE" ]; then echo "没有找到配置文件！"; sleep 2; return; fi
    local listens=($(grep "listen =" "$REALM_CONF_FILE" | awk -F'"' '{print $2}'))
    local remotes=($(grep "remote =" "$REALM_CONF_FILE" | awk -F'"' '{print $2}'))
    local remarks=($(grep -B 1 "listen =" "$REALM_CONF_FILE" | grep "^#" | awk -F': ' '{print $2}'))

    if [ ${#listens[@]} -eq 0 ]; then echo "当前没有任何转发规则。"; sleep 2; return; fi

    clear
    echo -e "${CYAN}=== 当前 Realm 转发规则 ===${PLAIN}"
    for ((i=0; i<${#listens[@]}; i++)); do
        local d_remark=${remarks[i]:-"未命名节点"}
        echo -e "${GREEN}$((i+1)).${PLAIN} [${YELLOW}${d_remark}${PLAIN}] ${listens[i]} -> ${remotes[i]}"
    done
    echo "==========================="
    read -p "请输入要删除的规则序号 (输入 0 取消): " c
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#listens[@]}" ]; then
        cp "$REALM_CONF_FILE" "${REALM_CONF_FILE}.bak"
        cat <<EOF > "$REALM_CONF_FILE"
[network]
no_tcp = false
use_udp = true

EOF
        local del_idx=$((c-1))
        for ((i=0; i<${#listens[@]}; i++)); do
            if [ $i -ne $del_idx ]; then
                local p_remark=${remarks[i]:-"自动重写节点"}
                cat <<EOF >> "$REALM_CONF_FILE"

# 节点名称: ${p_remark}
[[endpoints]]
listen = "${listens[i]}"
remote = "${remotes[i]}"
EOF
            fi
        done
        systemctl restart realm
        echo -e "${GREEN}删除成功！${PLAIN}"
    fi
    sleep 2
}

realm_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${PLAIN}"
        echo -e "${CYAN}        端口转发管理 (独立 Realm 模块)    ${PLAIN}"
        echo -e "${CYAN}==========================================${PLAIN}"
        if [ -f "$REALM_BIN" ]; then
            echo -e "Realm 转发状态: $(get_realm_status)"
            echo -e "------------------------------------------"
            echo -e "${GREEN}1.${PLAIN} ➕ 添加单端口转发"
            echo -e "${GREEN}2.${PLAIN} ➕ 添加端口段转发"
            echo -e "${GREEN}3.${PLAIN} 📋 查看或删除转发规则"
            echo -e "${GREEN}4.${PLAIN} 🗑 彻底卸载 Realm 转发服务"
        else
            echo -e "Realm 转发状态: ${YELLOW}未安装${PLAIN}"
            echo -e "------------------------------------------"
            echo -e "${GREEN}1.${PLAIN} 🚀 立即安装 Realm 并添加转发规则"
        fi
        echo -e "${GREEN}0.${PLAIN} 🔙 返回上一级主菜单"
        echo -e "${CYAN}==========================================${PLAIN}"
        read -p "请输入选项: " RMENU_CHOICE

        case "$RMENU_CHOICE" in
            1) if [ ! -f "$REALM_BIN" ]; then install_realm; fi; realm_add_forward ;;
            2) realm_add_range ;;
            3) realm_delete_forward ;;
            4) 
               systemctl stop realm >/dev/null 2>&1; systemctl disable realm >/dev/null 2>&1
               rm -f "$REALM_SERVICE_FILE"; systemctl daemon-reload
               rm -rf "$REALM_DIR" "$REALM_CONF_DIR"
               echo -e "${GREEN}Realm 已彻底卸载！${PLAIN}"; sleep 2 ;;
            0) break ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ================= 首页主菜单 =================

start_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}     Sing-box 五协议终极版管理脚本 (SBA)   ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    BBR_TXT=$(check_bbr_status)
    if [ -f "$CONF_FILE" ]; then
        echo -e "系统状态: ${GREEN}已安装${PLAIN}   |   BBR加速状态: ${BBR_TXT}"
        echo -e "------------------------------------------"
        echo -e "${YELLOW}[ Sing-box 节点选项 ]${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 一键升级 SBA 管理脚本"
        echo -e "${GREEN}2.${PLAIN} 一键无损更新 Sing-box 核心 (保留配置)"
        echo -e "${GREEN}3.${PLAIN} 强制彻底重装 Sing-box"
        echo -e "${GREEN}4.${PLAIN} 动态修改端口、伪装域名等参数"
        echo -e "${GREEN}5.${PLAIN} 独立申请或修复安全证书"
        echo -e "${GREEN}6.${PLAIN} 查看所有节点并生成终端二维码"
        echo -e "${GREEN}7.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}8.${PLAIN} 彻底卸载 Sing-box"
    else
        echo -e "系统状态: ${YELLOW}未安装${PLAIN}   |   BBR加速状态: ${BBR_TXT}"
        echo -e "------------------------------------------"
        echo -e "${YELLOW}[ Sing-box 节点选项 ]${PLAIN}"
        echo -e "${GREEN}3.${PLAIN} 全新安装 Sing-box"
        echo -e "${GREEN}7.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}8.${PLAIN} 彻底卸载 Sing-box"
    fi
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 高级扩展模块 ]${PLAIN}"
    echo -e "${GREEN}9.${PLAIN} ➡️ ${YELLOW}端口转发管理 (基于 Realm)${PLAIN}"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请输入选项: " MENU_CHOICE
    
    if [ -f "$CONF_FILE" ]; then
        case "$MENU_CHOICE" in
            1) update_script ;;
            2) silent_update_core ;;
            3) fresh_install ;;
            4) modify_parameters ;;
            5) standalone_cert_manager ;;
            6) show_links ;;
            7) enable_bbr ;;
            8) uninstall_singbox ;;
            9) realm_menu; start_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    else
        case "$MENU_CHOICE" in
            3) fresh_install ;;
            7) enable_bbr ;;
            8) uninstall_singbox ;;
            9) realm_menu; start_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    fi
}

start_menu
