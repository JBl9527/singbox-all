#!/bin/bash

# ==========================================
# 独立的 Realm 端口转发管理模块
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

REALM_DIR="/root/realm"
REALM_BIN="${REALM_DIR}/realm"
REALM_CONF_DIR="/root/.realm"
REALM_CONF_FILE="${REALM_CONF_DIR}/config.toml"
REALM_SERVICE_FILE="/etc/systemd/system/realm.service"

PUBLIC_IP="" 

get_public_ip() {
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ipv4.icanhazip.com || curl -s4 api.ipify.org)
        if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP="IP获取失败"; fi
    fi
}

get_realm_status() {
    if systemctl is-active --quiet realm; then echo -e "${GREEN}运行中${PLAIN}"; else echo -e "${RED}未运行${PLAIN}"; fi
}

install_realm() {
    echo -e "${YELLOW}>>> 正在部署 Realm 转发服务...${PLAIN}"
    mkdir -p "$REALM_DIR" "$REALM_CONF_DIR"
    [ ! -f "$REALM_CONF_FILE" ] && cat << EOF_REALM_BASE > "$REALM_CONF_FILE"
[network]
no_tcp = false
use_udp = true

EOF_REALM_BASE

    local version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$version" ] && version="v2.6.0"
    local arch=$(uname -m)
    local filename=""
    case "$arch" in
        x86_64) filename="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64) filename="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) echo -e "${RED}不支持架构: $arch${PLAIN}"; sleep 2; return ;;
    esac

    wget -qO "/tmp/realm.tar.gz" "https://github.com/zhboner/realm/releases/download/${version}/${filename}"
    tar -xzf /tmp/realm.tar.gz -C "$REALM_DIR" && rm -f /tmp/realm.tar.gz
    chmod +x "$REALM_BIN"

    cat << EOF_REALM_SERVICE > "$REALM_SERVICE_FILE"
[Unit]
Description=Realm Forwarding Service
After=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_BIN} -c ${REALM_CONF_FILE}

[Install]
WantedBy=multi-user.target
EOF_REALM_SERVICE
    systemctl daemon-reload; systemctl enable realm >/dev/null 2>&1; systemctl restart realm
    echo -e "${GREEN}✔ Realm 转发服务安装完成并已启动！${PLAIN}"; sleep 2
}

realm_add_forward() {
    if [ ! -f "$REALM_BIN" ]; then install_realm; fi
    clear
    echo -e "${YELLOW}>>> 添加单端口转发 (Realm)${PLAIN}"
    read -p "请输入本机监听端口: " lp
    read -p "请输入目标落地 IP/域名: " rip
    read -p "请输入目标落地端口: " rp
    
    get_public_ip
    read -p "请输入此节点协议名称(默认Realm): " protocol
    protocol=${protocol:-Realm}
    node_name="${PUBLIC_IP}-${protocol}"

    cat << EOF_REALM_ADD >> "$REALM_CONF_FILE"

# 节点名称: $node_name
[[endpoints]]
listen = "[::]:$lp"
remote = "$rip:$rp"
EOF_REALM_ADD
    systemctl restart realm
    echo -e "${GREEN}✔ 转发规则添加成功！${PLAIN}"; sleep 2
}

realm_add_range() {
    if [ ! -f "$REALM_BIN" ]; then install_realm; fi
    clear
    echo -e "${YELLOW}>>> 添加端口段转发 (Realm)${PLAIN}"
    read -p "请输入起始端口: " sp
    read -p "请输入结束端口: " ep
    read -p "请输入目标落地 IP/域名: " rip
    read -p "请输入目标落地基准端口: " rbp

    get_public_ip
    read -p "请输入此节点协议名称(默认Realm): " protocol
    protocol=${protocol:-Realm}

    local rp=$rbp
    for ((p=$sp; p<=$ep; p++)); do
        if ! grep -q "listen = \"[::]:$p\"" "$REALM_CONF_FILE"; then
            cat << EOF_REALM_RANGE >> "$REALM_CONF_FILE"

# 节点名称: ${PUBLIC_IP}-${protocol}-端口${p}
[[endpoints]]
listen = "[::]:$p"
remote = "$rip:$rp"
EOF_REALM_RANGE
        fi
        ((rp++))
    done
    systemctl restart realm
    echo -e "${GREEN}✔ 端口段转发规则添加成功！${PLAIN}"; sleep 2
}

