#!/bin/bash

# ==========================================
# Sing-box 终极多协议管理脚本 (ACME 修复版)
# 特性: 智能菜单 / 解决 ACME 邮箱封禁 / 动态修参 / 一键BBR
# ==========================================

SCRIPT_URL="https://raw.githubusercontent.com/JBl9527/singbox-all/main/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="${CONFIG_DIR}/cert"
CONF_FILE="${CONFIG_DIR}/sba.conf"
SING_BOX_BIN="/usr/local/bin/sing-box"

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 获取公网 IP
get_public_ip() {
    PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ipv4.icanhazip.com || curl -s4 api.ipify.org)
    if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP="你的VPS_IP"; fi
}

# 检测 BBR 状态
check_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo -e "${GREEN}已开启${PLAIN}"
    else
        echo -e "${RED}未开启${PLAIN}"
    fi
}

# 一键开启 BBR 网络加速
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
            echo -e "${RED}❌ BBR 开启失败！部分 OpenVZ 架构的 VPS 不支持修改内核参数。${PLAIN}"
        fi
    fi
    sleep 2
    start_menu
}

# 保存配置
save_config() {
    cat > "$CONF_FILE" <<EOF
CERT_CHOICE="${CERT_CHOICE}"
DOMAIN="${DOMAIN}"
PORT_REALITY="${PORT_REALITY}"
PORT_ANYTLS="${PORT_ANYTLS}"
PORT_HY2="${PORT_HY2}"
PORT_HY2_RANGE="${PORT_HY2_RANGE}"
PORT_TUIC="${PORT_TUIC}"
PADDING_SCHEME_JSON='${PADDING_SCHEME_JSON}'
UUID_REALITY="${UUID_REALITY}"
PASS_ANYTLS="${PASS_ANYTLS}"
PASS_HY2="${PASS_HY2}"
UUID_TUIC="${UUID_TUIC}"
PASS_TUIC="${PASS_TUIC}"
REALITY_PRIVATE="${REALITY_PRIVATE}"
REALITY_PUBLIC="${REALITY_PUBLIC}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
EOF
}

# 静默更新二进制核心
silent_update_core() {
    clear
    echo -e "${YELLOW}正在检测并下载最新版 Sing-box 核心...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) DL_ARCH="amd64" ;; aarch64) DL_ARCH="arm64" ;; *) echo -e "${RED}不支持的架构${PLAIN}"; exit 1 ;;
    esac
    
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络！${PLAIN}"
        sleep 2; start_menu; return
    fi
    
    systemctl stop sing-box > /dev/null 2>&1
    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${DL_ARCH}
    
    systemctl restart sing-box
    echo -e "${GREEN}✔ Sing-box 核心已成功无损更新至 v${LATEST_VERSION}！${PLAIN}"
    install_sba_shortcut
    sleep 3
    start_menu
}

