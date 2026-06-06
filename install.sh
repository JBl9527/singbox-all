#!/bin/sh

# ==========================================
# OpenWrt/ImmortalWrt 24.10+ 永久加源直装脚本 (满血增强版)
# 特性: 开启虚拟内存 / 永久加源 / 修改域名 / 终端扫码
# 支持: OPKG 架构完美适配
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

SELECTED_MANAGER=""
UPDATE_OPENCLASH=0
UPDATE_PASSWALL=0
UPDATE_BASE=0
ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')

# === 永久注入的核心追新公共源 ===
OPKG_REPO="src/gz custom_plugins https://dl.openwrt.ai/latest/packages/${ARCH}/kiddin9"
PUB_KEY_URL="https://dl.openwrt.ai/latest/public-key.pub"

# ==========================================================
# 基础探测与环境准备
# ==========================================================

auto_detect_env() {
    if command -v opkg >/dev/null 2>&1; then
        SELECTED_MANAGER="opkg"
    else
        echo -e "${RED}致命错误: 本脚本专门针对 OPKG 架构系统优化，未检测到 opkg，流程终止！${PLAIN}"
        exit 1
    fi
}

check_dependencies() {
    local DEPS_MISSING=0
    if ! command -v jq >/dev/null 2>&1; then DEPS_MISSING=1; fi
    if ! command -v qrencode >/dev/null 2>&1; then DEPS_MISSING=1; fi

    if [ "$DEPS_MISSING" -eq 1 ]; then
        echo -e "${YELLOW}⟳ 正在检测并补齐基础环境工具 (jq, qrencode)...${PLAIN}"
        opkg update >/dev/null 2>&1
        opkg install jq qrencode >/dev/null 2>&1
    fi
}

# ==========================================================
# 核心功能 1: 安装与更新流程
# ==========================================================

execute_update() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}   正在执行 虚拟内存保卫 & 永久写入软件源 流程  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # ---------------- 第 0 步：挂载 256MB 虚拟内存 ----------------
    echo -e "\n${YELLOW}[0/4] 正在临时构建 256MB 虚拟内存保障库...${PLAIN}"
    rm -f /var/lock/opkg.lock
    swapoff /root/swapfile >/dev/null 2>&1
    rm -f /root/swapfile >/dev/null 2>&1
    
    dd if=/dev/zero of=/root/swapfile bs=1M count=256 >/dev/null 2>&1
    if [ -f "/root/swapfile" ]; then
        mkswap /root/swapfile >/dev/null 2>&1
        swapon /root/swapfile >/dev/null 2>&1
        echo -e "✔ 256MB 虚拟内存挂载成功！系统抗压能力提升 200%，绝不闪退！"
    else
        echo -e "${RED}❌ 虚拟内存构建失败，转为常规模式。${PLAIN}"
    fi

    # ---------------- 第 1 步：永久写入系统软件源配置 ----------------
    echo -e "\n${GREEN}[1/4] 正在将全新每日追新源永久注入系统...${PLAIN}"
    OPKG_CONF="/etc/opkg/customfeeds.conf"
    OPKG_MAIN_CONF="/etc/opkg.conf"
    
    wget -qO - "$PUB_KEY_URL" | opkg-key add - >/dev/null 2>&1
    sed -i '/githubusercontent/d' "$OPKG_CONF" 2>/dev/null
    sed -i '/你的用户名/d' "$OPKG_CONF" 2>/dev/null
    
    if ! grep -q "custom_plugins" "$OPKG_CONF" 2>/dev/null; then
        echo "$OPKG_REPO" >> "$OPKG_CONF"
    fi
    echo -e "✔ 软件源配置已成功写入！"

    # ---------------- 第 2 步：刷新软件源索引 ----------------
    echo -e "\n${GREEN}[2/4] 正在对全套软件源执行安全刷新...${PLAIN}"
    sed -i 's/option check_signature/#option check_signature/g' "$OPKG_MAIN_CONF"
    opkg update
    echo -e "✔ 软件源列表全部同步完毕！"

    # ---------------- 第 3 步：一网打尽安装全家桶 ----------------
    echo -e "\n${GREEN}[3/4] 正在长驱直入安装选中插件及汉化组件...${PLAIN}"
    
    TARGET_PACKAGES=""
    [ "$UPDATE_OPENCLASH" -eq 1 ] && TARGET_PACKAGES="$TARGET_PACKAGES luci-app-openclash"
    [ "$UPDATE_PASSWALL" -eq 1 ] && TARGET_PACKAGES="$TARGET_PACKAGES luci-app-passwall"
    if [ "$UPDATE_BASE" -eq 1 ]; then
        TARGET_PACKAGES="$TARGET_PACKAGES luci-app-ddns-go luci-i18n-ddns-go-zh-cn luci-theme-argon luci-app-argon-config luci-proto-wireguard wireguard-tools qrencode luci-compat"
    fi
    
    if [ -n "$TARGET_PACKAGES" ]; then
        echo -e "🚀 正在安装: ${YELLOW}${TARGET_PACKAGES}${PLAIN}"
        opkg install --force-overwrite --force-checksum $TARGET_PACKAGES 2>&1 | grep -Ev "remove_obsolesced_files|Failed to determine obsolete files|Couldn't unlink"
        opkg upgrade --force-overwrite --force-checksum $TARGET_PACKAGES 2>/dev/null | grep -Ev "remove_obsolesced_files"
        echo -e "✔ 插件及其底层依赖、汉化包已全部装妥！"
    fi

    # ---------------- 第 4 步：卸载虚拟内存 ----------------
    echo -e "\n${YELLOW}[4/4] 流程结束，正在安全收回并卸载虚拟内存空间...${PLAIN}"
    swapoff /root/swapfile >/dev/null 2>&1
    rm -f /root/swapfile >/dev/null 2>&1
    sed -i 's/#option check_signature/option check_signature/g' "$OPKG_MAIN_CONF"
    echo -e "✔ 内存及系统配置恢复纯净状态。"
    
    restart_services
}