realm_delete_forward() {
    if [ ! -f "$REALM_CONF_FILE" ]; then echo "没有找到配置文件！"; sleep 2; return; fi
    local listens=($(grep "listen =" "$REALM_CONF_FILE" | awk -F'"' '{print $2}'))
    local remotes=($(grep "remote =" "$REALM_CONF_FILE" | awk -F'"' '{print $2}'))
    local remarks=($(grep -B 1 "listen =" "$REALM_CONF_FILE" | grep "^#" | awk -F': ' '{print $2}'))

    if [ ${#listens[@]} -eq 0 ]; then echo "当前没有任何转发规则。"; sleep 2; return; fi

    clear
    echo -e "${CYAN}=== 当前 Realm 转发规则 ===${PLAIN}"
    for ((i=0; i<${#listens[@]}; i++)); do
        local d_remark=${remarks[i]:-"未命名"}
        echo -e "${GREEN}$((i+1)).${PLAIN} [${YELLOW}${d_remark}${PLAIN}] ${listens[i]} -> ${remotes[i]}"
    done
    echo "==========================="
    read -p "请输入要删除的规则序号 (输入 0 取消): " c
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#listens[@]}" ]; then
        cat << EOF_REALM_DEL_BASE > "$REALM_CONF_FILE"
[network]
no_tcp = false
use_udp = true

EOF_REALM_DEL_BASE
        local del_idx=$((c-1))
        for ((i=0; i<${#listens[@]}; i++)); do
            if [ $i -ne $del_idx ]; then
                cat << EOF_REALM_DEL_LOOP >> "$REALM_CONF_FILE"

# 节点名称: ${remarks[i]:-"自动重写节点"}
[[endpoints]]
listen = "${listens[i]}"
remote = "${remotes[i]}"
EOF_REALM_DEL_LOOP
            fi
        done
        systemctl restart realm
        echo -e "${GREEN}删除成功！${PLAIN}"
    fi
    sleep 2
}

# --- 扩展模块的内部菜单 ---
realm_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${PLAIN}"
        echo -e "${CYAN}        端口转发管理 (独立 Realm 模块)    ${PLAIN}"
        echo -e "${CYAN}==========================================${PLAIN}"
        if [ -f "$REALM_BIN" ]; then
            echo -e "Realm 转发状态: $(get_realm_status)"
            echo -e "------------------------------------------"
            echo -e "${GREEN}1.${PLAIN} ➕ 添加单端口转发"
            echo -e "${GREEN}2.${PLAIN} ➕ 添加端口段转发"
            echo -e "${GREEN}3.${PLAIN} 📋 查看或删除转发规则"
            echo -e "${GREEN}4.${PLAIN} 🗑 彻底卸载 Realm 转发服务"
        else
            echo -e "Realm 转发状态: ${YELLOW}未安装${PLAIN}"
            echo -e "------------------------------------------"
            echo -e "${GREEN}1.${PLAIN} 🚀 立即安装 Realm 并添加转发规则"
        fi
        echo -e "${GREEN}0.${PLAIN} 🔙 返回 Sing-box 主程序"
        echo -e "${CYAN}==========================================${PLAIN}"
        read -p "请输入选项: " RMENU_CHOICE

        case "$RMENU_CHOICE" in
            1) if [ ! -f "$REALM_BIN" ]; then install_realm; fi; realm_add_forward ;;
            2) realm_add_range ;;
            3) realm_delete_forward ;;
            4) 
               systemctl stop realm >/dev/null 2>&1; systemctl disable realm >/dev/null 2>&1
               rm -f "$REALM_SERVICE_FILE"; systemctl daemon-reload
               rm -rf "$REALM_DIR" "$REALM_CONF_DIR"
               echo -e "${GREEN}Realm 已彻底卸载！${PLAIN}"; sleep 2 ;;
            0) break ;;
            *) echo -e "${RED}选择无效！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 启动菜单
realm_menu
