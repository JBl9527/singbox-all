#!/bin/bash

# ==========================================
# Sing-box 纯净防封锁管理脚本 (Any-Reality专供版)
# 包含: VLESS-REALITY, 标准AnyTLS, Any-Reality
# 特性: 证书双模申请 / 动态修参 / 纯粹轻量无冗余
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

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

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
            echo -e "${RED}❌ BBR 开启失败！部分虚拟化架构不支持修改内核参数。${PLAIN}"
        fi
    fi
    sleep 2
    start_menu
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
PADDING_SCHEME_JSON='${PADDING_SCHEME_JSON}'
UUID_REALITY="${UUID_REALITY}"
PASS_ANYTLS="${PASS_ANYTLS}"
PASS_ANYREALITY="${PASS_ANYREALITY}"
REALITY_PRIVATE="${REALITY_PRIVATE}"
REALITY_PUBLIC="${REALITY_PUBLIC}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
EOF
}

silent_update_core() {
    clear
    echo -e "${YELLOW}正在检测并下载最新版 Sing-box 核心...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) DL_ARCH="amd64" ;; aarch64) DL_ARCH="arm64" ;; *) echo -e "${RED}不支持的架构${PLAIN}"; exit 1 ;; esac
    
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    if [ $? -ne 0 ]; then echo -e "${RED}下载失败，请检查网络！${PLAIN}"; sleep 2; start_menu; return; fi
    
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

fresh_install() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        开始全新安装 Sing-box 服务        ${PLAIN}"
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

    echo -e "\n${YELLOW}=== 2. 协议端口设置 ===${PLAIN}"
    read -p "请输入 VLESS-REALITY 端口 [默认 34433]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-34433}
    read -p "请输入 标准 AnyTLS 端口 [默认 44433]: " PORT_ANYTLS
    PORT_ANYTLS=${PORT_ANYTLS:-44433}
    read -p "请输入 究极 Any-Reality 端口 [默认 54433]: " PORT_ANYREALITY
    PORT_ANYREALITY=${PORT_ANYREALITY:-54433}

    echo -e "\n${YELLOW}=== 3. AnyTLS Padding 设置 ===${PLAIN}"
    read -p "请输入自定义 padding-scheme (直接回车使用内置最强配置): " CUSTOM_PADDING
    if [ -z "$CUSTOM_PADDING" ]; then
        PADDING_SCHEME_JSON='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'
    else PADDING_SCHEME_JSON="$CUSTOM_PADDING"; fi
    
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget jq openssl socat uuid-runtime cron iptables > /dev/null 2>&1
    mkdir -p "$CERT_DIR"

    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) DL_ARCH="amd64" ;; aarch64) DL_ARCH="arm64" ;; *) exit 1 ;; esac
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${DL_ARCH}

    # ================= 证书生成逻辑 =================
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

    # 凭证独立生成
    UUID_REALITY=$(uuidgen)
    PASS_ANYTLS=$(openssl rand -base64 12)
    PASS_ANYREALITY=$(openssl rand -base64 12)
    
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
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}未检测到配置文件，请先选择安装！${PLAIN}"
        sleep 2; start_menu; return
    fi
    source "$CONF_FILE"

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          独立证书申请与修复模块          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${YELLOW}当前绑定的域名: ${GREEN}${DOMAIN:-无}${PLAIN}"
    echo -e "------------------------------------------"
    echo "1. 重新生成 临时自签证书"
    echo "2. 使用 Standalone 模式申请 永久域名证书 (需放行 80 端口)"
    echo "3. 使用 Cloudflare API 申请 永久域名证书 (DNS 验证，无需 80 端口)"
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
        echo -e "${RED}输入无效！${PLAIN}"; sleep 1; standalone_cert_manager; return
    fi

    save_config
    mkdir -p "$CERT_DIR"
    systemctl stop sing-box > /dev/null 2>&1

    if [ "$CERT_CHOICE" == "1" ]; then
        echo -e "\n${GREEN}正在生成自签证书...${PLAIN}"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN"
        echo -e "${GREEN}✔ 自签证书生成成功！${PLAIN}"
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

    echo -e "\n${YELLOW}正在重启并校验 Sing-box 核心...${PLAIN}"
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✔ 证书部署成功，Sing-box 运行正常！${PLAIN}"
    else
        echo -e "${RED}❌ 启动失败！可能是刚才的申请由于网络或配置原因失败，缺少证书文件。${PLAIN}"
    fi
    sleep 3
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
      "type": "anytls", "tag": "any-reality-in", "listen": "::", "listen_port": $PORT_ANYREALITY,
      "users": [ { "password": "$PASS_ANYREALITY" } ],
      "padding_scheme": [ $PADDING_SCHEME_JSON ],
      "tls": { 
          "enabled": true, 
          "server_name": "www.microsoft.com", 
          "reality": { 
              "enabled": true, 
              "handshake": { "server": "www.microsoft.com", "server_port": 443 }, 
              "private_key": "$REALITY_PRIVATE", 
              "short_id": ["$REALITY_SHORT_ID"] 
          } 
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" } ]
}
EOF
}

