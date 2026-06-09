#!/bin/bash

# ==========================================
# Realm 一键转发脚本 v3.2.4 (含动态节点命名增强)
# 更新日志:
# 1. 新增输入错误计数器
# 2. 连续输错 2 次自动返回主菜单
# 3. 新增本机公网 IP 自动检测
# 4. 新增 IP+协议 自动拼装生成节点名称
# ==========================================

# --- 基础配置 ---
sh_ver="3.2.4"
panel_ver="v3.2.4"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 路径定义
REALM_DIR="/root/realm"
REALM_BIN="${REALM_DIR}/realm"
CONFIG_DIR="/root/.realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
PANEL_DIR="${REALM_DIR}/web"
PANEL_BIN="${PANEL_DIR}/realm_web"

PUBLIC_IP="" # 全局IP变量缓存

# --- 状态检测函数 ---

get_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

get_panel_status() {
    if [ ! -f "$PANEL_BIN" ]; then
        echo -e "${RED}未安装${PLAIN}"
    elif systemctl is-active --quiet realm-panel; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${YELLOW}已安装但未启动${PLAIN}"
    fi
}

# --- 核心校验与辅助函数 ---

get_public_ip() {
    if [ -z "$PUBLIC_IP" ]; then
        echo -e "${YELLOW}正在自动检测本机公网 IP，请稍候...${PLAIN}"
        PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ipv4.icanhazip.com || curl -s4 api.ipify.org)
        if [ -z "$PUBLIC_IP" ]; then 
            PUBLIC_IP="自动获取失败IP"
            echo -e "${RED}IP获取失败，将使用默认占位符。${PLAIN}"
        fi
    fi
}

validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        echo -e "${RED}错误: 端口必须是 1-65535 之间的数字。${PLAIN}"
        return 1
    fi
}

validate_ip() {
    local ip=$1
    if [[ -z "$ip" ]]; then
        echo -e "${RED}错误: 地址不能为空。${PLAIN}"
        return 1
    fi
    if [[ "$ip" =~ ^[a-zA-Z0-9\.\:\-\[\]]+$ ]]; then
        return 0
    else
        echo -e "${RED}错误: 无效的 IP 或域名格式。${PLAIN}"
        return 1
    fi
}

check_port_available() {
    local port=$1
    if command -v ss >/dev/null; then
        if ss -tulpn | grep ":${port} " | grep -qv "realm"; then
            echo -e "${RED}错误: 本机端口 ${port} 已被其他程序占用。${PLAIN}"
            return 1
        fi
    fi
    return 0
}

check_rule_exists() {
    local port=$1
    if [ -f "$CONFIG_FILE" ]; then
        if grep -qE "listen = \"(\\[::]:${port}|0\\.0\\.0\\.0:${port})\"" "$CONFIG_FILE"; then
            echo -e "${RED}错误: 端口 ${port} 的规则已存在。${PLAIN}"
            return 0
        fi
    fi
    return 1
}

# --- 基础功能 ---

init_env() {
    mkdir -p "$REALM_DIR"
    mkdir -p "$CONFIG_DIR"
    [ ! -f "$CONFIG_FILE" ] && write_config_header
}

write_config_header() {
    cat <<EOF > "$CONFIG_FILE"
[network]
no_tcp = false
use_udp = true

EOF
}

check_dependencies() {
    local dependencies=("wget" "tar" "systemctl" "sed" "grep" "curl" "unzip" "ss")
    local missing=()
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then missing+=("$dep"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}安装依赖: ${missing[*]} ...${PLAIN}"
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y "${missing[@]}" iproute2
        elif [ -x "$(command -v yum)" ]; then
            yum install -y "${missing[@]}" iproute
        else
            echo -e "${RED}请手动安装依赖。${PLAIN}"; exit 1
        fi
    fi
}

