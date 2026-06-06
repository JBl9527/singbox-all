# 修改伪装域名的功能函数
modify_camouflage_domain() {
    local CONFIG_FILE="/etc/sing-box/config.json"
    
    # 1. 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 未检测到 Sing-box 配置文件，请确认服务是否已成功安装！${PLAIN}"
        return 1
    fi

    # 2. 自动检查并安装 jq 工具（用于精准解析和修改 JSON）
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${YELLOW}⟳ 正在安装 JSON 解析工具 jq...${PLAIN}"
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install jq -y >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install jq -y >/dev/null 2>&1
        fi
    fi

    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          修改 Sing-box 伪装域名          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    # 3. 尝试读取当前的伪装域名（此处以常用的 REALITY 或 WebSocket 节点结构为例）
    # 你可以根据你实际脚本生成的 JSON 路径进行微调
    local CURRENT_DOMAIN=$(jq -r '.inbounds[0].tls.reality.server_names[0] // .inbounds[0].transport.host // "未找到"' "$CONFIG_FILE")
    
    echo -e "当前配置的伪装域名为: ${YELLOW}${CURRENT_DOMAIN}${PLAIN}"
    echo -e "------------------------------------------"
    read -p "请输入新的伪装域名 (例如 google.com): " NEW_DOMAIN

    # 4. 校验输入是否为空
    if [ -z "$NEW_DOMAIN" ]; then
        echo -e "${RED}❌ 输入不能为空，取消修改。${PLAIN}"
        return 1
    fi

    # 5. 使用 jq 动态精准重写 JSON 配置文件
    # 示例包含两种常见场景（修改 TLS/REALITY 域名 或 修改 WebSocket 的 Host 头部）
    local TMP_CONFIG=$(mktemp)
    
    # 如果是 REALITY 协议，重写 reality.server_names
    if jq -e '.inbounds[0].tls.reality' "$CONFIG_FILE" >/dev/null 2>&1; then
        jq ".inbounds[0].tls.reality.server_names = [\"$NEW_DOMAIN\"] | .inbounds[0].tls.key_pair.server_name = \"$NEW_DOMAIN\"" "$CONFIG_FILE" > "$TMP_CONFIG"
    # 如果是 WebSocket/gRPC 协议，重写 transport.host
    elif jq -e '.inbounds[0].transport.host' "$CONFIG_FILE" >/dev/null 2>&1; then
        jq ".inbounds[0].transport.host = \"$NEW_DOMAIN\"" "$CONFIG_FILE" > "$TMP_CONFIG"
    else
        # 通用兜底策略：如果你的脚本用到了特定的本地环境变量记录文件（如 /etc/sing-box/env.sh），也可以在这里用 sed 直接修改变量
        echo -e "${RED}⚠️ 未能在 JSON 中匹配到标准的 TLS 或 Transport 节点结构。${PLAIN}"
        echo -e "${YELLOW}尝试执行强行字段写入...${PLAIN}"
        jq ".inbounds[0].tls.server_name = \"$NEW_DOMAIN\"" "$CONFIG_FILE" > "$TMP_CONFIG"
    fi

    # 6. 保存新配置并应用
    if [ -s "$TMP_CONFIG" ]; then
        mv "$TMP_CONFIG" "$CONFIG_FILE"
        echo -e "${GREEN}✔ 配置文件中的伪装域名已成功修改为: ${YELLOW}${NEW_DOMAIN}${PLAIN}"
        
        # 7. 重启服务使新域名生效
        echo -e "${YELLOW}⟳ 正在重启 Sing-box 服务以应用新配置...${PLAIN}"
        systemctl restart sing-box >/dev/null 2>&1
        sleep 1
        
        # 检查服务重启状态
        if systemctl is-active sing-box >/dev/null 2>&1; then
            echo -e "${GREEN}🎉 Sing-box 重启成功，新域名已生效！${PLAIN}"
        else
            echo -e "${RED}❌ 服务重启失败，请检查新输入的域名是否导致配置语法冲突！${PLAIN}"
        fi
    else
        rm -f "$TMP_CONFIG"
        echo -e "${RED}❌ 写入新配置失败，请检查磁盘空间或权限。${PLAIN}"
    fi
}
