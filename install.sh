#!/bin/bash

# ==========================================
# Sing-box 五协议主程序 (支持动态调用扩展模块)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 核心配置路径 ---
CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"
CONF_FILE="${CONFIG_DIR}/sba.conf"
SING_BOX_BIN="/usr/local/bin/sing-box"

PUBLIC_IP="" 

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# --- 核心：自动生成 sba 本地快捷指令 ---
# 当你用 bash <(curl...) 执行时，脚本会自动把最新代码下载到本地
if [ ! -f "/usr/bin/sba" ] || [[ "$0" != "/usr/bin/sba" && "$0" != "-bash" && "$0" != "bash" ]]; then
    curl -fsSL -o /usr/bin/sba "https://raw.githubusercontent.com/JBl9527/singbox-all/main/install.sh"
    chmod +x /usr/bin/sba
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
        echo -e "${GREEN}您的系统已经开启了 BBR 加速！${PLAIN}"
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}✔ BBR 加速开启成功！${PLAIN}"
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
    cat > "$CONF_FILE" << EOF_SBA_CONF
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
EOF_SBA_CONF
}

silent_update_core() {
    clear
    check_deps_extra
    echo -e "${YELLOW}正在检测并下载最新版 Sing-box 核心...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in 
        x86_64) DL_ARCH="amd64" ;; 
        aarch64) DL_ARCH="arm64" ;; 
        *) echo -e "${RED}不支持的架构${PLAIN}"; exit 1 ;; 
    esac
    
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    if [ $? -ne 0 ]; then echo -e "${RED}下载失败！${PLAIN}"; sleep 2; start_menu; return; fi
    
    systemctl stop sing-box > /dev/null 2>&1
    tar -xzf sing-box.tar.gz
    mv "sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf sing-box.tar.gz "sing-box-${LATEST_VERSION}-linux-${DL_ARCH}"
    systemctl restart sing-box
    echo -e "${GREEN}✔ Sing-box 核心已成功更新至 v${LATEST_VERSION}！${PLAIN}"
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
    echo "2. 使用 自定义邮箱 申请永久证书 (Standalone 模式)"
    echo "3. 使用 Cloudflare API 申请永久证书 (DNS 模式)"
    read -p "请输入选项 [1-3]: " CERT_CHOICE
    
    if [ "$CERT_CHOICE" == "2" ]; then
        read -p "请输入解析到本机的域名: " DOMAIN
        read -p "请输入 ACME 注册邮箱(用于接通知): " ACME_EMAIL
    elif [ "$CERT_CHOICE" == "3" ]; then
        read -p "请输入托管在 CF 上的域名: " DOMAIN
        read -p "请输入 CF 账号的登录邮箱: " CF_EMAIL
        read -p "请输入 CF Global API Key: " CF_KEY
    else
        CERT_CHOICE="1"
        DOMAIN="bing.com"
    fi

    generate_random_ports

    echo -e "\n${YELLOW}=== 2. 协议端口设置 ===${PLAIN}"
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
    read -p "请输入 REALITY 伪装目标域名 [默认: addons.mozilla.org]: " INPUT_DEST
    REALITY_DEST=${INPUT_DEST:-"addons.mozilla.org"}

    echo -e "\n${YELLOW}=== 4. AnyTLS Padding 设置 ===${PLAIN}"
    read -p "请输入自定义 padding (直接回车使用内置配置): " CUSTOM_PADDING
    if [ -z "$CUSTOM_PADDING" ]; then
        PADDING_SCHEME_JSON='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'
    else 
        PADDING_SCHEME_JSON="$CUSTOM_PADDING"
    fi
    
    echo -e "\n${GREEN}正在安装基础依赖组件...${PLAIN}\n"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget jq openssl socat uuid-runtime cron iptables qrencode > /dev/null 2>&1
    mkdir -p "$CERT_DIR"

    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in 
        x86_64) DL_ARCH="amd64" ;; 
        aarch64) DL_ARCH="arm64" ;; 
        *) exit 1 ;; 
    esac
    
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    mv "sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf sing-box.tar.gz "sing-box-${LATEST_VERSION}-linux-${DL_ARCH}"

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

    UUID_REALITY=$(uuidgen)
    PASS_ANYTLS=$(openssl rand -base64 12)
    PASS_ANYREALITY=$(openssl rand -base64 12)
    PASS_HY2=$(openssl rand -base64 12)
    UUID_TUIC=$(uuidgen)
    PASS_TUIC=$(openssl rand -base64 12)
    
    REALITY_KEYPAIR=$("$SING_BOX_BIN" generate reality-keypair)
    REALITY_PRIVATE=$(echo "$REALITY_KEYPAIR" | grep PrivateKey | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$REALITY_KEYPAIR" | grep PublicKey | awk '{print $2}')
    REALITY_SHORT_ID=$("$SING_BOX_BIN" generate rand --hex 8)

    save_config
    generate_config_json
    configure_systemd
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
        read -p "请输入域名: " NEW_DOMAIN
        DOMAIN=${NEW_DOMAIN:-$DOMAIN}
        read -p "请输入接收通知邮箱: " NEW_EMAIL
        ACME_EMAIL=${NEW_EMAIL:-$ACME_EMAIL}
        CERT_CHOICE="2"
    elif [ "$RE_CERT_CHOICE" == "3" ]; then
        read -p "请输入域名: " NEW_DOMAIN
        DOMAIN=${NEW_DOMAIN:-$DOMAIN}
        read -p "请输入 CF 账号邮箱: " NEW_CF_EMAIL
        CF_EMAIL=${NEW_CF_EMAIL:-$CF_EMAIL}
        read -p "请输入 CF API Key: " NEW_CF_KEY
        CF_KEY=${NEW_CF_KEY:-$CF_KEY}
        CERT_CHOICE="3"
    elif [ "$RE_CERT_CHOICE" == "1" ]; then
        CERT_CHOICE="1"
        DOMAIN="bing.com"
    else
        start_menu
        return
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
    show_links
}