# 全新安装流程
fresh_install() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        开始全新安装 Sing-box 服务        ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    echo -e "\n${YELLOW}=== 1. 证书模式选择 ===${PLAIN}"
    echo "1. 生成临时自签证书 (有效期10年，适合单纯使用 REALITY / AnyTLS 无需真实域名)"
    echo "2. 申请永久域名证书 (使用 acme.sh，需提前解析真实域名到本机并确保 80 端口空闲)"
    read -p "请输入选项 [1-2]: " CERT_CHOICE
    if [ "$CERT_CHOICE" == "2" ]; then read -p "请输入已解析到本机的域名: " DOMAIN; else DOMAIN="bing.com"; fi

    echo -e "\n${YELLOW}=== 2. 协议端口设置 ===${PLAIN}"
    read -p "请输入 REALITY 端口 [默认 34433]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-34433}
    read -p "请输入 AnyTLS 端口 [默认 44433]: " PORT_ANYTLS
    PORT_ANYTLS=${PORT_ANYTLS:-44433}
    read -p "请输入 Hysteria2 主监听端口 [默认 54433]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-54433}
    read -p "请输入 Hy2 跳跃端口段 (如 20000:30000，直接回车不跳跃): " PORT_HY2_RANGE
    PORT_HY2_RANGE=$(echo "$PORT_HY2_RANGE" | tr '-' ':')
    read -p "请输入 TUIC 端口 [默认 54434]: " PORT_TUIC
    PORT_TUIC=${PORT_TUIC:-54434}

    echo -e "\n${YELLOW}=== 3. AnyTLS 阻断防护 (Padding) 设置 ===${PLAIN}"
    read -p "请输入自定义 padding-scheme (直接回车使用最强默认配置): " CUSTOM_PADDING
    if [ -z "$CUSTOM_PADDING" ]; then
        PADDING_SCHEME_JSON='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'
    else PADDING_SCHEME_JSON="$CUSTOM_PADDING"; fi
    
    echo -e "\n${GREEN}正在安装基础依赖组件...${PLAIN}\n"
    apt-get update -y
    apt-get install -y curl wget jq openssl socat uuid-runtime cron iptables
    mkdir -p "$CERT_DIR"

    # 安装核心
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) DL_ARCH="amd64" ;; aarch64) DL_ARCH="arm64" ;; *) exit 1 ;; esac
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${DL_ARCH}

    # 证书生成逻辑 (解决 example.com 封禁问题)
    if [ "$CERT_CHOICE" == "1" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN"
    elif [ "$CERT_CHOICE" == "2" ]; then
        curl -s https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        # 【核心修复点】显式注册一个绝对不会被封禁的自定义合法邮箱
        ~/.acme.sh/acme.sh --register-account -m sba_admin2026@gmail.com --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc --fullchain-file "$CERT_DIR/server.crt" --key-file "$CERT_DIR/server.key" --reloadcmd "systemctl restart sing-box"
    fi

    # 凭证独立生成
    UUID_REALITY=$(uuidgen); PASS_ANYTLS=$(openssl rand -base64 12)
    PASS_HY2=$(openssl rand -base64 12); UUID_TUIC=$(uuidgen); PASS_TUIC=$(openssl rand -base64 12)
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

generate_config_json() {
    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": $PORT_REALITY,
      "users": [ { "uuid": "$UUID_REALITY", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "www.microsoft.com", "reality": { "enabled": true, "handshake": { "server": "www.microsoft.com", "server_port": 443 }, "private_key": "$REALITY_PRIVATE", "short_id": ["$REALITY_SHORT_ID"] } }
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

# 动态修改参数
modify_parameters() {
    clear
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}未检测到配置文件，请先选择安装！${PLAIN}"
        sleep 2; start_menu; return
    fi
    source "$CONF_FILE"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        动态修改节点参数 (无损重载)         ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "1. 修改 REALITY 端口 (当前: $PORT_REALITY)"
    echo -e "2. 修改 AnyTLS 端口 (当前: $PORT_ANYTLS)"
    echo -e "3. 修改 Hysteria2 端口及跳跃"
    echo -e "4. 修改 TUIC 端口 (当前: $PORT_TUIC)"
    echo -e "5. 修改 AnyTLS Padding Scheme"
    echo -e "0. 返回主菜单"
    read -p "请选择需要修改的选项 [0-5]: " MOD_CHOICE

    case "$MOD_CHOICE" in
        1) read -p "输入新的 REALITY 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_REALITY=$NEW_PORT ;;
        2) read -p "输入新的 AnyTLS 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_ANYTLS=$NEW_PORT ;;
        3) 
           read -p "输入新的主监听端口 (当前 $PORT_HY2): " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_HY2=$NEW_PORT
           read -p "输入新的跳跃端口段 (当前 $PORT_HY2_RANGE，清空请输入 none): " NEW_RANGE
           if [ "$NEW_RANGE" == "none" ]; then PORT_HY2_RANGE=""; elif [ -n "$NEW_RANGE" ]; then PORT_HY2_RANGE=$(echo "$NEW_RANGE" | tr '-' ':'); fi
           ;;
        4) read -p "输入新的 TUIC 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_TUIC=$NEW_PORT ;;
        5) 
           echo "当前 Padding: $PADDING_SCHEME_JSON"
           read -p "输入新的 Padding 规则: " NEW_PAD; [ -n "$NEW_PAD" ] && PADDING_SCHEME_JSON=$NEW_PAD ;;
        0) start_menu; return ;;
        *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; modify_parameters; return ;;
    esac

    systemctl stop sing-box
    save_config
    generate_config_json
    configure_systemd
    echo -e "${GREEN}修改成功！参数已生效。${PLAIN}"
    sleep 1
    show_links
}

