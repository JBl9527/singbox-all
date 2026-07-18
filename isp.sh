#!/bin/bash

# ==========================================
# Sing-box 独立家宽流量接管模块 (多协议增强版)
# 适用场景：台湾/美国家宽节点分流接管
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 【已修复】匹配主程序的实际配置路径
CONFIG_FILE="/usr/local/etc/sing-box/config.json"
RESIDENTIAL_TAG="Residential-ISP-Node"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}"
    sleep 3
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}正在安装 jq 依赖...${PLAIN}"
    apt-get update && apt-get install -y jq || { echo -e "${RED}jq 安装失败，请手动安装！${PLAIN}"; sleep 3; exit 1; }
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}未找到 Sing-box 配置文件：$CONFIG_FILE${PLAIN}"
    echo -e "${YELLOW}请确认您是否已经安装了 Sing-box，或者路径是否正确。${PLAIN}"
    sleep 3
    exit 1
fi

# ================= 核心功能函数 =================

enable_takeover() {
    echo -e "\n${CYAN}>>> 第一步：请选择家宽节点的协议类型 <<<${PLAIN}"
    echo "1. SOCKS5 (最常见于代理池和指纹浏览器节点)"
    echo "2. HTTP / HTTPS"
    echo "3. Shadowsocks (SS)"
    echo "4. Trojan"
    echo "5. VMess (基础 TCP)"
    read -p "请输入选项 [1-5]: " proto_choice

    echo -e "\n${CYAN}>>> 第二步：请输入家宽节点连接信息 <<<${PLAIN}"
    read -p "服务器地址 (IP/域名): " isp_address
    read -p "服务器端口 (Port): " isp_port

    local outbound_json=""

    # 根据不同协议构建不同的 JSON 结构
    case "$proto_choice" in
        1)
            # SOCKS5
            read -p "用户名 (留空则无认证): " isp_user
            read -p "密码 (留空则无认证): " isp_pass
            if [ -z "$isp_user" ]; then
                outbound_json="{\"type\": \"socks\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"version\": \"5\"}"
            else
                outbound_json="{\"type\": \"socks\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"version\": \"5\", \"username\": \"$isp_user\", \"password\": \"$isp_pass\"}"
            fi
            ;;
        2)
            # HTTP
            read -p "用户名 (留空则无认证): " isp_user
            read -p "密码 (留空则无认证): " isp_pass
            if [ -z "$isp_user" ]; then
                outbound_json="{\"type\": \"http\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port}"
            else
                outbound_json="{\"type\": \"http\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"username\": \"$isp_user\", \"password\": \"$isp_pass\"}"
            fi
            ;;
        3)
            # Shadowsocks
            read -p "加密方式 (如 aes-256-gcm, chacha20-ietf-poly1305): " isp_method
            read -p "连接密码: " isp_pass
            outbound_json="{\"type\": \"shadowsocks\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"method\": \"$isp_method\", \"password\": \"$isp_pass\"}"
            ;;
        4)
            # Trojan
            read -p "连接密码: " isp_pass
            read -p "SNI 域名 (留空则使用服务器地址): " isp_sni
            [ -z "$isp_sni" ] && isp_sni="$isp_address"
            outbound_json="{\"type\": \"trojan\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"password\": \"$isp_pass\", \"tls\": {\"enabled\": true, \"server_name\": \"$isp_sni\"}}"
            ;;
        5)
            # VMess
            read -p "UUID: " isp_uuid
            outbound_json="{\"type\": \"vmess\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"uuid\": \"$isp_uuid\", \"security\": \"auto\", \"alter_id\": 0}"
            ;;
        *)
            echo -e "${RED}输入错误，操作取消。${PLAIN}"
            sleep 2
            return
            ;;
    esac

    echo -e "\n${CYAN}>>> 第三步：请选择流量接管模式 <<<${PLAIN}"
    echo "1. 按【入站端口】接管 (例如让 10000 端口的流量全部走家宽)"
    echo "2. 按【入站 Tag】接管 (例如让 tag 为 'anytls-in' 的流量走家宽)"
    read -p "请选择 [1-2]: " mode_choice

    local rule_json=""
    if [ "$mode_choice" == "1" ]; then
        read -p "请输入需要接管的入站端口号 (如 10000): " target_port
        rule_json="{\"inbound_port\": [$target_port], \"outbound\": \"$RESIDENTIAL_TAG\"}"
    elif [ "$mode_choice" == "2" ]; then
        read -p "请输入需要接管的入站 Tag 名称: " target_tag
        rule_json="{\"inbound\": [\"$target_tag\"], \"outbound\": \"$RESIDENTIAL_TAG\"}"
    else
        echo -e "${RED}输入错误，操作取消。${PLAIN}"
        sleep 2
        return
    fi

    # 备份原配置
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_$(date +%s)"

    echo -e "${YELLOW}正在修改 Sing-box 配置...${PLAIN}"

    # 使用 jq 动态修改配置
    jq --arg tag "$RESIDENTIAL_TAG" \
       --argjson new_out "$outbound_json" \
       --argjson new_rule "$rule_json" \
    '
    .outbounds = (.outbounds | map(select(.tag != $tag))) + [$new_out] |
    .route.rules = [$new_rule] + (.route.rules | map(select(.outbound != $tag)))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo -e "${GREEN}配置已更新！正在测试配置并重启 Sing-box...${PLAIN}"
    
    # 测试配置是否正确
    if sing-box check -c "$CONFIG_FILE"; then
        systemctl restart sing-box
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}✅ 家宽流量接管已成功开启！${PLAIN}"
        else
            echo -e "${RED}❌ Sing-box 启动失败，请使用 systemctl status sing-box 查看错误。${PLAIN}"
        fi
    else
         echo -e "${RED}❌ 新生成的配置存在语法错误，Sing-box 拒绝加载。已自动回滚配置！${PLAIN}"
         LATEST_BAK=$(ls -t "${CONFIG_FILE}.bak_"* | head -1 2>/dev/null)
         if [ -n "$LATEST_BAK" ]; then
             mv "$LATEST_BAK" "$CONFIG_FILE"
             echo -e "${YELLOW}已恢复至修改前的配置。${PLAIN}"
         fi
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回子菜单..."
}