generate_config_json() {
    local FINAL_DEST=${REALITY_DEST:-"www.microsoft.com"}
    cat > "$CONFIG_DIR/config.json" << EOF_SINGBOX_JSON
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
      "tls": { "enabled": true, "server_name": "$FINAL_DEST", "reality": { "enabled": true, "handshake": { "server": "$FINAL_DEST", "server_port": 443 }, "private_key": "$REALITY_PRIVATE", "short_id": ["$REALITY_SHORT_ID"] } }
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
EOF_SINGBOX_JSON
}

configure_systemd() {
    IPTABLES_START=""
    IPTABLES_STOP=""
    if [ -n "$PORT_HY2_RANGE" ]; then
        IPTABLES_START="ExecStartPost=-/sbin/iptables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2\nExecStartPost=-/sbin/ip6tables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
        IPTABLES_STOP="ExecStopPost=-/sbin/iptables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2\nExecStopPost=-/sbin/ip6tables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
    fi

    # 替换实际物理换行来解决 systemd 不支持 \n 的问题
    IPTABLES_START=$(echo -e "$IPTABLES_START")
    IPTABLES_STOP=$(echo -e "$IPTABLES_STOP")

    cat > /etc/systemd/system/sing-box.service << EOF_SINGBOX_SERVICE
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
EOF_SINGBOX_SERVICE

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
        4) 
           read -p "新 Hy2 主监听端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_HY2=$NEW_PORT
           read -p "新 Hy2 跳跃段(清空填none): " NEW_RANGE
           if [ "$NEW_RANGE" == "none" ]; then 
               PORT_HY2_RANGE=""
           elif [ -n "$NEW_RANGE" ]; then 
               PORT_HY2_RANGE=$(echo "$NEW_RANGE" | tr '-' ':')
           fi 
           ;;
        5) read -p "新 TUIC 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_TUIC=$NEW_PORT ;;
        6) read -p "新 Padding: " NEW_PAD; [ -n "$NEW_PAD" ] && PADDING_SCHEME_JSON=$NEW_PAD ;;
        7) read -p "新 REALITY 伪装域名: " NEW_DEST; [ -n "$NEW_DEST" ] && REALITY_DEST=$NEW_DEST ;;
        0) start_menu; return ;;
        *) start_menu; return ;;
    esac

    systemctl stop sing-box
    save_config
    generate_config_json
    configure_systemd
    echo -e "${GREEN}修改成功！参数已联动全套协议。${PLAIN}"
    sleep 1
    show_links
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
        rm -rf "$CONFIG_DIR" "$SING_BOX_BIN"
        echo -e "${GREEN}卸载完成！${PLAIN}"
        sleep 2
    fi
    start_menu
}

