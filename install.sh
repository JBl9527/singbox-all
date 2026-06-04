#!/bin/bash

# ==========================================
# Sing-box 高级多协议一键部署脚本
# 包含协议: REALITY (开启 vision 流控), AnyTLS, Hysteria2, TUIC
# 特性: 端口自定义 / 自签或独立证书 / 极强 Padding Scheme
# ==========================================

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

# ================= 交互式配置信息 =================
interactive_setup() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}      Sing-box 多协议高级部署脚本         ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    # 1. 证书配置
    echo -e "\n${YELLOW}=== 1. 证书模式选择 ===${PLAIN}"
    echo "1. 生成临时自签证书 (有效期10年，适合单纯使用 REALITY / AnyTLS 无需真实域名)"
    echo "2. 申请永久域名证书 (使用 acme.sh，需提前解析真实域名到本机并确保 80 端口空闲)"
    read -p "请输入选项 [1-2]: " CERT_CHOICE
    if [ "$CERT_CHOICE" == "2" ]; then
        read -p "请输入已解析到本机的域名: " DOMAIN
    fi

    # 2. 端口配置
    echo -e "\n${YELLOW}=== 2. 协议端口设置 ===${PLAIN}"
    read -p "请输入 REALITY 端口 [默认 34433]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-34433}

    read -p "请输入 AnyTLS 端口 [默认 44433]: " PORT_ANYTLS
    PORT_ANYTLS=${PORT_ANYTLS:-44433}

    read -p "请输入 Hysteria2 端口 [默认 54433]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-54433}

    read -p "请输入 TUIC 端口 [默认 54434]: " PORT_TUIC
    PORT_TUIC=${PORT_TUIC:-54434}

    # 3. AnyTLS Padding Scheme
    echo -e "\n${YELLOW}=== 3. AnyTLS 阻断防护 (Padding Scheme) 设置 ===${PLAIN}"
    echo -e "脚本默认内置了最强抗检测方案，通过高度模拟真实复杂的 HTTPS Fragment 与延迟特征防止阻断。"
    read -p "请输入自定义 padding-scheme (如需使用内置最强默认配置，请直接回车): " CUSTOM_PADDING

    if [ -z "$CUSTOM_PADDING" ]; then
        # 默认最强抗检测方案 (AnyTLS Default Recommended)
        PADDING_SCHEME_JSON='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'
    else
        # 用户自定义的数组内容
        PADDING_SCHEME_JSON="$CUSTOM_PADDING"
    fi
    echo -e "\n${GREEN}交互配置完成，开始全自动安装部署...${PLAIN}\n"
    sleep 2
}

# 安装基础依赖
install_dependencies() {
    echo -e "${GREEN}[1/5] 正在安装基础依赖...${PLAIN}"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget jq openssl socat uuid-runtime cron > /dev/null 2>&1
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CERT_DIR"
}

# 安装 Sing-box 核心
install_sing_box() {
    echo -e "${GREEN}[2/5] 正在下载并安装 Sing-box 最新版...${PLAIN}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) DL_ARCH="amd64" ;;
        aarch64) DL_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
    
    DL_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"
    wget -qO sing-box.tar.gz "$DL_URL"
    tar -xzf sing-box.tar.gz
    mv sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box $SING_BOX_BIN
    chmod +x $SING_BOX_BIN
    rm -rf sing-box.tar.gz sing-box-${LATEST_VERSION}-linux-${DL_ARCH}
}

# 处理证书逻辑
manage_cert() {
    echo -e "${GREEN}[3/5] 正在处理证书配置...${PLAIN}"
    if [ "$CERT_CHOICE" == "1" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=bing.com" > /dev/null 2>&1
    elif [ "$CERT_CHOICE" == "2" ]; then
        curl -s https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
            --fullchain-file "$CERT_DIR/server.crt" \
            --key-file "$CERT_DIR/server.key" \
            --reloadcmd "systemctl restart sing-box"
    else
        echo -e "${RED}证书模式选择错误！${PLAIN}"
        exit 1
    fi
}

# 生成配置文件
generate_config() {
    echo -e "${GREEN}[4/5] 正在生成核心配置文件...${PLAIN}"
    UUID=$(uuidgen)
    PASSWORD=$(openssl rand -base64 12)
    REALITY_KEYPAIR=$($SING_BOX_BIN generate reality-keypair)
    REALITY_PRIVATE=$(echo "$REALITY_KEYPAIR" | grep PrivateKey | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$REALITY_KEYPAIR" | grep PublicKey | awk '{print $2}')
    REALITY_SHORT_ID=$($SING_BOX_BIN generate rand --hex 8)

    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": $PORT_REALITY,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE",
          "short_id": ["$REALITY_SHORT_ID"]
        }
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $PORT_ANYTLS,
      "users": [
        {
          "password": "$PASSWORD"
        }
      ],
      "padding_scheme": [
        $PADDING_SCHEME_JSON
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $PORT_HY2,
      "users": [
        {
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $PORT_TUIC,
      "users": [
        {
          "uuid": "$UUID",
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3", "spdy/3.1"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
}

# 配置 Systemd 服务并收尾
configure_systemd() {
    echo -e "${GREEN}[5/5] 正在配置系统服务...${PLAIN}"
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org/
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

    # 打印连接信息
    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${CYAN}        Sing-box 服务端部署成功！           ${PLAIN}"
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${YELLOW}核心节点凭证:${PLAIN}"
    echo -e "UUID: ${GREEN}$UUID${PLAIN}"
    echo -e "密码 (AnyTLS/Hy2/TUIC 共用): ${GREEN}$PASSWORD${PLAIN}"
    echo -e "-------------------------------------------"
    echo -e "${YELLOW}各协议端口信息:${PLAIN}"
    echo -e "REALITY (TCP): ${GREEN}$PORT_REALITY${PLAIN} ${CYAN}[已开启 xtls-rprx-vision 流控]${PLAIN}"
    echo -e "AnyTLS  (TCP): ${GREEN}$PORT_ANYTLS${PLAIN} ${CYAN}[已应用最强 Padding 抗检测机制]${PLAIN}"
    echo -e "Hysteria2(UDP): ${GREEN}$PORT_HY2${PLAIN}"
    echo -e "TUIC    (UDP): ${GREEN}$PORT_TUIC${PLAIN}"
    echo -e "-------------------------------------------"
    echo -e "${YELLOW}REALITY 专属验证信息:${PLAIN}"
    echo -e "Public Key (公钥): ${GREEN}$REALITY_PUBLIC${PLAIN}"
    echo -e "Short ID: ${GREEN}$REALITY_SHORT_ID${PLAIN}"
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "提示: 请务必在云提供商后台防火墙放行上述对应的 TCP/UDP 端口！"
}

# 运行主流程
interactive_setup
install_dependencies
install_sing_box
manage_cert
generate_config
configure_systemd