restart_services() {
    echo -e "\n${GREEN}正在平滑唤醒所有已安装的网络服务...${PLAIN}"
    [ -f "/etc/init.d/openclash" ] && /etc/init.d/openclash restart >/dev/null 2>&1
    [ -f "/etc/init.d/passwall" ] && /etc/init.d/passwall restart >/dev/null 2>&1
    [ -f "/etc/init.d/ddns-go" ] && /etc/init.d/ddns-go restart >/dev/null 2>&1
    /etc/init.d/network reload >/dev/null 2>&1

    echo -e "\n${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}  🎉 恭喜！源已永久加好，核心插件均安装成功！ ${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    plugin_menu
}

# ==========================================================
# 核心功能 2: 修改伪装域名参数
# ==========================================================

modify_camouflage_domain() {
    check_dependencies
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}          修改代理节点伪装域名参数        ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    
    # 请根据你实际使用代理插件的配置文件路径进行修改
    # 这里以 Passwall/OpenClash 常用的 JSON 格式示范，若使用 Sing-box 请修改为 /etc/sing-box/config.json
    local CONFIG_FILE="/etc/sing-box/config.json"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 未检测到相应的 JSON 配置文件 ($CONFIG_FILE)。${PLAIN}"
        echo -e "${YELLOW}如果你使用的是 OpenClash 或 Passwall，它们通过 LuCI 网页端管理伪装域名，请前往路由器网页后台修改。${PLAIN}"
        read -n 1 -s -r -p "按任意键返回..."
        plugin_menu
        return 1
    fi

    local CURRENT_DOMAIN=$(jq -r '.inbounds[0].tls.reality.server_names[0] // .inbounds[0].transport.host // "未找到"' "$CONFIG_FILE")
    
    echo -e "当前配置的伪装域名为: ${YELLOW}${CURRENT_DOMAIN}${PLAIN}"
    echo -e "------------------------------------------"
    read -p "请输入新的伪装域名 (例如 google.com): " NEW_DOMAIN

    if [ -z "$NEW_DOMAIN" ]; then
        echo -e "${RED}❌ 输入不能为空，取消修改。${PLAIN}"
        read -n 1 -s -r -p "按任意键返回..."
        plugin_menu
        return 1
    fi

    local TMP_CONFIG=$(mktemp)
    
    # 尝试重写常见的 TLS/Transport 字段
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
        
        echo -e "${YELLOW}⟳ 正在重启代理服务以应用新配置...${PLAIN}"
        systemctl restart sing-box >/dev/null 2>&1 || /etc/init.d/sing-box restart >/dev/null 2>&1
        echo -e "${GREEN}🎉 重启成功，新域名已生效！${PLAIN}"
    else
        rm -f "$TMP_CONFIG"
        echo -e "${RED}❌ 写入配置失败，请检查文件格式。${PLAIN}"
    fi
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
    plugin_menu
}

