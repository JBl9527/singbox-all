#!/bin/bash

# ==========================================
# Sing-box 五协议终极版 (动态分区面板)
# 包含: VLESS-REALITY, AnyTLS, Any-Reality, Hy2, TUIC
# 特性: 一键脚本升级 / 随机端口 / 证书双模 / 分区菜单 / 中转支持
# 增强: 内置 REALITY 伪装域名无损修改 / 终端高清晰二维码生成 / 动态节点命名
# ==========================================

SCRIPT_URL="https://raw.githubusercontent.com/JBl9527/sing-box-all/main/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"
CONF_FILE="${CONFIG_DIR}/sba.conf"
SING_BOX_BIN="/usr/local/bin/sing-box"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# ================= 自动化高阶依赖检测 =================
check_deps_extra() {
    local NEED_UPDATE=0
    if ! command -v jq >/dev/null 2>&1 || ! command -v qrencode >/dev/null 2>&1; then
        echo -e "${YELLOW}⟳ 正在检测并安装高阶扩展组件 (jq, qrencode)...${PLAIN}"
        apt-get update -y > /dev/null 2>&1
        apt-get install -y jq qrencode > /dev/null 2>&1
    fi
}

get_public_ip() {
    PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ipv4.icanhazip.com || curl -s4 api.ipify.org)
    if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP="你的VPS_IP"; fi
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
RELAY_IP="${RELAY_IP}"
EOF
}