configure_systemd() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$SING_BOX_BIN run -c $CONFIG_DIR/config.json
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

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}        动态修改节点参数 (无损重载)         ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "1. 修改 VLESS-REALITY 端口 (当前: $PORT_REALITY)"
    echo -e "2. 修改 标准 AnyTLS 端口 (当前: $PORT_ANYTLS)"
    echo -e "3. 修改 究极 Any-Reality 端口 (当前: $PORT_ANYREALITY)"
    echo -e "4. 修改 AnyTLS/Any-Reality Padding Scheme"
    echo -e "0. 返回主菜单"
    read -p "请选择 [0-4]: " MOD_CHOICE

    case "$MOD_CHOICE" in
        1) read -p "新 VLESS-REALITY 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_REALITY=$NEW_PORT ;;
        2) read -p "新 AnyTLS 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_ANYTLS=$NEW_PORT ;;
        3) read -p "新 Any-Reality 端口: " NEW_PORT; [ -n "$NEW_PORT" ] && PORT_ANYREALITY=$NEW_PORT ;;
        4) read -p "新 Padding: " NEW_PAD; [ -n "$NEW_PAD" ] && PADDING_SCHEME_JSON=$NEW_PAD ;;
        0) start_menu; return ;;
        *) echo -e "${RED}无效！${PLAIN}"; sleep 1; modify_parameters; return ;;
    esac

    systemctl stop sing-box
    save_config
    generate_config_json
    configure_systemd
    echo -e "${GREEN}修改成功！参数已生效。${PLAIN}"; sleep 1; show_links
}

show_links() {
    if [ ! -f "$CONF_FILE" ]; then echo "未找到配置！"; sleep 1; return; fi
    source "$CONF_FILE"
    get_public_ip

    INSECURE_FLAG="0"
    if [ "$CERT_CHOICE" == "1" ]; then INSECURE_FLAG="1"; fi

    VLESS_LINK="vless://${UUID_REALITY}@${PUBLIC_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#SingBox-REALITY"
    ANYTLS_LINK="anytls://${PASS_ANYTLS}@${PUBLIC_IP}:${PORT_ANYTLS}?security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&insecure=${INSECURE_FLAG}&allowInsecure=${INSECURE_FLAG}&type=tcp&headerType=none#SingBox-AnyTLS"
    ANYREALITY_LINK="anytls://${PASS_ANYREALITY}@${PUBLIC_IP}:${PORT_ANYREALITY}?security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#SingBox-AnyReality"

    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}↓↓↓ 您的最新节点连接代码 ↓↓↓${PLAIN}\n"
    echo -e "${GREEN}[1] VLESS + REALITY (常规抗封锁):${PLAIN}\n${VLESS_LINK}\n"
    echo -e "${GREEN}[2] 标准 AnyTLS (需真实域名/允许不安全):${PLAIN}\n${ANYTLS_LINK}\n"
    echo -e "${GREEN}[3] 究极 Any-Reality (免证书强混淆):${PLAIN}\n${ANYREALITY_LINK}\n"
    echo -e "${YELLOW}⚠️ 注意: Any-Reality 协议较为前沿，请确保您的本地客户端支持解析 anytls+reality 的配置组合 (如最新版 Sing-box 客户端、部分最新版 NekoBox/Mihomo)。${PLAIN}"
    echo -e "${CYAN}===========================================${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
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
    echo -e "${CYAN}     Sing-box 极简纯净版管理脚本 (SBA)    ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    if [ -f "$CONF_FILE" ]; then
        echo -e "系统状态: ${GREEN}已安装${PLAIN}"
        echo -e "------------------------------------------"
        echo -e "${GREEN}1.${PLAIN} ${CYAN}一键无损更新 Sing-box 核心${PLAIN}"
        echo -e "${GREEN}2.${PLAIN} 动态修改端口或高级参数"
        echo -e "${GREEN}3.${PLAIN} ${YELLOW}独立申请或修复安全证书${PLAIN}"
        echo -e "${GREEN}4.${PLAIN} 查看节点分享链接"
        echo -e "${GREEN}5.${PLAIN} 强制彻底覆盖并全新安装"
        echo -e "${GREEN}6.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}7.${PLAIN} 彻底卸载 Sing-box"
    else
        echo -e "系统状态: ${YELLOW}未安装${PLAIN}"
        echo -e "------------------------------------------"
        echo -e "${GREEN}1.${PLAIN} 全新安装 Sing-box"
        echo -e "${GREEN}6.${PLAIN} 一键开启 BBR 网络加速机制"
        echo -e "${GREEN}7.${PLAIN} 彻底卸载 Sing-box"
    fi
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请输入选项: " MENU_CHOICE
    
    if [ -f "$CONF_FILE" ]; then
        case "$MENU_CHOICE" in
            1) silent_update_core ;;
            2) modify_parameters ;;
            3) standalone_cert_manager ;;
            4) show_links ;;
            5) fresh_install ;;
            6) enable_bbr ;;
            7) uninstall_singbox ;;
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    else
        case "$MENU_CHOICE" in
            1) fresh_install ;;
            6) enable_bbr ;;
            7) uninstall_singbox ;;
            0) exit 0 ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1; start_menu ;;
        esac
    fi
}

start_menu
