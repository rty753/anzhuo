#!/bin/bash

#============================================================================
# Android Studio 远程桌面一键安装脚本
# 支持 HTTPS + 自定义/随机端口 + 自定义/随机密码
# 适用于 Ubuntu 20.04/22.04/24.04
#
# 功能：智能检测安装状态，支持续装、修复、管理
#============================================================================

set -e

# 设置非交互模式，避免 apt 弹出配置对话框
export DEBIAN_FRONTEND=noninteractive

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# 全局变量
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo ~$CURRENT_USER)

# 系统级配置目录（所有用户共享）
SYSTEM_CONFIG_DIR="/etc/android-studio-remote"
SYSTEM_CONFIG_FILE="$SYSTEM_CONFIG_DIR/config.conf"

# 用户级配置（向后兼容）
USER_CONFIG_FILE="$HOME_DIR/.android-studio-remote.conf"

# 自动检测配置文件位置
if [ -f "$SYSTEM_CONFIG_FILE" ]; then
    CONFIG_FILE="$SYSTEM_CONFIG_FILE"
elif [ -f "$USER_CONFIG_FILE" ]; then
    CONFIG_FILE="$USER_CONFIG_FILE"
else
    CONFIG_FILE="$SYSTEM_CONFIG_FILE"
fi

#============================================================================
# 工具函数
#============================================================================
generate_random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if ! ss -tuln | grep -q ":$port "; then
            echo $port
            return
        fi
    done
}

generate_random_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

check_port_available() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1
    else
        return 0
    fi
}

get_public_ip() {
    curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_SERVER_IP"
}

