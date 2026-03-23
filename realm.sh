#!/bin/bash

# =========================================
# 作者: jinqians（原作者）
# 修改: noa1188（自动获取最新版本 & 架构适配）
# 日期: 2026年3月
# 描述: 这个脚本用于安装、卸载、realm转发
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

VERSION="1.1"

# 检查realm是否已安装
if [ -f "/root/realm/realm" ]; then
    echo "检测到realm已安装。"
    realm_status="已安装"
    realm_status_color="\033[0;32m"
else
    echo "realm未安装。"
    realm_status="未安装"
    realm_status_color="\033[0;31m"
fi

# 检查realm服务状态
check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;32m启用\033[0m"
    else
        echo -e "\033[0;31m未启用\033[0m"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "realm转发脚本"
    echo "================================================="
    echo -e "${GREEN}作者：jinqian${NC}"
    echo -e "${GREEN}网站：https://jinqians.com${NC}"
    echo "================================================="
    echo "1. 部署环境"
    echo "2. 添加转发"
    echo "3. 删除转发"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 重启服务"
    echo "7. 一键卸载"
    echo "8. 更新脚本"
    echo "================="
    echo -e "realm 状态：${realm_status_color}${realm_status}\033[0m"
    echo -n "realm 转发状态："
    check_realm_service_status
}

# 配置防火墙规则（TCP + UDP）
configure_firewall() {
    local port=$1
    local action=$2

    if command -v ufw >/dev/null 2>&1; then
        if [ "$action" = "add" ]; then
            ufw allow $port/tcp
            ufw allow $port/udp
        else
            ufw delete allow $port/tcp
            ufw delete allow $port/udp
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        if [ "$action" = "add" ]; then
            iptables -I INPUT -p tcp --dport $port -j ACCEPT
            iptables -I INPUT -p udp --dport $port -j ACCEPT
        else
            iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
            iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null
        fi
    fi
}

# 部署环境（自动获取最新版本 + 自动识别架构）
deploy_realm() {
    mkdir -p /root/realm
    cd /root/realm || exit 1

    # 安装依赖：curl + jq
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y curl jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl jq
    fi

    # 校验 jq 是否安装成功
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq 安装失败，无法继续。请手动安装 jq 后重试。${NC}"
        return 1
    fi

    echo "正在获取 realm 最新版本信息..."

    # 1. 获取最新 release 信息
    api_json=$(curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest)
    if [ $? -ne 0 ] || [ -z "$api_json" ]; then
        echo -e "${RED}获取最新版本信息失败，请检查网络或 GitHub 访问。${NC}"
        return 1
    fi

    latest_tag=$(echo "$api_json" | jq -r '.tag_name')
    if [ -z "$latest_tag" ] || [ "$latest_tag" = "null" ]; then
        echo -e "${RED}解析最新版本号失败。${NC}"
        return 1
    fi
    echo "检测到 realm 最新版本: $latest_tag"

    # 2. 检测本机架构，优先 full 包，找不到再用 slim
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            download_url=$(echo "$api_json" \
                | jq -r '.assets[] | select(.name | contains("realm-x86_64-unknown-linux-gnu.tar.gz") and (contains("slim") | not)) | .browser_download_url')
            if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
                download_url=$(echo "$api_json" \
                    | jq -r '.assets[] | select(.name | contains("realm-slim-x86_64-unknown-linux-gnu.tar.gz")) | .browser_download_url')
            fi
            ;;
        aarch64|arm64)
            download_url=$(echo "$api_json" \
                | jq -r '.assets[] | select(.name | contains("aarch64-unknown-linux-gnu.tar.gz") and (contains("slim") | not)) | .browser_download_url')
            if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
                download_url=$(echo "$api_json" \
                    | jq -r '.assets[] | select(.name | contains("slim") and (.name | contains("aarch64-unknown-linux-gnu.tar.gz"))) | .browser_download_url')
            fi
            ;;
        armv7l|armv7)
            download_url=$(echo "$api_json" \
                | jq -r '.assets[] | select(.name | contains("armv7-unknown-linux-gnueabihf.tar.gz") and (contains("slim") | not)) | .browser_download_url')
            if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
                download_url=$(echo "$api_json" \
                    | jq -r '.assets[] | select(.name | contains("slim") and (.name | contains("armv7-unknown-linux-gnueabihf.tar.gz"))) | .browser_download_url')
            fi
            ;;
        *)
            echo -e "${RED}未支持的架构: $arch，请手动查看 Release 中的文件名。${NC}"
            return 1
            ;;
    esac

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        echo -e "${RED}在最新 Release 中找不到适用于架构 $arch 的安装包。${NC}"
        return 1
    fi

    echo "下载链接: $download_url"
    echo "开始下载 realm..."

    # 3. 下载（--fail 确保服务端返回错误时 curl 报错退出）
    rm -f realm.tar.gz
    curl -fsSL "$download_url" -o realm.tar.gz
    if [ $? -ne 0 ] || [ ! -s realm.tar.gz ]; then
        echo -e "${RED}下载 realm 失败或文件为空。${NC}"
        return 1
    fi

    # 4. 解压
    tar -xf realm.tar.gz
    if [ ! -f "realm" ]; then
        echo -e "${RED}解压后未找到 realm 可执行文件，请检查压缩包结构。${NC}"
        return 1
    fi

    # 5. 清理安装包
    rm -f realm.tar.gz

    chmod +x realm

    # 创建配置文件（如果不存在）
    [ ! -f /root/realm/config.toml ] && touch /root/realm/config.toml

    # 创建 systemd 服务文件
    cat > /etc/systemd/system/realm.service << EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/root/realm/realm -c /root/realm/config.toml
