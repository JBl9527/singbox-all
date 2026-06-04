#!/bin/bash

# ==========================================
# Sing-box 多协议一键部署脚本
# 包含协议: REALITY, AnyTLS, Hysteria2, TUIC
# 默认使用高位端口以增强隐蔽性
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# ================= 端口配置 =================
PORT_REALITY=34433
PORT_ANYTLS=44433
PORT_HY2=54433
PORT_TUIC=54434
# ==========================================

CONFIG_DIR="/usr/local/etc/sing-box"
CERT_DIR="/usr/local/etc/sing-box/cert"
SING_BOX_BIN="/usr/local/bin/sing-box"

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 安装基础依赖
install_dependencies() {
    echo -e "${GREEN}正在安装基础依赖...${PLAIN}"
    apt-get update -y
    apt-get install -y curl wget jq openssl socat uuid-runtime cron
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CERT_DIR"
}

# 安装 Sing-box 核心
install_sing_box() {
    echo -e "${GREEN}正在下载并安装 Sing-box 最新版...${PLAIN}"
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
    echo -e "${GREEN}Sing-box 安装成功！版本: ${LATEST_VERSION}${PLAIN}"
}

# 申请证书
manage_cert() {
    echo -e "${YELLOW}请选择证书模式:${PLAIN}"
    echo "1. 生成临时自签证书 (有效期10年，适合仅使用 REALITY 或无需真实域名的场景)"
    echo "2. 申请永久域名证书 (使用 acme.sh，需提前解析域名并确保 80 端口空闲)"
    read -p "请输入选项 [1-2]: " CERT_CHOICE

    if [ "$CERT_CHOICE" == "1" ]; then
        echo -e "${GREEN}正在生成自签证书...${PLAIN}"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=bing.com"
        echo -e "${GREEN}自签证书生成完毕！${PLAIN}"
    elif [ "$CERT_CHOICE" == "2" ]; then
        read -p "请输入已解析到本机的域名: " DOMAIN
        echo -e "${GREEN}正在安装 acme.sh 并申请证书...${PLAIN}"
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
        ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
            --fullchain-file "$CERT_DIR/server.crt" \
            --key-file "$CERT_DIR/server.key" \
            --reloadcmd "systemctl restart sing-box"
        echo -e "${GREEN}证书申请完毕！${PLAIN}"
    else
        echo -e "${RED}输入无效！${PLAIN}"
        exit 1
    fi
}

# 生成配置文件
generate_config() {
    echo -e "${GREEN}正在生成节点凭证...${PLAIN}"
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
      "type": "vless",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $PORT_ANYTLS,
      "users": [
        {
          "uuid": "$UUID",
          "flow": ""
        }
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

    echo -e "${GREEN}配置文件生成成功！${PLAIN}"
    
    # 打印连接信息
    echo -e "==========================================="
    echo -e "${YELLOW}您的 Sing-box 节点信息如下:${PLAIN}"
    echo -e "UUID: ${GREEN}$UUID${PLAIN}"
    echo -e "密码 (Hy2/TUIC): ${GREEN}$PASSWORD${PLAIN}"
    echo -e "-------------------------------------------"
    echo -e "${YELLOW}各协议端口信息:${PLAIN}"
    echo -e "REALITY 端口 (TCP): ${GREEN}$PORT_REALITY${PLAIN}"
    echo -e "AnyTLS 端口 (TCP): ${GREEN}$PORT_ANYTLS${PLAIN}"
    echo -e "Hysteria2 端口 (UDP): ${GREEN}$PORT_HY2${PLAIN}"
    echo -e "TUIC 端口 (UDP): ${GREEN}$PORT_TUIC${PLAIN}"
    echo -e "-------------------------------------------"
    echo -e "REALITY 公钥 (Public Key): ${GREEN}$REALITY_PUBLIC${PLAIN}"
    echo -e "REALITY Short ID: ${GREEN}$REALITY_SHORT_ID${PLAIN}"
    echo -e "==========================================="
}

# 配置 Systemd 服务
configure_systemd() {
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
    systemctl enable sing-box
    systemctl restart sing-box
    echo -e "${GREEN}Sing-box 已经启动并设置为开机自启！${PLAIN}"
}

# 运行主流程
install_dependencies
install_sing_box
manage_cert
generate_config
configure_systemd
