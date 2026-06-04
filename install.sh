#!/bin/bash

# ==========================================
# Sing-box 高级多协议一键部署脚本 (菜单管理版)
# 特性: sba快捷调用 / 纯净卸载 / 独立随机凭证 / 端口跳跃
# ==========================================

# ！！！非常重要：请将下面的 URL 替换为你 GitHub 仓库中该脚本的真实 Raw 链接 ！！！
SCRIPT_URL="https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="/usr/local/etc/sing-box/cert"
SING_BOX_BIN="/usr/local/bin/sing-box"

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 获取公网 IP
get_public_ip() {
    PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ipv4.icanhazip.com || curl -s4 api.ipify.org)
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP="你的VPS_IP"
    fi
}

# ================= 1. 核心安装模块 =================
main_install() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        开始全新安装 Sing-box 服务        ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    # --- 证书配置 ---
    echo -e "\n${YELLOW}=== 1. 证书模式选择 ===${PLAIN}"
    echo "1. 生成临时自签证书 (有效期10年，适合单纯使用 REALITY / AnyTLS 无需真实域名)"
    echo "2. 申请永久域名证书 (使用 acme.sh，需提前解析真实域名到本机并确保 80 端口空闲)"
    read -p "请输入选项 [1-2]: " CERT_CHOICE
    if [ "$CERT_CHOICE" == "2" ]; then
        read -p "请输入已解析到本机的域名: " DOMAIN
    else
        DOMAIN="bing.com"
    fi

    # --- 端口配置 ---
    echo -e "\n${YELLOW}=== 2. 协议端口设置 ===${PLAIN}"
    read -p "请输入 REALITY 端口 [默认 34433]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-34433}

    read -p "请输入 AnyTLS 端口 [默认 44433]: " PORT_ANYTLS
    PORT_ANYTLS=${PORT_ANYTLS:-44433}

    read -p "请输入 Hysteria2 主监听端口 [默认 54433]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-54433}

    echo -e "\n${CYAN}Hysteria2 端口跳跃 (Port Hopping) 设置:${PLAIN}"
    read -p "请输入 Hy2 跳跃端口段 (如 20000:30000，直接回车表示不开启): " PORT_HY2_RANGE
    PORT_HY2_RANGE=$(echo "$PORT_HY2_RANGE" | tr '-' ':')

    read -p "请输入 TUIC 端口 [默认 54434]: " PORT_TUIC
    PORT_TUIC=${PORT_TUIC:-54434}

    # --- AnyTLS Padding ---
    echo -e "\n${YELLOW}=== 3. AnyTLS 阻断防护 (Padding Scheme) 设置 ===${PLAIN}"
    read -p "请输入自定义 padding-scheme (如需使用内置最强默认配置，请直接回车): " CUSTOM_PADDING

    if [ -z "$CUSTOM_PADDING" ]; then
        PADDING_SCHEME_JSON='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'
    else
        PADDING_SCHEME_JSON="$CUSTOM_PADDING"
    fi
    
    echo -e "\n${GREEN}交互配置完成，开始全自动部署...${PLAIN}\n"
    sleep 2

    # --- 执行部署流程 ---
    install_dependencies
    install_sing_box
    manage_cert
    generate_config
    configure_systemd
    install_sba_shortcut
    show_links
}

install_dependencies() {
    echo -e "${GREEN}[1/5] 正在安装基础依赖...${PLAIN}"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget jq openssl socat uuid-runtime cron iptables > /dev/null 2>&1
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CERT_DIR"
}

install_sing_box() {
    echo -e "${GREEN}[2/5] 正在下载并安装 Sing-box 最新版...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) DL_ARCH="amd64" ;;
        aarch64) DL_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
    
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${DL_ARCH}
}