#============================================================================
# 安装状态检测
#============================================================================
check_component() {
    local name=$1
    local check_cmd=$2
    if eval "$check_cmd" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

detect_installation_status() {
    local status=()
    local errors=()

    # 检测各组件
    if check_component "XFCE" "dpkg -l | grep -q xfce4"; then
        status+=("xfce:installed")
    else
        status+=("xfce:missing")
        errors+=("XFCE 桌面未安装")
    fi

    if check_component "TigerVNC" "command -v vncserver"; then
        status+=("tigervnc:installed")
    else
        status+=("tigervnc:missing")
        errors+=("TigerVNC 未安装")
    fi

    if check_component "noVNC" "dpkg -l | grep -q novnc"; then
        status+=("novnc:installed")
    else
        status+=("novnc:missing")
        errors+=("noVNC 未安装")
    fi

    if check_component "Java" "command -v java"; then
        status+=("java:installed")
    else
        status+=("java:missing")
        errors+=("Java JDK 未安装")
    fi

    if check_component "Android Studio" "[ -d /opt/android-studio ]"; then
        status+=("android-studio:installed")
    else
        status+=("android-studio:missing")
        errors+=("Android Studio 未安装")
    fi

    if check_component "Chrome" "command -v google-chrome-stable"; then
        status+=("chrome:installed")
    else
        status+=("chrome:missing")
        errors+=("Google Chrome 未安装")
    fi

    if check_component "VNC Config" "[ -f $HOME_DIR/.vnc/passwd ]"; then
        status+=("vnc-config:installed")
    else
        status+=("vnc-config:missing")
        errors+=("VNC 密码未配置")
    fi

    if check_component "SSL Cert" "[ -f $HOME_DIR/.vnc/ssl/novnc.pem ]"; then
        status+=("ssl:installed")
    else
        status+=("ssl:missing")
        errors+=("SSL 证书未生成")
    fi

    # 检测服务状态
    if systemctl is-active --quiet vncserver@1 2>/dev/null; then
        status+=("vnc-service:running")
    else
        status+=("vnc-service:stopped")
        errors+=("VNC 服务未运行")
    fi

    if systemctl is-active --quiet novnc 2>/dev/null; then
        status+=("novnc-service:running")
    else
        status+=("novnc-service:stopped")
        errors+=("noVNC 服务未运行")
    fi

    # 返回结果
    echo "STATUS:${status[*]}"
    echo "ERRORS:${errors[*]}"
}

is_fully_installed() {
    local result=$(detect_installation_status)
    if echo "$result" | grep -q "missing\|stopped"; then
        return 1
    else
        return 0
    fi
}

# 检测是否有任何安装（系统级检测）
has_any_installation() {
    # 检查系统级配置
    [ -f "$SYSTEM_CONFIG_FILE" ] && return 0
    # 检查 Android Studio
    [ -d "/opt/android-studio" ] && return 0
    # 检查 systemd 服务
    [ -f "/etc/systemd/system/novnc.service" ] && return 0
    # 检查任何用户的配置文件
    for home in /home/*; do
        [ -f "$home/.android-studio-remote.conf" ] && return 0
    done
    [ -f "/root/.android-studio-remote.conf" ] && return 0
    return 1
}

# 查找并加载配置文件
find_and_load_config() {
    # 优先系统级
    if [ -f "$SYSTEM_CONFIG_FILE" ]; then
        CONFIG_FILE="$SYSTEM_CONFIG_FILE"
        return 0
    fi
    # 查找用户级
    for home in /home/*; do
        if [ -f "$home/.android-studio-remote.conf" ]; then
            CONFIG_FILE="$home/.android-studio-remote.conf"
            return 0
        fi
    done
    if [ -f "/root/.android-studio-remote.conf" ]; then
        CONFIG_FILE="/root/.android-studio-remote.conf"
        return 0
    fi
    return 1
}

get_missing_components() {
    local result=$(detect_installation_status)
    local status_line=$(echo "$result" | grep "^STATUS:")
    local missing=()

    [[ "$status_line" == *"xfce:missing"* ]] && missing+=("xfce")
    [[ "$status_line" == *"tigervnc:missing"* ]] && missing+=("tigervnc")
    [[ "$status_line" == *"novnc:missing"* ]] && missing+=("novnc")
    [[ "$status_line" == *"java:missing"* ]] && missing+=("java")
    [[ "$status_line" == *"android-studio:missing"* ]] && missing+=("android-studio")
    [[ "$status_line" == *"chrome:missing"* ]] && missing+=("chrome")
    [[ "$status_line" == *"vnc-config:missing"* ]] && missing+=("vnc-config")
    [[ "$status_line" == *"ssl:missing"* ]] && missing+=("ssl")
    [[ "$status_line" == *"vnc-service:stopped"* ]] && missing+=("vnc-service")
    [[ "$status_line" == *"novnc-service:stopped"* ]] && missing+=("novnc-service")

    echo "${missing[*]}"
}

#============================================================================
# 安装函数（模块化）
#============================================================================
install_base_deps() {
    print_info "安装基础依赖..."
    sudo apt-get update
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        wget curl git unzip net-tools ca-certificates gnupg lsb-release software-properties-common
    print_success "基础依赖安装完成"
}

install_xfce() {
    print_info "安装 XFCE 桌面环境..."
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        xfce4 xfce4-goodies dbus-x11
    print_success "XFCE 桌面环境安装完成"
}

install_tigervnc() {
    print_info "安装 TigerVNC Server..."
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        tigervnc-standalone-server tigervnc-common
    print_success "TigerVNC 安装完成"
}

configure_vnc() {
    local password=$1
    print_info "配置 VNC..."
    mkdir -p $HOME_DIR/.vnc
    echo "$password" | vncpasswd -f > $HOME_DIR/.vnc/passwd
    chmod 600 $HOME_DIR/.vnc/passwd

    cat > $HOME_DIR/.vnc/xstartup << 'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
exec startxfce4
EOF
    chmod +x $HOME_DIR/.vnc/xstartup
    print_success "VNC 配置完成"
}

install_novnc() {
    print_info "安装 noVNC..."
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        novnc python3-websockify python3-numpy
    print_success "noVNC 安装完成"
}

generate_ssl_cert() {
    print_info "生成 SSL 证书..."
    local ssl_dir="$HOME_DIR/.vnc/ssl"
    mkdir -p $ssl_dir
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout $ssl_dir/novnc.key \
        -out $ssl_dir/novnc.crt \
        -days 365 \
        -subj "/C=CN/ST=State/L=City/O=Organization/CN=localhost"
    cat $ssl_dir/novnc.key $ssl_dir/novnc.crt > $ssl_dir/novnc.pem
    chmod 600 $ssl_dir/novnc.pem
    print_success "SSL 证书生成完成"
}

install_java() {
    print_info "安装 Java JDK..."
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        openjdk-17-jdk
    print_success "Java JDK 安装完成"
}

install_android_studio() {
    print_info "下载并安装 Android Studio（约 1.5GB）..."
    local url="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2024.2.1.11/android-studio-2024.2.1.11-linux.tar.gz"
    wget -q --show-progress -O /tmp/android-studio.tar.gz "$url"
    sudo rm -rf /opt/android-studio
    sudo tar -xzf /tmp/android-studio.tar.gz -C /opt/
    rm -f /tmp/android-studio.tar.gz

    # 桌面快捷方式
    mkdir -p $HOME_DIR/Desktop
    cat > $HOME_DIR/Desktop/android-studio.desktop << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Android Studio
Icon=/opt/android-studio/bin/studio.svg
Exec=/opt/android-studio/bin/studio.sh
Categories=Development;IDE;
Terminal=false
StartupNotify=true
EOF
    chmod +x $HOME_DIR/Desktop/android-studio.desktop
    sudo ln -sf /opt/android-studio/bin/studio.sh /usr/local/bin/android-studio
    print_success "Android Studio 安装完成"
}

install_chrome() {
    print_info "安装 Google Chrome..."
    wget -q -O /tmp/google-chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        /tmp/google-chrome.deb || sudo apt-get install -f -y
    rm -f /tmp/google-chrome.deb

    # 设置默认浏览器
    sudo update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
    sudo update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
    xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || true

    # XFCE 默认浏览器
    mkdir -p $HOME_DIR/.config/xfce4
    echo "WebBrowser=google-chrome" > $HOME_DIR/.config/xfce4/helpers.rc

    # 桌面快捷方式
    cat > $HOME_DIR/Desktop/google-chrome.desktop << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Icon=google-chrome
Exec=/usr/bin/google-chrome-stable %U
Categories=Network;WebBrowser;
Terminal=false
StartupNotify=true
EOF
    chmod +x $HOME_DIR/Desktop/google-chrome.desktop
    print_success "Google Chrome 安装完成"
}

setup_services() {
    local novnc_port=$1
    local vnc_port=5901
    local ssl_dir="$HOME_DIR/.vnc/ssl"

    print_info "配置系统服务..."

    # VNC 服务
    sudo tee /etc/systemd/system/vncserver@.service > /dev/null << EOF
[Unit]
Description=TigerVNC Server for display %i
After=syslog.target network.target

[Service]
Type=simple
User=$CURRENT_USER
PAMName=login
PIDFile=$HOME_DIR/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver :%i -geometry 1920x1080 -depth 24 -localhost yes
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

    # noVNC 服务
    sudo tee /etc/systemd/system/novnc.service > /dev/null << EOF
[Unit]
Description=noVNC WebSocket Proxy
After=vncserver@1.service
Requires=vncserver@1.service

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/websockify --web=/usr/share/novnc --cert=$ssl_dir/novnc.pem $novnc_port localhost:$vnc_port
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable vncserver@1.service novnc.service
    print_success "系统服务配置完成"
}

start_services() {
    print_info "启动服务..."
    sudo systemctl start vncserver@1.service
    sleep 3
    sudo systemctl start novnc.service
    print_success "服务已启动"
}

restart_services() {
    print_info "重启服务..."
    sudo systemctl restart vncserver@1.service
    sleep 2
    sudo systemctl restart novnc.service
    print_success "服务已重启"
}

configure_firewall() {
    local port=$1
    print_info "配置防火墙（开放端口 $port）..."

    if command -v ufw &> /dev/null; then
        sudo ufw allow $port/tcp comment "noVNC for Android Studio" 2>/dev/null || true
    fi

    if command -v firewall-cmd &> /dev/null; then
        sudo firewall-cmd --add-port=$port/tcp --permanent 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
    fi

    if command -v iptables &> /dev/null && ! command -v ufw &> /dev/null && ! command -v firewall-cmd &> /dev/null; then
        sudo iptables -I INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
    fi

    print_success "防火墙配置完成"
}

save_config() {
    local port=$1
    local password=$2
    local install_user=$3

    # 创建系统级配置目录
    sudo mkdir -p $SYSTEM_CONFIG_DIR

    sudo tee $SYSTEM_CONFIG_FILE > /dev/null << EOF
# Android Studio 远程桌面配置
# 生成时间: $(date)
# 安装用户: ${install_user:-$CURRENT_USER}

NOVNC_PORT=$port
VNC_PASSWORD=$password
VNC_PORT=5901
INSTALL_USER=${install_user:-$CURRENT_USER}
EOF
    sudo chmod 644 $SYSTEM_CONFIG_FILE
    CONFIG_FILE="$SYSTEM_CONFIG_FILE"
}

#============================================================================
# 管理界面
#============================================================================
show_management_menu() {
    # 读取配置
    source $CONFIG_FILE 2>/dev/null || { print_error "配置文件不存在"; return 1; }
    local public_ip=$(get_public_ip)

    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║         Android Studio 远程桌面 - 管理面板                 ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${GREEN}访问地址:${NC}  https://$public_ip:$NOVNC_PORT/vnc.html"
        echo -e "  ${GREEN}VNC 密码:${NC}  $VNC_PASSWORD"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
        echo ""

        # 服务状态
        local vnc_status novnc_status
        if systemctl is-active --quiet vncserver@1 2>/dev/null; then
            vnc_status="${GREEN}运行中${NC}"
        else
            vnc_status="${RED}已停止${NC}"
        fi

        if systemctl is-active --quiet novnc 2>/dev/null; then
            novnc_status="${GREEN}运行中${NC}"
        else
            novnc_status="${RED}已停止${NC}"
        fi

        echo -e "  VNC 服务:   $vnc_status"
        echo -e "  noVNC 服务: $novnc_status"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${YELLOW}1)${NC} 重启所有服务"
        echo -e "  ${YELLOW}2)${NC} 停止所有服务"
        echo -e "  ${YELLOW}3)${NC} 启动所有服务"
        echo -e "  ${YELLOW}4)${NC} 修改 VNC 密码"
        echo -e "  ${YELLOW}5)${NC} 修改端口"
        echo -e "  ${YELLOW}6)${NC} 查看日志"
        echo -e "  ${YELLOW}7)${NC} 系统检查与修复"
        echo -e "  ${YELLOW}8)${NC} 完全卸载"
        echo -e "  ${YELLOW}0)${NC} 退出"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
        read -p "请选择操作 [0-8]: " choice

        case $choice in
            1)
                restart_services
                read -p "按回车继续..."
                ;;
            2)
                print_info "停止服务..."
                sudo systemctl stop novnc vncserver@1
                print_success "服务已停止"
                read -p "按回车继续..."
                ;;
            3)
                start_services
                read -p "按回车继续..."
                ;;
            4)
                change_password
                read -p "按回车继续..."
                ;;
            5)
                change_port
                read -p "按回车继续..."
                ;;
            6)
                echo ""
                print_info "最近 20 条日志："
                journalctl -u novnc -u vncserver@1 --no-pager -n 20
                echo ""
                read -p "按回车继续..."
                ;;
            7)
                repair_installation
                read -p "按回车继续..."
                ;;
            8)
                uninstall
                exit 0
                ;;
            0)
                echo ""
                print_info "再见！"
                exit 0
                ;;
            *)
                print_warning "无效选项"
                sleep 1
                ;;
        esac
    done
}

change_password() {
    echo ""
    read -p "请输入新的 VNC 密码 (至少6位): " new_password
    if [ ${#new_password} -lt 6 ]; then
        print_error "密码至少需要 6 个字符！"
        return 1
    fi

    echo "$new_password" | vncpasswd -f > $HOME_DIR/.vnc/passwd
    chmod 600 $HOME_DIR/.vnc/passwd

    # 更新配置文件
    sed -i "s/^VNC_PASSWORD=.*/VNC_PASSWORD=$new_password/" $CONFIG_FILE

    restart_services
    print_success "密码已修改为: $new_password"
}

change_port() {
    source $CONFIG_FILE
    echo ""
    echo "当前端口: $NOVNC_PORT"
    read -p "请输入新端口 (1024-65535): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        print_error "无效端口号！"
        return 1
    fi

    if ! check_port_available "$new_port"; then
        print_error "端口 $new_port 已被占用！"
        return 1
    fi

    # 更新配置
    sed -i "s/^NOVNC_PORT=.*/NOVNC_PORT=$new_port/" $CONFIG_FILE

    # 更新服务
    setup_services $new_port
    configure_firewall $new_port
    restart_services

    print_success "端口已修改为: $new_port"
    print_warning "请记得在云控制台开放新端口 $new_port"
}

repair_installation() {
    echo ""
    print_info "检查安装状态..."

    local missing=$(get_missing_components)

    if [ -z "$missing" ]; then
        print_success "所有组件正常运行！"
        return 0
    fi

    print_warning "发现问题组件: $missing"
    echo ""
    read -p "是否修复？[Y/n]: " confirm

    if [[ "$confirm" =~ ^[Nn] ]]; then
        return 0
    fi

    # 读取配置
    source $CONFIG_FILE 2>/dev/null
    local port=${NOVNC_PORT:-$(generate_random_port)}
    local password=${VNC_PASSWORD:-$(generate_random_password)}

    # 按需修复
    for component in $missing; do
        case $component in
            xfce) install_xfce ;;
            tigervnc) install_tigervnc ;;
            novnc) install_novnc ;;
            java) install_java ;;
            android-studio) install_android_studio ;;
            chrome) install_chrome ;;
            vnc-config) configure_vnc "$password" ;;
            ssl) generate_ssl_cert ;;
            vnc-service|novnc-service)
                setup_services $port
                start_services
                ;;
        esac
    done

    print_success "修复完成！"
}