install_realm() {
    echo -e "${GREEN}> 部署 Realm...${PLAIN}"
    check_dependencies; init_env
    local version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$version" ] && version="v2.6.0"
    
    local arch=$(uname -m)
    local filename=""
    case "$arch" in
        x86_64) filename="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64) filename="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) echo -e "${RED}不支持架构: $arch${PLAIN}"; return 1 ;;
    esac

    wget -O "/tmp/realm.tar.gz" "https://github.com/zhboner/realm/releases/download/${version}/${filename}" || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
    tar -xvf /tmp/realm.tar.gz -C "$REALM_DIR" && rm -f /tmp/realm.tar.gz
    chmod +x "$REALM_BIN"

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_BIN} -c ${CONFIG_FILE}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable realm; systemctl restart realm
    echo -e "${GREEN}安装完成${PLAIN}"
}

uninstall_realm() {
    read -p "确定卸载 Realm? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    systemctl stop realm; systemctl disable realm
    rm -f "$SERVICE_FILE"; systemctl daemon-reload; rm -rf "$REALM_DIR"
    read -p "删除配置? [y/N]: " del_conf
    [[ "$del_conf" == "y" || "$del_conf" == "Y" ]] && rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}已卸载${PLAIN}"
}

# --- 转发管理 (已添加重试限制) ---

add_forward() {
    echo -e "${YELLOW}>>> 添加转发 (连续错误2次自动返回)${PLAIN}"
    
    # 1. 本机端口
    local attempt=0
    while true; do
        read -e -p "本机端口: " lp
        if ! validate_port "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if ! check_port_available "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if check_rule_exists "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    # 2. 落地IP
    attempt=0
    while true; do
        read -e -p "落地IP/域名: " rip
        if ! validate_ip "$rip"; then
             ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
             continue
        fi
        break
    done

    # 3. 落地端口
    attempt=0
    while true; do
        read -e -p "落地端口: " rp
        if ! validate_port "$rp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    # 4. 自动生成节点名称
    get_public_ip
    read -e -p "请输入此转发的底层协议 (如 VLESS, Hy2, TUIC，直接回车默认填写 Realm): " protocol
    protocol=${protocol:-Realm}
    node_name="${PUBLIC_IP}-${protocol}"

    cat <<EOF >> "$CONFIG_FILE"

# 节点名称: $node_name
[[endpoints]]
listen = "[::]:$lp"
remote = "$rip:$rp"
EOF
    restart_service

    echo ""
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}✅ 转发添加成功！客户端配置信息如下：${PLAIN}"
    echo -e "${YELLOW}节点建议名称 : ${GREEN}${node_name}${PLAIN}"
    echo -e "${YELLOW}客户端连接IP : ${GREEN}${PUBLIC_IP}${PLAIN}"
    echo -e "${YELLOW}客户端连接端口: ${GREEN}${lp}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
}

add_range_forward() {
    echo -e "${YELLOW}>>> 端口段转发 (连续错误2次自动返回)${PLAIN}"
    local attempt=0
    
    while true; do read -e -p "落地IP: " rip; validate_ip "$rip" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "起始端口: " sp; validate_port "$sp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "结束端口: " ep; validate_port "$ep" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "落地基准端口: " rbp; validate_port "$rbp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done

    [ "$sp" -ge "$ep" ] && { echo -e "${RED}起始必须小于结束${PLAIN}"; return; }

    # 自动生成节点名称前缀
    get_public_ip
    read -e -p "请输入此转发的底层协议 (如 VLESS, Hy2，直接回车默认填写 Realm): " protocol
    protocol=${protocol:-Realm}

    echo "生成中..."
    local rp=$rbp
    for ((p=$sp; p<=$ep; p++)); do
        if ! grep -q "listen = \"[::]:$p\"" "$CONFIG_FILE"; then
            cat <<EOF >> "$CONFIG_FILE"

# 节点名称: ${PUBLIC_IP}-${protocol}-端口${p}
[[endpoints]]
listen = "[::]:$p"
remote = "$rip:$rp"
EOF
        fi
        ((rp++))
    done
    restart_service

    echo ""
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}✅ 端口段转发添加成功！${PLAIN}"
    echo -e "${YELLOW}您的节点命名参考前缀 : ${GREEN}${PUBLIC_IP}-${protocol}${PLAIN}"
    echo -e "${YELLOW}客户端连接统一IP     : ${GREEN}${PUBLIC_IP}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
}