update_script() {
    clear
    echo -e "${YELLOW}正在从 GitHub 同步最新版 SBA 管理脚本...${PLAIN}"
    install_sba_shortcut
    echo -e "${GREEN}✔ SBA 脚本已成功更新至最新版！${PLAIN}"
    echo -e "${CYAN}即将为您自动重载最新菜单...${PLAIN}"
    sleep 2
    sba
    exit 0
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
    
    echo -e "\n${YELLOW}=== 5. 中转节点(Relay)配置 ===${PLAIN}"
    read -p "是否使用国内/其他中转机接入本节点？(y/N): " USE_RELAY
    if [[ "$USE_RELAY" =~ ^[Yy]$ ]]; then
        read -p "请输入中转机的 IP 地址或域名: " RELAY_IP
    else
        RELAY_IP=""
    fi

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
        echo -e "\n${GREEN}正在生成自签证书...${PLAIN}"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN"
    elif [ "$CERT_CHOICE" == "2" ]; then
        echo -e "\n${GREEN}正在清理旧缓存并使用 Standalone 申请证书...${PLAIN}"
        rm -rf ~/.acme.sh 
        curl -s https://get.acme.sh | sh -s email="sba_cert_${RANDOM}@gmail.com"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/server.crt" --key-file "$CERT_DIR/server.key"
    elif [ "$CERT_CHOICE" == "3" ]; then
        echo -e "\n${GREEN}正在清理旧缓存并使用 Cloudflare DNS API 申请证书...${PLAIN}"
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
    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✔ 证书部署成功，Sing-box 运行正常！${PLAIN}"
    else
        echo -e "${RED}❌ 启动失败！缺少证书文件。${PLAIN}"
    fi
    sleep 3; show_links
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

install_sba_shortcut() {
    cat > /usr/bin/sba <<EOF
#!/bin/bash
bash <(curl -Ls $SCRIPT_URL)
EOF
    chmod +x /usr/bin/sba
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
    echo -e "8. ${YELLOW}修改 中转 IP 地址 (当前: ${RELAY_IP:-未设置})${PLAIN}"
    echo -e "0. 返回主菜单"
    read -p "请选择 [0-8]: " MOD_CHOICE

    case "$MOD_CHOICE" in
        1) read -p "新 REALITY 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_REALITY=$NEW_PORT ;;
        2) read -p "新 AnyTLS 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_ANYTLS=$NEW_PORT ;;
        3) read -p "新 Any-Reality 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_ANYREALITY=$NEW_PORT ;;
        4) read -p "新 Hy2 主监听端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_HY2=$NEW_PORT
           read -p "新 Hy2 跳跃段(清空填none): " NEW_RANGE
           if [ "$NEW_RANGE" == "none" ]; then PORT_HY2_RANGE=""; elif [ -n "$NEW_RANGE" ]; then PORT_HY2_RANGE=$(echo "$NEW_RANGE" | tr '-' ':'); fi ;;
        5) read -p "新 TUIC 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_TUIC=$NEW_PORT ;;
        6) read -p "新 Padding: " NEW_PAD; [ -n "$NEW_PAD" ] && PADDING_SCHEME_JSON=$NEW_PAD ;;
        7) read -p "请输入全新 REALITY 伪装域名 (如 apple.com): " NEW_DEST
           if [ -n "$NEW_DEST" ]; then
               REALITY_DEST=$NEW_DEST
           else
               echo -e "${RED}无效输入，保持原样。${PLAIN}"; sleep 1; modify_parameters; return
           fi ;;
        8) read -p "请输入新的中转 IP (留空则清除): " NEW_RELAY; RELAY_IP=$NEW_RELAY ;;
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

    # 自动检测判定：如果用户设置了中转 IP 则使用中转，否则使用 VPS 直连 IP
    if [ -n "$RELAY_IP" ]; then
        DISPLAY_IP="$RELAY_IP"
    else
        DISPLAY_IP="$PUBLIC_IP"
    fi

    local FINAL_DEST=${REALITY_DEST:-"www.microsoft.com"}
    INSECURE_FLAG="0"
    if [ "$CERT_CHOICE" == "1" ]; then INSECURE_FLAG="1"; fi

    VLESS_LINK="vless://${UUID_REALITY}@${DISPLAY_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${FINAL_DEST}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${DISPLAY_IP}-VLESS-REALITY"
    
    HY2_PORT_DISPLAY=${PORT_HY2}
    if [ -n "$PORT_HY2_RANGE" ]; then HY2_PORT_DISPLAY=${PORT_HY2_RANGE/-/:}; fi
    HY2_LINK="hy2://${PASS_HY2}@${DISPLAY_IP}:${HY2_PORT_DISPLAY}?insecure=${INSECURE_FLAG}&sni=${DOMAIN}#${DISPLAY_IP}-Hysteria2"
    
    TUIC_LINK="tuic://${UUID_TUIC}:${PASS_TUIC}@${DISPLAY_IP}:${PORT_TUIC}?sni=${DOMAIN}&alpn=h3&allow_insecure=${INSECURE_FLAG}#${DISPLAY_IP}-TUIC"
    
    ANYTLS_LINK="anytls://${PASS_ANYTLS}@${DISPLAY_IP}:${PORT_ANYTLS}?security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&insecure=${INSECURE_FLAG}&allowInsecure=${INSECURE_FLAG}&type=tcp&headerType=none#${DISPLAY_IP}-AnyTLS"
    
    ANYREALITY_LINK="anytls://${PASS_ANYREALITY}@${DISPLAY_IP}:${PORT_ANYREALITY}?security=reality&sni=${FINAL_DEST}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${DISPLAY_IP}-AnyReality"

    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}↓↓↓ 您的当前核心节点一键分享链接 ↓↓↓${PLAIN}\n"
    
    if [ -n "$RELAY_IP" ]; then
        echo -e "${YELLOW}>>> 当前已开启中转模式，流量将通过: $RELAY_IP 转发 <<<${PLAIN}\n"
    fi
    
    echo -e "${GREEN}[1] VLESS + REALITY (常规抗封锁):${PLAIN}\n${VLESS_LINK}\n"
    echo -e "${GREEN}[2] 标准 AnyTLS (需真实域名):${PLAIN}\n${ANYTLS_LINK}\n"
    echo -e "${GREEN}[3] 究极 Any-Reality (免证书强混淆):${PLAIN}\n${ANYREALITY_LINK}\n"
    echo -e "${GREEN}[4] Hysteria2 (含UDP端口跳跃):${PLAIN}\n${HY2_LINK}\n"
    echo -e "${GREEN}[5] TUIC v5 (高丢包保活):${PLAIN}\n${TUIC_LINK}\n"
    
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}想要为哪个节点在终端直接渲染二维码？${PLAIN}"
    read -p "请输入对应节点数字 [1-5]，输入其他数字或直接回车返回主菜单: " QR_CHOICE

    case "$QR_CHOICE" in
        1) echo -e "\n${GREEN}==== VLESS-REALITY 节点客户端扫码 ==== ${PLAIN}"
           qrencode -t ANSIUTF8 "$VLESS_LINK" ;;
        2) echo -e "\n${GREEN}==== 标准 AnyTLS 节点客户端扫码 ==== ${PLAIN}"
           qrencode -t ANSIUTF8 "$ANYTLS_LINK" ;;
        3) echo -e "\n${GREEN}==== Any-Reality 节点客户端扫码 ==== ${PLAIN}"
           qrencode -t ANSIUTF8 "$ANYREALITY_LINK" ;;
        4) echo -e "\n${GREEN}==== Hysteria2 节点客户端扫码 ==== ${PLAIN}"
           qrencode -t ANSIUTF8 "$HY2_LINK" ;;
        5) echo -e "\n${GREEN}==== TUIC v5 节点客户端扫码 ==== ${PLAIN}"
           qrencode -t ANSIUTF8 "$TUIC_LINK" ;;
        *) start_menu; return ;;
    esac

    echo ""
    read -n 1 -s -r -p "扫码完毕？按任意键返回主菜单..."
    start_menu
}