WorkingDirectory=/root/realm

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 /etc/systemd/system/realm.service
    systemctl daemon-reload
    systemctl enable realm.service

    realm_status="已安装"
    realm_status_color="\\033[0;32m"

    echo -e "${GREEN}realm ${latest_tag} 安装完成（架构: ${arch}）。${NC}"
    echo "你可以在主菜单中启动/添加转发规则。"
}

# 卸载realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /root/realm
    echo "realm已被卸载。"
    realm_status="未安装"
    realm_status_color="\\033[0;31m"
}

# 添加转发规则
add_forward() {
    while true; do
        read -p "请输入本地监听端口: " port
        read -p "请输入目标IP/域名: " ip
        read -p "请输入目标端口: " remote_port

        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}错误：端口必须是1-65535之间的数字${NC}"
            continue
        fi

        echo "[[endpoints]]
listen = \"[::]:$port\"
remote = \"$ip:$remote_port\"" >> /root/realm/config.toml

        configure_firewall $port "add"

        echo -e "${GREEN}已添加转发规则：本地端口 $port -> $ip:$remote_port${NC}"

        read -p "是否继续添加(Y/N)? " answer
        if [[ $answer != "Y" && $answer != "y" ]]; then
            break
        fi
    done

    restart_service
}

# 删除转发规则
delete_forward() {
    echo "当前转发规则："
    local IFS=$'\n'
    local lines=($(grep -n 'listen =' /root/realm/config.toml))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    local index=1
    declare -A port_map
    for line in "${lines[@]}"; do
        # 修复：从 [::]:端口" 中精准提取端口号，避免误取行号
        local port=$(echo "$line" | grep -oE ':[0-9]+"' | tail -1 | tr -d ':"')
        port_map[$index]=$port
        local line_number=$(echo "$line" | cut -d':' -f1)
        local remote_line=$((line_number + 1))
        local remote=$(sed -n "${remote_line}p" /root/realm/config.toml | cut -d'"' -f2)
        echo "${index}. 本地端口 $port -> $remote"
        index=$((index + 1))
    done

    read -p "请输入要删除的转发规则序号，直接按回车返回主菜单： " choice
    if [ -z "$choice" ]; then
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]] || [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo -e "${RED}无效的选择${NC}"
        return
    fi

    local port_to_delete=${port_map[$choice]}
    configure_firewall $port_to_delete "remove"

    local line_number=$(echo "${lines[$((choice-1))]}" | cut -d':' -f1)
    sed -i "${line_number},$((line_number+1))d" /root/realm/config.toml

    echo -e "${GREEN}已删除转发规则和对应的防火墙规则${NC}"

    restart_service
}

# 重启服务
restart_service() {
    systemctl daemon-reload
    systemctl restart realm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}realm服务已重启${NC}"
    else
        echo -e "${RED}realm服务重启失败，请检查日志：journalctl -u realm${NC}"
    fi
}

# 启动服务
start_service() {
    systemctl daemon-reload
    systemctl enable realm.service
    systemctl start realm.service
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}realm服务已启动并设置为开机自启${NC}"
    else
        echo -e "${RED}realm服务启动失败，请检查日志：journalctl -u realm${NC}"
    fi
}

# 停止服务
stop_service() {
    systemctl stop realm
    echo "realm服务已停止。"
}

# 更新脚本（注意：拉取的是上游原版，会覆盖本脚本的自定义改动）
update_script() {
    echo -e "${GREEN}检查更新...${NC}"
    echo -e "${RED}警告：更新将拉取上游原版脚本，本脚本的自定义改动（自动检测版本/架构等）将被覆盖！${NC}"
    read -p "确认继续？(y/n) " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${GREEN}已取消更新${NC}"
        return 0
    fi

    remote_version=$(curl -s https://raw.githubusercontent.com/jinqians/realm/refs/heads/main/realm.sh | grep "^VERSION=" | cut -d'"' -f2)
    if [ $? -ne 0 ]; then
        echo -e "${RED}检查更新失败：无法获取远程版本信息${NC}"
        return 1
    fi

    if [ "$VERSION" = "$remote_version" ]; then
        echo -e "${GREEN}当前已是最新版本！${NC}"
        return 0
    fi

    echo -e "${GREEN}发现新版本：${remote_version}${NC}"
    read -p "是否更新？(y/n) " choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        echo -e "${GREEN}已取消更新${NC}"
        return 0
    fi

    wget -O /tmp/realm.sh https://raw.githubusercontent.com/jinqians/realm/refs/heads/main/realm.sh

    if [ $? -eq 0 ] && [ -s /tmp/realm.sh ]; then
        cp "$0" "$0.backup"
        mv /tmp/realm.sh "$0"
        chmod +x "$0"
        echo -e "${GREEN}脚本更新成功！已备份原脚本为 $0.backup${NC}"
        echo -e "${GREEN}请重新运行脚本以应用更新。${NC}"
        exit 0
    else
        echo -e "${RED}更新失败：无法下载新版本或文件为空${NC}"
        rm -f /tmp/realm.sh
    fi
}

# 主循环
while true; do
    show_menu
    read -p "请选择一个选项: " choice
    case $choice in
        1) deploy_realm ;;
        2) add_forward ;;
        3) delete_forward ;;
        4) start_service ;;
        5) stop_service ;;
        6) restart_service ;;
        7) uninstall_realm ;;
        8) update_script ;;
        *) echo "无效选项: $choice" ;;
    esac
    read -p "按任意键继续..." key
done