uninstall() {
    echo ""
    print_warning "这将完全卸载 Android Studio 远程桌面环境！"
    read -p "确定要卸载吗？输入 'YES' 确认: " confirm

    if [ "$confirm" != "YES" ]; then
        print_info "取消卸载"
        return 0
    fi

    print_info "正在卸载..."

    sudo systemctl stop novnc vncserver@1 2>/dev/null || true
    sudo systemctl disable novnc vncserver@1 2>/dev/null || true
    sudo rm -f /etc/systemd/system/vncserver@.service
    sudo rm -f /etc/systemd/system/novnc.service
    sudo systemctl daemon-reload

    sudo rm -rf /opt/android-studio
    sudo rm -f /usr/local/bin/android-studio

    rm -rf $HOME_DIR/.vnc
    rm -f $HOME_DIR/.android-studio-remote.conf
    rm -f $HOME_DIR/.android-studio-remote.status
    rm -f $HOME_DIR/Desktop/android-studio.desktop
    rm -f $HOME_DIR/Desktop/google-chrome.desktop

    print_success "卸载完成！"
}

#============================================================================
# 全新安装流程
#============================================================================
full_install() {
    clear
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}   Android Studio 远程桌面安装脚本${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""

    # 获取端口
    local default_port=$(generate_random_port)
    echo -e "${YELLOW}请输入 noVNC 端口 [直接回车使用随机端口: $default_port]:${NC}"
    read -p "> " input_port

    local novnc_port
    if [ -z "$input_port" ]; then
        novnc_port=$default_port
        print_info "使用随机端口: $novnc_port"
    else
        if ! [[ "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -lt 1024 ] || [ "$input_port" -gt 65535 ]; then
            print_error "端口必须在 1024-65535 之间！"
            exit 1
        fi
        if ! check_port_available "$input_port"; then
            print_error "端口 $input_port 已被占用！"
            exit 1
        fi
        novnc_port=$input_port
    fi

    echo ""

    # 获取密码
    local default_password=$(generate_random_password)
    echo -e "${YELLOW}请输入 VNC 密码 [直接回车使用随机密码: $default_password]:${NC}"
    read -p "> " input_password

    local vnc_password
    if [ -z "$input_password" ]; then
        vnc_password=$default_password
        print_info "使用随机密码: $vnc_password"
    else
        if [ ${#input_password} -lt 6 ]; then
            print_error "密码至少需要 6 个字符！"
            exit 1
        fi
        vnc_password=$input_password
    fi

    echo ""
    echo -e "${CYAN}--------------------------------------------${NC}"
    echo -e "  端口: ${GREEN}$novnc_port${NC}"
    echo -e "  密码: ${GREEN}$vnc_password${NC}"
    echo -e "${CYAN}--------------------------------------------${NC}"
    echo ""
    echo -e "${YELLOW}按回车开始安装，Ctrl+C 取消...${NC}"
    read

    # 保存配置（安装前保存，便于断点续装）
    save_config $novnc_port $vnc_password $CURRENT_USER

    # 开始安装
    echo ""
    print_info "步骤 1/8: 安装基础依赖..."
    install_base_deps

    print_info "步骤 2/8: 安装 XFCE 桌面..."
    install_xfce

    print_info "步骤 3/8: 安装 TigerVNC..."
    install_tigervnc
    configure_vnc "$vnc_password"

    print_info "步骤 4/8: 安装 noVNC..."
    install_novnc
    generate_ssl_cert

    print_info "步骤 5/8: 安装 Java JDK..."
    install_java

    print_info "步骤 6/8: 安装 Android Studio..."
    install_android_studio

    print_info "步骤 7/8: 安装 Google Chrome..."
    install_chrome

    print_info "步骤 8/8: 配置系统服务..."
    setup_services $novnc_port
    start_services
    configure_firewall $novnc_port

    # 完成
    local public_ip=$(get_public_ip)

    echo ""
    echo "============================================================"
    echo -e "${GREEN}✅ 安装完成！${NC}"
    echo "============================================================"
    echo ""
    echo -e "${RED}⚠️  重要：请在云服务商控制台开放端口 $novnc_port ${NC}"
    echo "------------------------------------------------------------"
    echo -e "  阿里云:  安全组 → 入方向 → 添加 TCP 端口 $novnc_port"
    echo -e "  腾讯云:  安全组 → 入站规则 → 添加 TCP 端口 $novnc_port"
    echo -e "  华为云:  安全组 → 入方向规则 → 添加 TCP 端口 $novnc_port"
    echo -e "  AWS:     Security Groups → Inbound → TCP $novnc_port"
    echo "------------------------------------------------------------"
    echo ""
    echo -e "${CYAN}📌 访问信息（云端口开放后即可访问）：${NC}"
    echo "------------------------------------------------------------"
    echo -e "  访问地址:  ${GREEN}https://$public_ip:$novnc_port/vnc.html${NC}"
    echo -e "  VNC 密码:  ${GREEN}$vnc_password${NC}"
    echo "------------------------------------------------------------"
    echo ""
    echo -e "${YELLOW}💡 首次访问时，浏览器会提示证书不安全，点击「高级」→「继续访问」即可${NC}"
    echo -e "${YELLOW}💡 再次运行此脚本可进入管理面板${NC}"
    echo ""
}

#============================================================================
# 主入口
#============================================================================
main() {
    # root 用户警告（但不阻止，允许管理）
    if [ "$EUID" -eq 0 ]; then
        print_warning "检测到 root 用户"
        print_info "建议使用普通用户进行安装，root 用户可用于管理"
    fi

    # 尝试查找已有配置
    find_and_load_config

    # 检测安装状态
    if has_any_installation && is_fully_installed; then
        # 已完整安装，进入管理界面
        show_management_menu
    elif has_any_installation; then
        # 有安装但未完整，提供选项
        clear
        echo ""
        echo -e "${YELLOW}检测到未完成的安装${NC}"
        echo ""

        local missing=$(get_missing_components)
        print_warning "缺失组件: $missing"
        echo ""
        echo -e "  ${YELLOW}1)${NC} 继续安装/修复"
        echo -e "  ${YELLOW}2)${NC} 重新安装"
        echo -e "  ${YELLOW}3)${NC} 进入管理界面"
        echo -e "  ${YELLOW}0)${NC} 退出"
        echo ""
        read -p "请选择 [0-3]: " choice

        case $choice in
            1)
                repair_installation
                if is_fully_installed; then
                    show_management_menu
                fi
                ;;
            2)
                sudo rm -f $SYSTEM_CONFIG_FILE
                rm -f $USER_CONFIG_FILE
                full_install
                ;;
            3)
                show_management_menu
                ;;
            0)
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
    else
        # 全新安装
        if [ "$EUID" -eq 0 ]; then
            print_error "首次安装请使用普通用户！"
            print_info "请切换到普通用户后重新运行"
            exit 1
        fi
        full_install
    fi
}

main "$@"