manage_cert() {
    echo -e "${GREEN}[3/5] 正在处理证书配置...${PLAIN}"
    if [ "$CERT_CHOICE" == "1" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN" > /dev/null 2>&1
    elif [ "$CERT_CHOICE" == "2" ]; then
        curl -s https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
            --fullchain-file "$CERT_DIR/server.crt" \
            --key-file "$CERT_DIR/server.key" \
            --reloadcmd "systemctl restart sing-box"
    fi
}

generate_config() {
    echo -e "${GREEN}[4/5] 正在独立生成各协议的随机凭证...${PLAIN}"
    
    UUID_REALITY=$(uuidgen); PASS_ANYTLS=$(openssl rand -base64 12)
    PASS_HY2=$(openssl rand -base64 12); UUID_TUIC=$(uuidgen); PASS_TUIC=$(openssl rand -base64 12)
    
    REALITY_KEYPAIR=$($SING_BOX_BIN generate reality-keypair)
    REALITY_PRIVATE=$(echo "$REALITY_KEYPAIR" | grep PrivateKey | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$REALITY_KEYPAIR" | grep PublicKey | awk '{print $2}')
    REALITY_SHORT_ID=$($SING_BOX_BIN generate rand --hex 8)

    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": $PORT_REALITY,
      "users": [ { "uuid": "$UUID_REALITY", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": { "enabled": true, "handshake": { "server": "www.microsoft.com", "server_port": 443 }, "private_key": "$REALITY_PRIVATE", "short_id": ["$REALITY_SHORT_ID"] }
      }
    },
    {
      "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": $PORT_ANYTLS,
      "users": [ { "password": "$PASS_ANYTLS" } ],
      "padding_scheme": [ $PADDING_SCHEME_JSON ],
      "tls": { "enabled": true, "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
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
    echo -e "${GREEN}[5/5] 正在配置系统服务及生成分享链接...${PLAIN}"
    IPTABLES_START=""; IPTABLES_STOP=""
    if [ -n "$PORT_HY2_RANGE" ]; then
        IPTABLES_START="ExecStartPost=-/sbin/iptables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2\nExecStartPost=-/sbin/ip6tables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
        IPTABLES_STOP="ExecStopPost=-/sbin/iptables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2\nExecStopPost=-/sbin/ip6tables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
    fi

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org/
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

show_links() {
    get_public_ip
    INSECURE_FLAG="0"
    if [ "$CERT_CHOICE" == "1" ]; then INSECURE_FLAG="1"; fi

    VLESS_LINK="vless://${UUID_REALITY}@${PUBLIC_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#SingBox-REALITY"
    HY2_PORT_DISPLAY=${PORT_HY2}
    if [ -n "$PORT_HY2_RANGE" ]; then HY2_PORT_DISPLAY=${PORT_HY2_RANGE/-/:}; fi
    HY2_LINK="hy2://${PASS_HY2}@${PUBLIC_IP}:${HY2_PORT_DISPLAY}?insecure=${INSECURE_FLAG}&sni=${DOMAIN}#SingBox-Hy2"
    TUIC_LINK="tuic://${UUID_TUIC}:${PASS_TUIC}@${PUBLIC_IP}:${PORT_TUIC}?sni=${DOMAIN}&alpn=h3&allow_insecure=${INSECURE_FLAG}#SingBox-TUIC"

    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${CYAN}        Sing-box 服务端部署成功！           ${PLAIN}"
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}↓↓↓ 复制以下代码直接导入客户端 ↓↓↓${PLAIN}\n"
    echo -e "${GREEN}[1] REALITY:${PLAIN}\n${VLESS_LINK}\n"
    echo -e "${GREEN}[2] Hysteria2:${PLAIN}\n${HY2_LINK}\n"
    echo -e "${GREEN}[3] TUIC v5:${PLAIN}\n${TUIC_LINK}\n"
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}AnyTLS 端口: ${GREEN}$PORT_ANYTLS${PLAIN}  | 密码: ${GREEN}$PASS_ANYTLS${PLAIN}"
    echo -e "${GREEN}提示: 以后可随时在终端输入 sba 呼出管理菜单！${PLAIN}"
    echo -e "${CYAN}===========================================${PLAIN}"
}

# ================= 2. 卸载模块 =================
uninstall_singbox() {
    clear
    echo -e "${RED}警告: 即将卸载 Sing-box 及所有配置文件！${PLAIN}"
    read -p "确认要卸载吗？[y/N]: " UNINSTALL_CONFIRM
    if [[ "$UNINSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在停止并禁用 Sing-box 服务...${PLAIN}"
        systemctl stop sing-box > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
        
        echo -e "${YELLOW}正在清理核心文件与配置...${PLAIN}"
        rm -rf "$CONFIG_DIR"
        rm -f "$SING_BOX_BIN"
        rm -f /usr/bin/sba
        
        echo -e "${GREEN}卸载完成！系统已恢复纯净状态。${PLAIN}"
    else
        echo -e "${GREEN}已取消卸载。${PLAIN}"
    fi
    sleep 2
    start_menu
}

# ================= 3. 主菜单控制流 =================
start_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}      Sing-box 高级部署及管理脚本         ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 安装/更新 Sing-box (多协议防封锁版)"
    echo -e "${GREEN}2.${PLAIN} 彻底卸载 Sing-box"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请输入选项 [0-2]: " MENU_CHOICE
    case "$MENU_CHOICE" in
        1) main_install ;;
        2) uninstall_singbox ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请重新选择！${PLAIN}"; sleep 1; start_menu ;;
    esac
}

# 脚本入口
start_menu