# ================= 脚本更新模块 =================
update_script() {
    clear
    echo -e "${YELLOW}正在从 GitHub 拉取最新版主脚本...${PLAIN}"
    
    # 获取脚本的实际路径
    local SCRIPT_PATH=$(readlink -f "$0")
    
    # 如果是通过 bash <(curl ...) 直接执行，可能获取不到真实路径，降级覆盖 /usr/bin/sba
    if [[ "$SCRIPT_PATH" == *"/bash" ]] || [[ "$SCRIPT_PATH" == *"-bash" ]]; then
        SCRIPT_PATH="/usr/bin/sba"
    fi

    # 下载新版本到临时文件
    if curl -fsSL -o "/tmp/sba_update.sh" "https://raw.githubusercontent.com/JBl9527/singbox-all/main/install.sh"; then
        chmod +x "/tmp/sba_update.sh"
        mv -f "/tmp/sba_update.sh" "$SCRIPT_PATH"
        
        # 确保系统快捷命令也同时更新
        if [[ "$SCRIPT_PATH" != "/usr/bin/sba" ]]; then
            cp -f "$SCRIPT_PATH" "/usr/bin/sba"
            chmod +x "/usr/bin/sba"
        fi
        
        echo -e "${GREEN}✅ 主脚本升级成功！正在重新加载...${PLAIN}"
        sleep 2
        # 使用 exec 替换当前 bash 进程，实现无缝重启菜单
        exec bash "$SCRIPT_PATH"
    else
        echo -e "${RED}❌ 升级失败！请检查网络或确认 GitHub RAW 链接是否可访问。${PLAIN}"
        sleep 2
        start_menu
    fi
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
        echo -e "${GREEN}1.${PLAIN} 一键无损更新 Sing-box 核心"
        echo -e "${GREEN}2.${PLAIN} 强制彻底重装 Sing-box"
        echo -e "${GREEN}3.${PLAIN} 动态修改端口、伪装域名等参数"
        echo -e "${GREEN}4.${PLAIN} 独立申请或修复安全证书"
        echo -e "${GREEN}5.${PLAIN} 查看所有节点并生成终端二维码"
        echo -e "${GREEN}6.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}7.${PLAIN} 彻底卸载 Sing-box"
        echo -e "${GREEN}8.${PLAIN} 🔄 更新主管理脚本 (SBA)"
    else
        echo -e "系统状态: ${YELLOW}未安装${PLAIN}   |   BBR加速状态: ${BBR_TXT}"
        echo -e "------------------------------------------"
        echo -e "${YELLOW}[ Sing-box 节点选项 ]${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} 全新安装 Sing-box"
        echo -e "${GREEN}6.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}7.${PLAIN} 彻底卸载 Sing-box"
        echo -e "${GREEN}8.${PLAIN} 🔄 更新主管理脚本 (SBA)"
    fi
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 高级扩展模块 ]${PLAIN}"
    echo -e "${GREEN}9.${PLAIN}  ➡️ ${YELLOW}端口转发管理 (远程动态调用 Realm)${PLAIN}"
    echo -e "${GREEN}10.${PLAIN} ➡️ ${YELLOW}家宽流量接管 (远程动态调用 ISP分流)${PLAIN}"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请输入选项: " MENU_CHOICE
    
    case "$MENU_CHOICE" in
        1) [ -f "$CONF_FILE" ] && silent_update_core || start_menu ;;
        2) fresh_install ;;
        3) [ -f "$CONF_FILE" ] && modify_parameters || start_menu ;;
        4) [ -f "$CONF_FILE" ] && standalone_cert_manager || start_menu ;;
        5) [ -f "$CONF_FILE" ] && show_links || start_menu ;;
        6) enable_bbr ;;
        7) uninstall_singbox ;;
        8) update_script ;;
        9) 
           # --- 核心：动态调用独立的 Realm 模块 ---
           clear
           echo -e "${YELLOW}正在从 GitHub 拉取最新的端口转发(Realm)模块...${PLAIN}"
           curl -fsSL -o /tmp/realm.sh "https://raw.githubusercontent.com/JBl9527/singbox-all/main/realm.sh"
           if [ -f "/tmp/realm.sh" ]; then
               chmod +x /tmp/realm.sh
               bash /tmp/realm.sh
           else
               echo -e "${RED}拉取失败！请检查网络或 GitHub 仓库地址是否正确。${PLAIN}"
               sleep 2
           fi
           start_menu 
           ;;
        10) 
           # --- 核心：动态调用独立的 家宽接管 模块 ---
           clear
           echo -e "${YELLOW}正在从 GitHub 拉取最新的家宽接管(ISP)模块...${PLAIN}"
           # 注意：请确保你把家宽接管脚本保存为 isp.sh 并上传到了 Github
           curl -fsSL -o /tmp/isp.sh "https://raw.githubusercontent.com/JBl9527/singbox-all/main/isp.sh"
           if [ -f "/tmp/isp.sh" ]; then
               chmod +x /tmp/isp.sh
               bash /tmp/isp.sh
           else
               echo -e "${RED}拉取失败！请确保你已将家宽接管脚本命名为 isp.sh 并上传到了 Github。${PLAIN}"
               sleep 2
           fi
           start_menu 
           ;;
        0) exit 0 ;;
        *) start_menu ;;
    esac
}

start_menu
