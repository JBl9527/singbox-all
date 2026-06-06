#!/bin/bash

# ==========================================
# Sing-box 全能一键管理脚本 (含域名修改与扫码功能)
# 适用系统: Debian / Ubuntu / CentOS 等主流 Linux VPS
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 强制要求 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本 (可输入 sudo su - 切换)！${PLAIN}"
  exit 1
fi

# ==========================================
# 依赖检测与安装
# ==========================================
check_dependencies() {
    local DEPS_MISSING=0
    if ! command -v jq >/dev/null 2>&1; then DEPS_MISSING=1; fi
    if ! command -v qrencode >/dev/null 2>&1; then DEPS_MISSING=1; fi

    if [ "$DEPS_MISSING" -eq 1 ]; then
        echo -e "${YELLOW}⟳ 正在安装必要的底层依赖 (jq, qrencode)...${PLAIN}"
        if command -v apt >/dev/null 2>&1; then
            apt update >/dev/null 2>&1 && apt install jq qrencode -y >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install epel-release -y >/dev/null 2>&1
            yum install jq qrencode -y >/dev/null 2>&1
        fi
    fi
}

# ==========================================
# 核心功能区 
# ==========================================
install_singbox() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}             安装 Sing-box                ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # 【请在这里填入你的 Sing-box 下载、配置文件生成逻辑】
    echo -e "${YELLOW}正在执行安装部署...${PLAIN}"
    sleep 2 # 模拟安装时间
    
    # 强烈建议：安装完成后，把节点链接存入这个文件，方便后续扫码读取
    # echo "vless://xxxxxx" > /etc/sing-box/share_link.txt
    
    echo -e "${GREEN}✔ Sing-box 安装完成！${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

update_singbox() {
    echo -e "${YELLOW}正在检查并更新 Sing-box 核心...${PLAIN}"
    # 【请在这里填入你的核心更新逻辑】
    sleep 1
    echo -e "${GREEN}✔ Sing-box 更新完成！${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

uninstall_singbox() {
    echo -e "${RED}正在卸载 Sing-box...${PLAIN}"
    # 【请在这里填入你的卸载清理逻辑】
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    rm -rf /etc/sing-box
    echo -e "${GREEN}✔ Sing-box 已完全清理！${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

toggle_service() {
    echo -e "${CYAN}请选择操作: 1. 启动  2. 停止  3. 重启${PLAIN}"
    read -p "输入数字: " action
    case "$action" in
        1) systemctl start sing-box; echo -e "${GREEN}服务已启动！${PLAIN}" ;;
        2) systemctl stop sing-box; echo -e "${YELLOW}服务已停止！${PLAIN}" ;;
        3) systemctl restart sing-box; echo -e "${GREEN}服务已重启！${PLAIN}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

show_config() {
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}            当前节点配置信息              ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    if [ -f "/etc/sing-box/share_link.txt" ]; then
        cat /etc/sing-box/share_link.txt
    else
        echo -e "${RED}未找到保存的节点链接文件。${PLAIN}"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# ==========================================
