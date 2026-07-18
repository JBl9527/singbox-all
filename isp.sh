#!/bin/bash

# ==========================================
# Sing-box 独立家宽流量接管模块 (SBA ISP)
# 适用场景：台湾/美国家宽节点分流接管
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

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

# ================= 1. 开启家宽接管 =================

enable_takeover() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}           配置家宽节点连接参数           ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo "1. SOCKS5 (常见于代理池和指纹浏览器节点)"
    echo "2. HTTP / HTTPS"
    echo "3. Shadowsocks (SS)"
    echo "4. Trojan"
    echo "5. VMess (基础 TCP)"
    read -p "请选择家宽协议 [1-5]: " proto_choice

    echo -e "\n${YELLOW}--- 输入节点信息 ---${PLAIN}"
    read -p "服务器 IP 或 域名: " isp_address
    read -p "服务器 端口: " isp_port

    local outbound_json=""

    # 构建协议 JSON
    case "$proto_choice" in
        1)
            read -p "用户名 (留空则无认证): " isp_user
            read -p "密码 (留空则无认证): " isp_pass
            if [ -z "$isp_user" ]; then
                outbound_json="{\"type\": \"socks\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"version\": \"5\"}"
            else
                outbound_json="{\"type\": \"socks\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"version\": \"5\", \"username\": \"$isp_user\", \"password\": \"$isp_pass\"}"
            fi
            ;;
        2)
            read -p "用户名 (留空则无认证): " isp_user
            read -p "密码 (留空则无认证): " isp_pass
            if [ -z "$isp_user" ]; then
                outbound_json="{\"type\": \"http\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port}"
            else
                outbound_json="{\"type\": \"http\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"username\": \"$isp_user\", \"password\": \"$isp_pass\"}"
            fi
            ;;
        3)
            read -p "加密方式 (如 aes-256-gcm): " isp_method
            read -p "连接密码: " isp_pass
            outbound_json="{\"type\": \"shadowsocks\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"method\": \"$isp_method\", \"password\": \"$isp_pass\"}"
            ;;
        4)
            read -p "连接密码: " isp_pass
            read -p "SNI 域名 (留空使用服务器地址): " isp_sni
            [ -z "$isp_sni" ] && isp_sni="$isp_address"
            outbound_json="{\"type\": \"trojan\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"password\": \"$isp_pass\", \"tls\": {\"enabled\": true, \"server_name\": \"$isp_sni\"}}"
            ;;
        5)
            read -p "UUID: " isp_uuid
            outbound_json="{\"type\": \"vmess\", \"tag\": \"$RESIDENTIAL_TAG\", \"server\": \"$isp_address\", \"server_port\": $isp_port, \"uuid\": \"$isp_uuid\", \"security\": \"auto\", \"alter_id\": 0}"
            ;;
        *)
            echo -e "${RED}输入错误，操作取消。${PLAIN}"
            sleep 2
            return
            ;;
    esac

    echo -e "\n${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}             选择需要接管的节点           ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo "1. 从本机已搭节点中选择 (自动读取)"
    echo "2. 手动指定入站 端口 (高级)"
    echo "3. 手动指定入站 Tag (高级)"
    read -p "请选择接管模式 [1-3]: " mode_choice

    local rule_json=""
    
    if [ "$mode_choice" == "1" ]; then
        echo -e "\n${YELLOW}已识别到以下本机节点 (Inbounds)：${PLAIN}"
        mapfile -t INBOUND_TAGS < <(jq -r '.inbounds[]? | select(.tag != null and .type != "direct" and .type != "block") | .tag' "$CONFIG_FILE")
        
        if [ ${#INBOUND_TAGS[@]} -eq 0 ]; then
            echo -e "${RED}未在配置文件中找到任何有效节点！${PLAIN}"
            sleep 2
            return
        fi

        for i in "${!INBOUND_TAGS[@]}"; do
            local pt=$(jq -r ".inbounds[] | select(.tag == \"${INBOUND_TAGS[$i]}\") | .listen_port // \"未知\"" "$CONFIG_FILE")
            # 【修复点1】补上 -e，让终端正常渲染颜色，而不是显示乱码
            echo -e " [$((i+1))] ${GREEN}${INBOUND_TAGS[$i]}${PLAIN} (端口: $pt)"
        done
        
        read -p "请输入对应数字选择接管目标 [1-${#INBOUND_TAGS[@]}]: " tag_idx
        
        if [[ ! "$tag_idx" =~ ^[0-9]+$ ]] || [ "$tag_idx" -lt 1 ] || [ "$tag_idx" -gt "${#INBOUND_TAGS[@]}" ]; then
             echo -e "${RED}输入错误，操作取消。${PLAIN}"
             sleep 2
             return
        fi

        local target_tag="${INBOUND_TAGS[$((tag_idx-1))]}"
        rule_json="{\"inbound\": [\"$target_tag\"], \"outbound\": \"$RESIDENTIAL_TAG\"}"
        echo -e "已选择接管节点: ${GREEN}$target_tag${PLAIN}"

    elif [ "$mode_choice" == "2" ]; then
        read -p "请输入需要接管的入站端口号 (如 10000): " target_port
        rule_json="{\"inbound_port\": [$target_port], \"outbound\": \"$RESIDENTIAL_TAG\"}"
    elif [ "$mode_choice" == "3" ]; then
        read -p "请输入需要接管的入站 Tag 名称: " target_tag
        rule_json="{\"inbound\": [\"$target_tag\"], \"outbound\": \"$RESIDENTIAL_TAG\"}"
    else
        echo -e "${RED}输入错误，操作取消。${PLAIN}"
        sleep 2
        return
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_$(date +%s)"
    echo -e "\n${YELLOW}正在修改并重载 Sing-box 配置...${PLAIN}"

    # 【修复点2】使用 // [] 兼容处理没有 route.rules 数组的情况，避免 null 报错
    if ! jq --arg tag "$RESIDENTIAL_TAG" \
       --argjson new_out "$outbound_json" \
       --argjson new_rule "$rule_json" \
    '
    .outbounds = ((.outbounds // []) | map(select(.tag != $tag))) + [$new_out] |
    .route.rules = [$new_rule] + ((.route.rules // []) | map(select(.outbound != $tag)))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
        echo -e "${RED}❌ jq 写入配置失败，请检查上面是否有报错信息！${PLAIN}"
        rm -f "${CONFIG_FILE}.tmp"
        read -n 1 -s -r -p "按任意键返回子菜单..."
        return
    fi
    
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    if sing-box check -c "$CONFIG_FILE"; then
        systemctl restart sing-box
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}✅ 家宽流量接管已成功开启！${PLAIN}"
        else
            echo -e "${RED}❌ Sing-box 启动失败，请检查配置。${PLAIN}"
        fi
    else
         echo -e "${RED}❌ 新配置存在语法错误。已自动回滚！${PLAIN}"
         LATEST_BAK=$(ls -t "${CONFIG_FILE}.bak_"* | head -1 2>/dev/null)
         [ -n "$LATEST_BAK" ] && mv "$LATEST_BAK" "$CONFIG_FILE"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回子菜单..."
}

# ================= 2. 查看接管状态 =================

view_status() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          当前家宽流量接管状态            ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    if ! grep -q "$RESIDENTIAL_TAG" "$CONFIG_FILE"; then
        echo -e "\n${YELLOW}当前未开启任何家宽接管配置。${PLAIN}\n"
    else
        echo -e "${GREEN}【已绑定的家宽节点信息】${PLAIN}"
        jq -r '.outbounds[]? | select(.tag == "'$RESIDENTIAL_TAG'") | 
        " - 协议类型: \(.type) \n - 节点地址: \(.server):\(.server_port)"' "$CONFIG_FILE"

        echo -e "\n${GREEN}【被接管的本机流量】${PLAIN}"
        jq -r '(.route.rules // [])[] | select(.outbound == "'$RESIDENTIAL_TAG'") |
        if .inbound then " - 已接管节点标签 (Tag): \(.inbound | join(\", \"))" else empty end,
        if .inbound_port then " - 已接管入站端口 (Port): \(.inbound_port | join(\", \"))" else empty end' "$CONFIG_FILE"
        echo ""
    fi
    echo -e "${CYAN}==========================================${PLAIN}"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# ================= 3. 移除接管 =================

disable_takeover() {
    echo -e "${YELLOW}正在移除家宽接管规则...${PLAIN}"
    
    if ! grep -q "$RESIDENTIAL_TAG" "$CONFIG_FILE"; then
         echo -e "${GREEN}未发现家宽接管规则，无需清理。${PLAIN}"
         sleep 2
         return
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_$(date +%s)"

    # 【修复点3】同理，移除时也增加容错处理
    if ! jq --arg tag "$RESIDENTIAL_TAG" \
    '
    .outbounds = ((.outbounds // []) | map(select(.tag != $tag))) |
    .route.rules = ((.route.rules // []) | map(select(.outbound != $tag)))
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
         echo -e "${RED}❌ 清理配置失败。${PLAIN}"
         rm -f "${CONFIG_FILE}.tmp"
         read -n 1 -s -r -p "按任意键返回子菜单..."
         return
    fi
    
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

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
    echo -e " 1. ${GREEN}开启/修改${PLAIN} 家宽流量接管 (接管本机节点流量)"
    echo -e " 2. ${CYAN}查看当前${PLAIN} 流量接管状态"
    echo -e " 3. ${RED}关闭/移除${PLAIN} 家宽流量接管"
    echo -e " 0. 返回主菜单"
    echo -e "${GREEN}===========================================${PLAIN}"
    read -p "请输入选项 [0-3]: " choice

    case "$choice" in
        1) enable_takeover; show_menu ;;
        2) view_status; show_menu ;;
        3) disable_takeover; show_menu ;;
        0) echo -e "${GREEN}退出家宽模块...${PLAIN}"; sleep 1; exit 0 ;;
        *) echo -e "${RED}请输入正确的数字 [0-3]${PLAIN}"; sleep 2; show_menu ;;
    esac
}

show_menu