disable_takeover() {
    echo -e "${YELLOW}正在移除家宽接管规则...${PLAIN}"
    
    if ! grep -q "$RESIDENTIAL_TAG" "$CONFIG_FILE"; then
         echo -e "${GREEN}未发现家宽接管规则，无需清理。${PLAIN}"
         sleep 2
         return
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_$(date +%s)"

    jq --arg tag "$RESIDENTIAL_TAG" \
    '
    .outbounds = (.outbounds | map(select(.tag != $tag))) |
    .route.rules = (.route.rules | map(select(.outbound != $tag)))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    systemctl restart sing-box
    echo -e "${GREEN}✅ 家宽接管规则已移除，Sing-box 已重启。${PLAIN}"
    echo ""
    read -n 1 -s -r -p "按任意键返回子菜单..."
}

# ================= 交互菜单 =================
show_menu() {
    clear
    echo -e "${GREEN}===========================================${PLAIN}"
    echo -e "${GREEN}    Sing-box 家宽流量接管管理模块 (SBA ISP)  ${PLAIN}"
    echo -e "${GREEN}===========================================${PLAIN}"
    echo -e " 1. ${GREEN}开启/修改${PLAIN} 家宽流量接管 (支持 SS/Trojan/Socks/HTTP/VMess)"
    echo -e " 2. ${RED}关闭/移除${PLAIN} 家宽流量接管"
    echo -e " 0. 返回主菜单"
    echo -e "${GREEN}===========================================${PLAIN}"
    read -p "请输入选项 [0-2]: " choice

    case "$choice" in
        1) enable_takeover; show_menu ;;
        2) disable_takeover; show_menu ;;
        0) echo -e "${GREEN}退出家宽模块...${PLAIN}"; sleep 1; exit 0 ;;
        *) echo -e "${RED}请输入正确的数字 [0-2]${PLAIN}"; sleep 2; show_menu ;;
    esac
}

show_menu