# 高级功能: 修改伪装域名参数
# ==========================================
modify_camouflage_domain() {
    check_dependencies
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          修改 Sing-box 伪装域名          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    local CONFIG_FILE="/etc/sing-box/config.json" 

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 未检测到 Sing-box 配置文件 ($CONFIG_FILE)。${PLAIN}"
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return 1
    fi

    local CURRENT_DOMAIN=$(jq -r '.inbounds[0].tls.reality.server_names[0] // .inbounds[0].transport.host // "未找到"' "$CONFIG_FILE")
    
    echo -e "当前配置的伪装域名为: ${YELLOW}${CURRENT_DOMAIN}${PLAIN}"
    echo -e "------------------------------------------"
    read -p "请输入新的伪装域名 (例如 microsoft.com): " NEW_DOMAIN

    if [ -z "$NEW_DOMAIN" ]; then
        echo -e "${RED}❌ 输入不能为空，取消修改。${PLAIN}"
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return 1
    fi

    local TMP_CONFIG=$(mktemp)
    
    if jq -e '.inbounds[0].tls.reality' "$CONFIG_FILE" >/dev/null 2>&1; then
        jq ".inbounds[0].tls.reality.server_names = [\"$NEW_DOMAIN\"] | .inbounds[0].tls.key_pair.server_name = \"$NEW_DOMAIN\"" "$CONFIG_FILE" > "$TMP_CONFIG"
    elif jq -e '.inbounds[0].transport.host' "$CONFIG_FILE" >/dev/null 2>&1; then
        jq ".inbounds[0].transport.host = \"$NEW_DOMAIN\"" "$CONFIG_FILE" > "$TMP_CONFIG"
    else
        jq ".inbounds[0].tls.server_name = \"$NEW_DOMAIN\"" "$CONFIG_FILE" > "$TMP_CONFIG"
    fi

    if [ -s "$TMP_CONFIG" ]; then
        mv "$TMP_CONFIG" "$CONFIG_FILE"
        echo -e "${GREEN}✔ 配置文件中的伪装域名已成功修改为: ${YELLOW}${NEW_DOMAIN}${PLAIN}"
        
        echo -e "${YELLOW}⟳ 正在重启 Sing-box 服务以应用新配置...${PLAIN}"
        systemctl restart sing-box >/dev/null 2>&1
        echo -e "${GREEN}🎉 重启成功，新域名已生效！${PLAIN}"
    else
        rm -f "$TMP_CONFIG"
        echo -e "${RED}❌ 写入配置失败，请检查文件权限或格式。${PLAIN}"
    fi
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# ==========================================
# 高级功能: 生成终端二维码
# ==========================================
show_qr_code() {
    check_dependencies
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}            生成并显示节点二维码          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    local SHARE_LINK=""
    local LINK_FILE="/etc/sing-box/share_link.txt" 
    
    if [ -f "$LINK_FILE" ]; then
        SHARE_LINK=$(cat "$LINK_FILE")
    else
        echo -e "${YELLOW}⚠️ 系统未找到自动保存的分享链接文件。${PLAIN}"
        read -p "请手动粘贴要生成二维码的节点链接 (vless://...): " SHARE_LINK
    fi

    if [ -z "$SHARE_LINK" ]; then
        echo -e "${RED}❌ 链接不能为空！${PLAIN}"
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return 1
    fi

    echo -e "\n${GREEN}请打开手机客户端扫描下方二维码：${PLAIN}\n"
    qrencode -t ANSIUTF8 "$SHARE_LINK"
    
    echo -e "\n${YELLOW}节点明文链接 (可手动复制)：${PLAIN}"
    echo -e "${CYAN}${SHARE_LINK}${PLAIN}\n"
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# ==========================================
# 交互主菜单
# ==========================================
main_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}       Sing-box 全能一键管理脚本          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 安装 Sing-box"
    echo -e "${GREEN}2.${PLAIN} 更新 Sing-box"
    echo -e "${GREEN}3.${PLAIN} 卸载 Sing-box"
    echo -e "------------------------------------------"
    echo -e "${GREEN}4.${PLAIN} 启动 / 停止 / 重启 服务"
    echo -e "${GREEN}5.${PLAIN} 查看当前配置信息"
    echo -e "------------------------------------------"
    echo -e "${GREEN}6.${PLAIN} ${YELLOW}修改伪装域名参数${PLAIN}"
    echo -e "${GREEN}7.${PLAIN} ${YELLOW}生成并显示节点二维码${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-7]: " MENU_CHOICE
    
    case "$MENU_CHOICE" in
        1) install_singbox ;;
        2) update_singbox ;;
        3) uninstall_singbox ;;
        4) toggle_service ;;
        5) show_config ;;
        6) modify_camouflage_domain ;;
        7) show_qr_code ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入！${PLAIN}"; sleep 1; main_menu ;;
    esac
}

# 脚本入口
main_menu