delete_forward() {
    [ ! -f "$CONFIG_FILE" ] && return
    local listens=($(grep "listen =" "$CONFIG_FILE" | awk -F'"' '{print $2}'))
    local remotes=($(grep "remote =" "$CONFIG_FILE" | awk -F'"' '{print $2}'))
    # 尝试提取注释的节点名称
    local remarks=($(grep -B 1 "listen =" "$CONFIG_FILE" | grep "^#" | awk -F': ' '{print $2}'))

    [ ${#listens[@]} -eq 0 ] && { echo "无规则"; return; }

    echo "==============="
    for ((i=0; i<${#listens[@]}; i++)); do
        local d_remark=${remarks[i]:-"未命名节点"}
        echo -e "${GREEN}$((i+1)).${PLAIN} [${YELLOW}${d_remark}${PLAIN}] ${listens[i]} -> ${remotes[i]}"
    done
    echo "==============="
    read -p "删除序号(0取消): " c
    [[ "$c" == "0" || -z "$c" ]] && return
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#listens[@]}" ]; then
        echo -e "${RED}无效序号${PLAIN}"; return
    fi
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"; write_config_header
    local del_idx=$((c-1))
    for ((i=0; i<${#listens[@]}; i++)); do
        if [ $i -ne $del_idx ]; then
            local p_remark=${remarks[i]:-"自动重写节点"}
            cat <<EOF >> "$CONFIG_FILE"

# 节点名称: ${p_remark}
[[endpoints]]
listen = "${listens[i]}"
remote = "${remotes[i]}"
EOF
        fi
    done
    restart_service
}

# --- 服务控制 ---
start_service() { systemctl start realm; echo "已启动"; }
stop_service() { systemctl stop realm; echo "已停止"; }
restart_service() { 
    systemctl daemon-reload; systemctl restart realm; sleep 1
    systemctl is-active --quiet realm && echo -e "${GREEN}重启成功${PLAIN}" || echo -e "${RED}重启失败${PLAIN}"
}

# --- 面板管理 ---
panel_management() {
    while true; do
        clear
        echo "=== Realm 面板管理 ($panel_ver) ==="
        echo -e "面板状态: $(get_panel_status)"
        echo "============================="
        echo "1. 安装面板"
        echo "2. 启动面板"
        echo "3. 停止面板"
        echo "4. 卸载面板"
        echo "0. 返回上级"
        read -p "选择: " pc
        case $pc in
            1) install_panel ;;
            2) systemctl start realm-panel; echo "尝试启动..." ;;
            3) systemctl stop realm-panel; echo "已停止" ;;
            4) uninstall_panel ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
        read -p "按回车继续..."
    done
}

install_panel() {
    check_dependencies
    local arch=$(uname -m)
    local p_file=""
    case "$arch" in
        x86_64) p_file="realm-panel-linux-amd64.zip" ;;
        aarch64|arm64) p_file="realm-panel-linux-arm64.zip" ;;
        *) echo "不支持架构: $arch"; return ;;
    esac

    mkdir -p "$PANEL_DIR"
    local url="https://github.com/wcwq98/realm/releases/download/${panel_ver}/${p_file}"
    local tmp_zip="/tmp/${p_file}"
    local tmp_dir="/tmp/realm_panel_$$"

    if ! wget -O "$tmp_zip" "$url"; then
        echo -e "${RED}下载失败${PLAIN}"
        rm -f "$tmp_zip"
        return 1
    fi

    mkdir -p "$tmp_dir"
    unzip -o "$tmp_zip" -d "$tmp_dir"
    rm -f "$tmp_zip"

    # 无论 zip 内部目录结构如何，都能找到 realm_web 二进制
    local found_bin
    found_bin=$(find "$tmp_dir" -name "realm_web" -type f 2>/dev/null | head -1)
    if [ -z "$found_bin" ]; then
        # 兜底：找第一个非文本可执行文件
        found_bin=$(find "$tmp_dir" -maxdepth 3 -type f ! -name "*.txt" ! -name "*.md" 2>/dev/null | head -1)
    fi

    if [ -z "$found_bin" ]; then
        echo -e "${RED}解压后未找到可执行文件，请手动安装${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi

    cp "$found_bin" "$PANEL_BIN"
    chmod +x "$PANEL_BIN"

    # 复制静态资源和模板
    [ -d "$tmp_dir/static" ]    && cp -r "$tmp_dir/static"    "$PANEL_DIR/"
    [ -d "$tmp_dir/templates" ] && cp -r "$tmp_dir/templates" "$PANEL_DIR/"
    # 兼容 zip 内有子目录的情况
    local sub_dir
    sub_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -n "$sub_dir" ]; then
        [ -d "$sub_dir/static" ]    && cp -r "$sub_dir/static"    "$PANEL_DIR/"
        [ -d "$sub_dir/templates" ] && cp -r "$sub_dir/templates" "$PANEL_DIR/"
    fi
    # 复制默认配置（不覆盖已有配置）
    [ -f "$tmp_dir/config.toml" ] && [ ! -f "$PANEL_DIR/config.toml" ] && cp "$tmp_dir/config.toml" "$PANEL_DIR/"

    rm -rf "$tmp_dir"

    cat <<EOF > /etc/systemd/system/realm-panel.service
[Unit]
Description=Realm Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_BIN}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable realm-panel; systemctl start realm-panel
    echo -e "${GREEN}面板安装成功!${PLAIN}"
}