uninstall_singbox() {
    clear
    echo -e "${RED}警告: 即将清除所有核心、配置、证书及状态！${PLAIN}"
    read -p "确认要彻底卸载吗？[y/N]: " UNINSTALL_CONFIRM
    if [[ "$UNINSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop sing-box > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
        rm -rf "$CONFIG_DIR"
        rm -rf ~/.acme.sh
        rm -f "$SING_BOX_BIN"
        rm -f /usr/bin/sba
        echo -e "${GREEN}卸载完成！系统已恢复纯净状态。${PLAIN}"
        exit 0
    else
        echo -e "${GREEN}已取消。${PLAIN}"; sleep 1; start_menu
    fi
}

start_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}     Sing-box 五协议终极版管理脚本 (SBA)   ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    BBR_TXT=$(check_bbr_status)
    if [ -f "$CONF_FILE" ]; then
        echo -e "系统状态: ${GREEN}已安装${PLAIN}   |   BBR加速状态: ${BBR_TXT}"
        echo -e "------------------------------------------"
        echo -e "${YELLOW}[ 更新与重装 ]${PLAIN}"
        echo -e "${GREEN}1.${PLAIN} 一键升级 SBA 管理脚本 (同步 GitHub 最新代码)"
        echo -e "${GREEN}2.${PLAIN} 一键无损更新 Sing-box 核心 (保留配置)"
        echo -e "${GREEN}3.${PLAIN} 强制彻底重装 Sing-box (清空并重新配置)"
        echo -e "------------------------------------------"
        echo -e "${YELLOW}[ 配置与管理 ]${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} 动态修改端口、${YELLOW}中转IP${PLAIN}、伪装域名等高级参数"
        echo -e "${GREEN}5.${PLAIN} 独立申请或修复安全证书"
        echo -e "${GREEN}6.${PLAIN} 查看所有节点并${YELLOW}一键生成终端二维码${PLAIN}"
        echo -e "${GREEN}7.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}8.${PLAIN} 彻底卸载 Sing-box"
    else
        echo -e "系统状态: ${YELLOW}未安装${PLAIN}   |   BBR加速状态: ${BBR_TXT}"
        echo -e "------------------------------------------"
        echo -e "${GREEN}3.${PLAIN} 全新安装 Sing-box"
        echo -e "${GREEN}7.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}8.${PLAIN} 彻底卸载 Sing-box"
    fi
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
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    else
        case "$MENU_CHOICE" in
            3) fresh_install ;;
            7) enable_bbr ;;
            8) uninstall_singbox ;;
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    fi
}

start_menu
