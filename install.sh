#!/bin/bash

# ==========================================
# Sing-box 高级多协议一键部署脚本 (终极版)
# 协议: REALITY, AnyTLS, Hysteria2 (含端口跳跃), TUIC
# 特性: 凭证全独立随机 / 交互式端口映射 / 最强 Padding Scheme
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

    # 2. 端口与端口跳跃配置
    echo -e "\n${YELLOW}=== 2. 协议端口设置 ===${PLAIN}"
    read -p "请输入 REALITY 端口 [默认 34433]: " PORT_REALITY
    PORT_REALITY=${PORT_REALITY:-34433}

    read -p "请输入 AnyTLS 端口 [默认 44433]: " PORT_ANYTLS
    PORT_ANYTLS=${PORT_ANYTLS:-44433}

    read -p "请输入 Hysteria2 主监听端口 [默认 54433]: " PORT_HY2
    PORT_HY2=${PORT_HY2:-54433}

    echo -e "\n${CYAN}Hysteria2 端口跳跃 (Port Hopping) 设置:${PLAIN}"
    echo "输入一个端口段，例如 20000:30000，客户端可在此范围内动态跳跃防封锁。"
    read -p "请输入 Hy2 跳跃端口段 (直接回车表示不开启端口跳跃): " PORT_HY2_RANGE
    # 将用户可能输入的减号替换为冒号，适配 iptables 格式
    PORT_HY2_RANGE=$(echo "$PORT_HY2_RANGE" | tr '-' ':')

    read -p "请输入 TUIC 端口 [默认 54434]: " PORT_TUIC
    PORT_TUIC=${PORT_TUIC:-54434}

    # 3. AnyTLS Padding Scheme
    echo -e "\n${YELLOW}=== 3. AnyTLS 阻断防护 (Padding Scheme) 设置 ===${PLAIN}"
    echo -e "脚本默认内置了最强抗检测方案，通过高度模拟真实复杂的 HTTPS Fragment 与延迟特征防止阻断。"
    read -p "请输入自定义 padding-scheme (如需使用内置最强默认配置，请直接回车): " CUSTOM_PADDING

    if [ -z "$CUSTOM_PADDING" ]; then
        PADDING_SCHEME_JSON='"stop=8", "0=30-30", "1=100-400", "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000", "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"'
    else
        PADDING_SCHEME_JSON="$CUSTOM_PADDING"
    fi
    echo -e "\n${GREEN}交互配置完成，开始全自动安装部署...${PLAIN}\n"
    sleep 2
}

# 安装基础依赖
install_dependencies() {
    echo -e "${GREEN}[1/5] 正在安装基础依赖...${PLAIN}"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget jq openssl socat uuid-runtime cron iptables > /dev/null 2>&1
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
    fi
}

# 生成配置文件 (独立生成各项凭据)
generate_config() {
    echo -e "${GREEN}[4/5] 正在独立生成各协议的随机凭证...${PLAIN}"
    
    # 完全独立的凭证生成
    UUID_REALITY=$(uuidgen)
    PASS_ANYTLS=$(openssl rand -base64 12)
    PASS_HY2=$(openssl rand -base64 12)
    UUID_TUIC=$(uuidgen)
    PASS_TUIC=$(openssl rand -base64 12)

    # REALITY 专属公私钥
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
          "uuid": "$UUID_REALITY",
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
          "password": "$PASS_ANYTLS"
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
          "password": "$PASS_HY2"
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
          "uuid": "$UUID_TUIC",
          "password": "$PASS_TUIC"
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

# 配置 Systemd 服务并绑定 iptables 端口跳跃规则
configure_systemd() {
    echo -e "${GREEN}[5/5] 正在配置系统服务及防火墙映射...${PLAIN}"
    
    # 初始化 systemd 的 Exec 规则变量
    IPTABLES_START=""
    IPTABLES_STOP=""

    # 如果配置了端口跳跃，自动向 systemd 注入 iptables NAT 规则
    if [ -n "$PORT_HY2_RANGE" ]; then
        IPTABLES_START="ExecStartPost=-/sbin/iptables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2
ExecStartPost=-/sbin/ip6tables -t nat -A PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
        
        IPTABLES_STOP="ExecStopPost=-/sbin/iptables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2
ExecStopPost=-/sbin/ip6tables -t nat -D PREROUTING -p udp --dport $PORT_HY2_RANGE -j REDIRECT --to-ports $PORT_HY2"
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
$IPTABLES_START
$IPTABLES_STOP
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box > /dev/null 2>&1
    systemctl restart sing-box

    # 打印最终连接信息
    clear
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${CYAN}        Sing-box 服务端部署成功！           ${PLAIN}"
    echo -e "${CYAN}===========================================${PLAIN}"
    
    echo -e "${YELLOW}[1] REALITY 配置信息 (VLESS + TCP):${PLAIN}"
    echo -e "  端口: ${GREEN}$PORT_REALITY${PLAIN} ${CYAN}[xtls-rprx-vision 流控]${PLAIN}"
    echo -e "  UUID: ${GREEN}$UUID_REALITY${PLAIN}"
    echo -e "  公钥: ${GREEN}$REALITY_PUBLIC${PLAIN}"
    echo -e "  Short ID: ${GREEN}$REALITY_SHORT_ID${PLAIN}"
    
    echo -e "\n${YELLOW}[2] AnyTLS 配置信息 (AnyTLS + TCP):${PLAIN}"
    echo -e "  端口: ${GREEN}$PORT_ANYTLS${PLAIN} ${CYAN}[已应用最强 Padding]${PLAIN}"
    echo -e "  密码: ${GREEN}$PASS_ANYTLS${PLAIN}"

    echo -e "\n${YELLOW}[3] Hysteria2 配置信息 (UDP):${PLAIN}"
    if [ -n "$PORT_HY2_RANGE" ]; then
        echo -e "  端口: ${GREEN}$PORT_HY2${PLAIN} 或跳跃端口段: ${GREEN}$PORT_HY2_RANGE${PLAIN}"
        echo -e "  (客户端地址填写示例: ${GREEN}你的IP:${PORT_HY2_RANGE/-/:}${PLAIN})"
    else
        echo -e "  端口: ${GREEN}$PORT_HY2${PLAIN} (未开启跳跃)"
    fi
    echo -e "  密码: ${GREEN}$PASS_HY2${PLAIN}"

    echo -e "\n${YELLOW}[4] TUIC v5 配置信息 (UDP):${PLAIN}"
    echo -e "  端口: ${GREEN}$PORT_TUIC${PLAIN}"
    echo -e "  UUID: ${GREEN}$UUID_TUIC${PLAIN}"
    echo -e "  密码: ${GREEN}$PASS_TUIC${PLAIN}"
    
    echo -e "${CYAN}===========================================${PLAIN}"
    echo -e "${RED}重要提示: 请务必在云提供商防火墙及系统防火墙中放行上述所有 TCP/UDP 端口！${PLAIN}"
    if [ -n "$PORT_HY2_RANGE" ]; then
        echo -e "${RED}由于开启了 Hy2 端口跳跃，请务必放行 UDP 端口段: ${PORT_HY2_RANGE}${PLAIN}"
    fi
}

# 运行主流程
interactive_setup
install_dependencies
install_sing_box
manage_cert
generate_config
configure_systemd