uninstall_panel() {
    systemctl stop realm-panel; systemctl disable realm-panel
    rm -f /etc/systemd/system/realm-panel.service; systemctl daemon-reload
    rm -rf "$PANEL_DIR"
    echo "已卸载"
}

# --- 脚本更新 ---
Update_Shell() {
    local url="https://raw.githubusercontent.com/wcwq98/realm/main/realm.sh"
    local new_ver=$(wget -qO- "$url" | grep 'sh_ver="' | awk -F "=" '{print $NF}' | tr -d '"' | head -1)
    [[ -z "$new_ver" ]] && { echo -e "${RED}检测失败${PLAIN}"; return; }
    [[ "$new_ver" == "$sh_ver" ]] && { echo "已是最新"; return; }
    read -p "更新到 $new_ver? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && wget -N --no-check-certificate "$url" -O realm.sh && chmod +x realm.sh && echo "已更新" && exit 0
}

# --- 主菜单 ---
show_menu() {
    clear
    echo "################################################"
    echo "#        Realm 一键转发脚本 (v${sh_ver})         #"
    echo "################################################"
    echo -e " Realm 状态: $(get_status)"
    echo -e " 面板 状态: $(get_panel_status)"
    echo "------------------------------------------------"
    echo "  1. 安装 / 重置 Realm"
    echo "  2. 卸载 Realm"
    echo "------------------------------------------------"
    echo "  3. 添加转发规则"
    echo "  4. 添加端口段转发"
    echo "  5. 删除转发规则"
    echo "  6. 查看当前配置"
    echo "------------------------------------------------"
    echo "  7. 启动服务"
    echo "  8. 停止服务"
    echo "  9. 重启服务"
    echo "------------------------------------------------"
    echo "  10. 更新脚本"
    echo "  11. 面板管理"
    echo "  0. 退出脚本"
    echo "################################################"
}

main() {
    check_dependencies; init_env
    while true; do
        show_menu
        read -p "选择 [0-11]: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_forward ;;
            4) add_range_forward ;;
            5) delete_forward ;;
            6) cat "$CONFIG_FILE" ;;
            7) start_service ;;
            8) stop_service ;;
            9) restart_service ;;
            10) Update_Shell ;;
            11) panel_management ;;
            0) exit 0 ;;
            *) echo "无效" ;;
        esac
        [ "$opt" != "0" ] && read -p "按回车返回..."
    done
}

main