# 链接展示
show_links() {
    if [ ! -f "$CONF_FILE" ]; then echo "未找到配置！"; sleep 1; return; fi
    source "$CONF_FILE"
    get_public_ip

    INSECURE_FLAG="0"
    if [ "$CERT_CHOICE" == "1" ]; then INSECURE_FLAG="1"; fi

    VLESS_LINK="vless://${UUID_REALITY}@${PUBLIC_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#SingBox-REALITY"
    HY2_PORT_DISPLAY=${PORT_HY2}
    if [ -n "$PORT_HY2_RANGE" ]; then HY2_PORT_DISPLAY=${PORT_HY2_RANGE/-/:}; fi
    HY2_LINK="hy2://${PASS_HY2}@${PUBLIC_IP}:${HY2_PORT_DISPLAY}?insecure=${INSECURE_FLAG}&sni=${DOMAIN}#SingBox-Hy2"
    TUIC_LINK="tuic://${UUID_TUIC}:${PASS_TUIC}@${PUBLIC_IP}:${PORT_TUIC}?sni=${DOMAIN}&alpn=h3&allow_insecure=${INSECURE_FLAG}#SingBox-TUIC"
    ANYTLS_LINK="anytls://${PASS_ANYTLS}@${PUBLIC_IP}:${PORT_ANYTLS}?security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&insecure=${INSECURE_FLAG}&allowInsecure=${INSECURE_FLAG}&type=tcp&headerType=none#SingBox-AnyTLS"

    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}↓↓↓ 您的最新节点连接代码 ↓↓↓${PLAIN}\n"
    echo -e "${GREEN}[1] REALITY (VLESS + Vision):${PLAIN}\n${VLESS_LINK}\n"
    echo -e "${GREEN}[2] AnyTLS:${PLAIN}\n${ANYTLS_LINK}\n"
    echo -e "${GREEN}[3] Hysteria2:${PLAIN}\n${HY2_LINK}\n"
    echo -e "${GREEN}[4] TUIC v5:${PLAIN}\n${TUIC_LINK}\n"
    echo -e "${CYAN}===========================================${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    start_menu
}

# 彻底卸载
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
        rm -f "$SING_BOX_BIN"
        rm -f /usr/bin/sba
        echo -e "${GREEN}卸载完成！系统已恢复纯净状态。${PLAIN}"
        exit 0
    else
        echo -e "${GREEN}已取消。${PLAIN}"; sleep 1; start_menu
    fi
}

# ================= 主菜单控制流 =================
start_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}      Sing-box 终极部署及管理脚本         ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    BBR_TXT=$(check_bbr_status)
    if [ -f "$CONF_FILE" ]; then
        echo -e "系统状态: ${GREEN}已安装${PLAIN}   |   BBR加速状态: ${BBR_TXT}"
        echo -e "${GREEN}1.${PLAIN} ${CYAN}一键无损更新 Sing-box 核心 (直接静默升级，绝不动配置)${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} 动态修改端口或配置参数"
        echo -e "${GREEN}3.${PLAIN} 查看当前节点分享链接"
        echo -e "${GREEN}4.${PLAIN} 强制彻底覆盖并全新安装"
    else
        echo -e "系统状态: ${YELLOW}未安装${PLAIN}   |   BBR加速状态: ${BBR_TXT}"
        echo -e "${GREEN}1.${PLAIN} 全新安装 Sing-box (多协议防封锁版)"
    fi
    echo -e "${GREEN}5.${PLAIN} ${YELLOW}一键开启 BBR 网络加速机制${PLAIN}"
    echo -e "${GREEN}6.${PLAIN} 彻底卸载 Sing-box"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请输入选项 [0-6]: " MENU_CHOICE
    
    if [ -f "$CONF_FILE" ]; then
        case "$MENU_CHOICE" in
            1) silent_update_core ;;
            2) modify_parameters ;;
            3) show_links ;;
            4) fresh_install ;;
            5) enable_bbr ;;
            6) uninstall_singbox ;;
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    else
        case "$MENU_CHOICE" in
            1) fresh_install ;;
            5) enable_bbr ;;
            6) uninstall_singbox ;;
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    fi
}

# 脚本入口
start_menu