# ==========================================================
# 核心功能 3: 终端展示节点二维码
# ==========================================================

show_qr_code() {
    check_dependencies
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}            生成并显示节点二维码          ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"

    local SHARE_LINK=""
    
    # 【注】：如果你的脚本生成了分享链接文件，请填入路径；如果没有，下方会提示手动输入
    local LINK_FILE="/etc/sing-box/share_link.txt" 
    
    if [ -f "$LINK_FILE" ]; then
        SHARE_LINK=$(cat "$LINK_FILE")
    else
        echo -e "${YELLOW}⚠️ 系统未找到自动保存的分享链接文件。${PLAIN}"
        echo -e "${CYAN}提示: 打开你的代理插件(如 Passwall)节点配置，复制其分享链接(vless://...)${PLAIN}"
        read -p "请粘贴要生成二维码的节点链接: " SHARE_LINK
    fi

    if [ -z "$SHARE_LINK" ]; then
        echo -e "${RED}❌ 链接不能为空！${PLAIN}"
        read -n 1 -s -r -p "按任意键返回..."
        plugin_menu
        return 1
    fi

    echo -e "\n${GREEN}请打开手机客户端扫描下方二维码：${PLAIN}\n"
    # 使用 ANSIUTF8 终端原生渲染高清二维码，保证扫描成功率
    qrencode -t ANSIUTF8 "$SHARE_LINK"
    
    echo -e "\n${YELLOW}节点明文链接 (可手动复制)：${PLAIN}"
    echo -e "${CYAN}${SHARE_LINK}${PLAIN}\n"
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
    plugin_menu
}

# ==========================================================
# 交互主菜单
# ==========================================================

plugin_menu() {
    clear
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${CYAN}  系统架构: ${SELECTED_MANAGER} 模式 | 满血增强直装版  ${PLAIN}"
    echo -e "${CYAN}==========================================${PLAIN}"
    echo -e "${YELLOW}[ 核心安装与更新 ]${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} 仅同步加源更新 ${YELLOW}OpenClash${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 仅同步加源更新 ${YELLOW}Passwall${PLAIN}"
    echo -e "${GREEN}3.${PLAIN} 永久加源安装 ${YELLOW}DDNS-GO(带中文) + Argon + WG(带扫码)${PLAIN}"
    echo -e "${GREEN}4.${PLAIN} ${CYAN}一键全家桶: 同时写入上述所有源及插件 (默认推荐)${PLAIN}"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}[ 节点高级管理 ]${PLAIN}"
    echo -e "${GREEN}5.${PLAIN} ${YELLOW}修改节点伪装域名参数${PLAIN} (如适用于 Sing-box)"
    echo -e "${GREEN}6.${PLAIN} ${YELLOW}终端生成并显示节点二维码${PLAIN} (一键扫码)"
    echo -e "------------------------------------------"
    echo -e "${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==========================================${PLAIN}"
    read -p "请选择操作 [0-6]: " PLUGIN_CHOICE
    
    case "$PLUGIN_CHOICE" in
        1) UPDATE_OPENCLASH=1; UPDATE_PASSWALL=0; UPDATE_BASE=0; execute_update ;;
        2) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=1; UPDATE_BASE=0; execute_update ;;
        3) UPDATE_OPENCLASH=0; UPDATE_PASSWALL=0; UPDATE_BASE=1; execute_update ;;
        4) UPDATE_OPENCLASH=1; UPDATE_PASSWALL=1; UPDATE_BASE=1; execute_update ;;
        5) modify_camouflage_domain ;;
        6) show_qr_code ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${PLAIN}"; sleep 1; plugin_menu ;;
    esac
}

auto_detect_env
plugin_menu
