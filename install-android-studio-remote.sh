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

    # Android Studio 不再作为必需组件检测（改为可选）

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
    # Android Studio 不再作为必需组件
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

#============================================================================
# 扩展应用安装
#============================================================================
install_chinese_input() {
    print_info "安装中文输入法 (Fcitx5 + 中文拼音)..."

    # 安装 fcitx5 和中文输入法
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 \
        fcitx5-frontend-qt5 fcitx5-config-qt im-config fonts-noto-cjk fonts-noto-cjk-extra

    # 获取安装用户的 home 目录
    local user_home
    if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != "root" ]; then
        user_home=$(eval echo ~$INSTALL_USER)
    else
        user_home=$HOME_DIR
    fi

    # 配置输入法环境变量
    cat >> $user_home/.profile << 'EOF'

# Fcitx5 中文输入法配置
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export INPUT_METHOD=fcitx
export SDL_IM_MODULE=fcitx
EOF

    # 创建 fcitx5 自动启动
    mkdir -p $user_home/.config/autostart
    cat > $user_home/.config/autostart/fcitx5.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx5
Exec=fcitx5
Hidden=false
EOF

    # 配置 fcitx5 默认使用拼音
    mkdir -p $user_home/.config/fcitx5/profile
    cat > $user_home/.config/fcitx5/profile << 'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF

    # 修改 VNC 启动脚本，添加输入法启动
    if [ -f $user_home/.vnc/xstartup ]; then
        # 检查是否已添加
        if ! grep -q "fcitx5" $user_home/.vnc/xstartup; then
            sed -i '/exec startxfce4/i \
# 启动中文输入法\
export GTK_IM_MODULE=fcitx\
export QT_IM_MODULE=fcitx\
export XMODIFIERS=@im=fcitx\
fcitx5 -d &\
sleep 1' $user_home/.vnc/xstartup
        fi
    fi

    print_success "中文输入法安装完成"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -e "  使用方法:"
    echo -e "  ${GREEN}Ctrl + Space${NC}  切换中英文输入法"
    echo -e "  ${GREEN}Shift${NC}         临时切换英文"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo ""
    print_warning "需要重启 VNC 服务才能生效"
    read -p "是否现在重启 VNC？[Y/n]: " restart_vnc
    if [[ ! "$restart_vnc" =~ ^[Nn] ]]; then
        restart_services
    fi
}

setup_clipboard() {
    print_info "配置剪贴板共享..."

    # 安装剪贴板工具
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        xclip xsel autocutsel

    # 获取安装用户的 home 目录
    local user_home
    if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != "root" ]; then
        user_home=$(eval echo ~$INSTALL_USER)
    else
        user_home=$HOME_DIR
    fi

    # 修改 VNC 启动脚本，添加剪贴板同步
    if [ -f $user_home/.vnc/xstartup ]; then
        # 检查是否已添加
        if ! grep -q "autocutsel" $user_home/.vnc/xstartup; then
            sed -i '/exec startxfce4/i \
# 剪贴板同步\
autocutsel -fork &\
autocutsel -selection PRIMARY -fork &' $user_home/.vnc/xstartup
        fi
    fi

    print_success "剪贴板配置完成"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  noVNC 剪贴板使用说明：${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${GREEN}方法 1: noVNC 剪贴板面板${NC}"
    echo -e "  点击左侧工具栏的「剪贴板」图标"
    echo -e "  粘贴内容到文本框，远程桌面即可使用 Ctrl+V 粘贴"
    echo ""
    echo -e "  ${GREEN}方法 2: 浏览器快捷键（需授权）${NC}"
    echo -e "  首次使用时，浏览器会请求剪贴板权限，请点击「允许」"
    echo -e "  然后可直接使用 Ctrl+C / Ctrl+V"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}  注意：部分浏览器可能限制剪贴板访问${NC}"
    echo -e "  推荐使用 Chrome/Edge，并确保使用 HTTPS 连接"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo ""

    print_warning "需要重启 VNC 服务才能生效"
    read -p "是否现在重启 VNC？[Y/n]: " restart_vnc
    if [[ ! "$restart_vnc" =~ ^[Nn] ]]; then
        restart_services
    fi
}

install_firefox() {
    print_info "安装 Firefox 浏览器..."
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" firefox

    # 获取安装用户的 home 目录
    local user_home
    if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != "root" ]; then
        user_home=$(eval echo ~$INSTALL_USER)
    else
        user_home=$HOME_DIR
    fi

    # 创建桌面快捷方式
    mkdir -p $user_home/Desktop
    cat > $user_home/Desktop/firefox.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
Icon=firefox
Exec=/usr/bin/firefox %U
Categories=Network;WebBrowser;
Terminal=false
StartupNotify=true
EOF
    chmod +x $user_home/Desktop/firefox.desktop
    print_success "Firefox 安装完成"
}

install_telegram() {
    print_info "安装 Telegram..."

    # 下载 Telegram
    local tg_url="https://telegram.org/dl/desktop/linux"
    wget -q --show-progress -O /tmp/telegram.tar.xz "$tg_url"

    # 解压安装
    sudo tar -xJf /tmp/telegram.tar.xz -C /opt/
    rm -f /tmp/telegram.tar.xz

    # 创建命令链接
    sudo ln -sf /opt/Telegram/Telegram /usr/local/bin/telegram

    # 获取安装用户的 home 目录
    local user_home
    if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != "root" ]; then
        user_home=$(eval echo ~$INSTALL_USER)
    else
        user_home=$HOME_DIR
    fi

    # 创建桌面快捷方式
    mkdir -p $user_home/Desktop
    cat > $user_home/Desktop/telegram.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Telegram
Icon=/opt/Telegram/Telegram
Exec=/opt/Telegram/Telegram
Categories=Network;InstantMessaging;
Terminal=false
StartupNotify=true
EOF
    chmod +x $user_home/Desktop/telegram.desktop
    print_success "Telegram 安装完成"
}

install_redroid() {
    print_info "安装 Redroid (Docker 云手机)..."

    # 检查并安装 Docker
    if ! command -v docker &> /dev/null; then
        print_info "正在安装 Docker..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker $CURRENT_USER
        sudo systemctl enable docker
        sudo systemctl start docker
        print_success "Docker 安装完成"
    else
        print_info "Docker 已安装"
    fi

    # 加载必要的内核模块
    print_info "配置内核模块..."
    sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
    sudo modprobe ashmem_linux 2>/dev/null || true

    # 检查是否支持 binder
    if [ ! -e /dev/binder ] && [ ! -e /dev/binderfs/binder ]; then
        print_warning "系统可能不支持 binder，尝试安装 binder 模块..."
        sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            linux-modules-extra-$(uname -r) 2>/dev/null || true
        sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
    fi

    # 创建 binderfs 挂载点（如果需要）
    if [ ! -e /dev/binder ]; then
        sudo mkdir -p /dev/binderfs
        sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
    fi

    # 拉取 Redroid 镜像
    print_info "拉取 Redroid 镜像（约 1GB）..."
    sudo docker pull redroid/redroid:11.0.0-latest

    # 生成随机 ADB 端口
    local adb_port=$(shuf -i 5555-5600 -n 1)

    # 运行 Redroid 容器
    print_info "启动 Redroid 容器..."
    sudo docker run -d --name redroid \
        --privileged \
        -v /dev/binderfs:/dev/binderfs \
        -p ${adb_port}:5555 \
        redroid/redroid:11.0.0-latest \
        androidboot.redroid_gpu_mode=guest \
        androidboot.redroid_width=720 \
        androidboot.redroid_height=1280 \
        androidboot.redroid_dpi=320 2>/dev/null || {
            # 如果 binderfs 不可用，尝试其他方式
            sudo docker run -d --name redroid \
                --privileged \
                -p ${adb_port}:5555 \
                redroid/redroid:11.0.0-latest \
                androidboot.redroid_gpu_mode=guest \
                androidboot.redroid_width=720 \
                androidboot.redroid_height=1280 \
                androidboot.redroid_dpi=320
        }

    # 安装 scrcpy 用于显示
    print_info "安装 scrcpy（屏幕投射工具）..."
    sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        scrcpy adb 2>/dev/null || {
            # 如果 apt 没有 scrcpy，用 snap 安装
            sudo snap install scrcpy 2>/dev/null || true
        }

    # 获取安装用户的 home 目录
    local user_home
    if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != "root" ]; then
        user_home=$(eval echo ~$INSTALL_USER)
    else
        user_home=$HOME_DIR
    fi

    # 创建连接脚本
    cat > $user_home/Desktop/redroid-connect.sh << EOF
#!/bin/bash
adb connect localhost:${adb_port}
sleep 2
scrcpy -s localhost:${adb_port}
EOF
    chmod +x $user_home/Desktop/redroid-connect.sh

    # 创建桌面快捷方式
    cat > $user_home/Desktop/redroid.desktop << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Redroid 云手机
Icon=phone
Exec=$user_home/Desktop/redroid-connect.sh
Categories=Development;
Terminal=true
StartupNotify=true
EOF
    chmod +x $user_home/Desktop/redroid.desktop

    # 开放防火墙端口
    configure_firewall $adb_port

    echo ""
    print_success "Redroid 安装完成！"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ADB 端口: ${GREEN}${adb_port}${NC}"
    echo -e "  连接命令: ${GREEN}adb connect localhost:${adb_port}${NC}"
    echo -e "  投屏命令: ${GREEN}scrcpy -s localhost:${adb_port}${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo ""
    print_warning "请在云控制台开放端口 ${adb_port} 以便远程 ADB 连接"
    echo ""
}

manage_redroid() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              Redroid 云手机管理                            ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        # 检查 Redroid 状态
        local redroid_status
        if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^redroid$"; then
            redroid_status="${GREEN}运行中${NC}"
        elif sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^redroid$"; then
            redroid_status="${YELLOW}已停止${NC}"
        else
            redroid_status="${RED}未安装${NC}"
        fi

        echo -e "  Redroid 状态: $redroid_status"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${YELLOW}1)${NC} 启动 Redroid"
        echo -e "  ${YELLOW}2)${NC} 停止 Redroid"
        echo -e "  ${YELLOW}3)${NC} 重启 Redroid"
        echo -e "  ${YELLOW}4)${NC} 查看日志"
        echo -e "  ${YELLOW}5)${NC} 删除并重装"
        echo -e "  ${YELLOW}0)${NC} 返回上级菜单"
        echo ""
        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1)
                sudo docker start redroid 2>/dev/null || print_error "启动失败，Redroid 可能未安装"
                print_success "Redroid 已启动"
                read -p "按回车继续..."
                ;;
            2)
                sudo docker stop redroid 2>/dev/null
                print_success "Redroid 已停止"
                read -p "按回车继续..."
                ;;
            3)
                sudo docker restart redroid 2>/dev/null
                print_success "Redroid 已重启"
                read -p "按回车继续..."
                ;;
            4)
                echo ""
                sudo docker logs --tail 50 redroid 2>/dev/null || print_error "无法获取日志"
                echo ""
                read -p "按回车继续..."
                ;;
            5)
                sudo docker rm -f redroid 2>/dev/null
                install_redroid
                read -p "按回车继续..."
                ;;
            0)
                return
                ;;
            *)
                print_warning "无效选项"
                sleep 1
                ;;
        esac
    done
}

#============================================================================
# 扩展应用菜单
#============================================================================
show_apps_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              扩展应用安装                                  ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        # 检查已安装状态
        local android_studio_status firefox_status chrome_status telegram_status redroid_status
        local chinese_input_status clipboard_status

        if [ -d /opt/android-studio ]; then
            android_studio_status="${GREEN}[已安装]${NC}"
        else
            android_studio_status="${YELLOW}[未安装]${NC}"
        fi

        if command -v firefox &> /dev/null; then
            firefox_status="${GREEN}[已安装]${NC}"
        else
            firefox_status="${YELLOW}[未安装]${NC}"
        fi

        if command -v google-chrome-stable &> /dev/null; then
            chrome_status="${GREEN}[已安装]${NC}"
        else
            chrome_status="${YELLOW}[未安装]${NC}"
        fi

        if [ -f /opt/Telegram/Telegram ]; then
            telegram_status="${GREEN}[已安装]${NC}"
        else
            telegram_status="${YELLOW}[未安装]${NC}"
        fi

        if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^redroid$"; then
            redroid_status="${GREEN}[已安装]${NC}"
        else
            redroid_status="${YELLOW}[未安装]${NC}"
        fi

        if command -v fcitx5 &> /dev/null; then
            chinese_input_status="${GREEN}[已安装]${NC}"
        else
            chinese_input_status="${YELLOW}[未安装]${NC}"
        fi

        if command -v autocutsel &> /dev/null; then
            clipboard_status="${GREEN}[已配置]${NC}"
        else
            clipboard_status="${YELLOW}[未配置]${NC}"
        fi

        echo -e "  ${CYAN}── 系统增强 ──${NC}"
        echo -e "  ${YELLOW}1)${NC} 安装中文输入法          $chinese_input_status"
        echo -e "  ${YELLOW}2)${NC} 配置剪贴板共享          $clipboard_status"
        echo ""
        echo -e "  ${CYAN}── 开发工具 ──${NC}"
        echo -e "  ${YELLOW}3)${NC} 安装 Android Studio      $android_studio_status"
        echo ""
        echo -e "  ${CYAN}── 浏览器 ──${NC}"
        echo -e "  ${YELLOW}4)${NC} 安装 Firefox 浏览器      $firefox_status"
        echo -e "  ${YELLOW}5)${NC} 安装 Google Chrome       $chrome_status"
        echo ""
        echo -e "  ${CYAN}── 通讯工具 ──${NC}"
        echo -e "  ${YELLOW}6)${NC} 安装 Telegram            $telegram_status"
        echo ""
        echo -e "  ${CYAN}── 云手机 ──${NC}"
        echo -e "  ${YELLOW}7)${NC} 安装 Redroid 云手机      $redroid_status"
        echo -e "  ${YELLOW}8)${NC} Redroid 管理"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}0)${NC} 返回主菜单"
        echo ""
        read -p "请选择操作 [0-8]: " choice

        case $choice in
            1)
                install_chinese_input
                read -p "按回车继续..."
                ;;
            2)
                setup_clipboard
                read -p "按回车继续..."
                ;;
            3)
                install_android_studio
                read -p "按回车继续..."
                ;;
            4)
                install_firefox
                read -p "按回车继续..."
                ;;
            5)
                install_chrome
                read -p "按回车继续..."
                ;;
            6)
                install_telegram
                read -p "按回车继续..."
                ;;
            7)
                install_redroid
                read -p "按回车继续..."
                ;;
            8)
                manage_redroid
                ;;
            0)
                return
                ;;
            *)
                print_warning "无效选项"
                sleep 1
                ;;
        esac
    done
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
        echo ""
        echo -e "  ${CYAN}9)${NC} ⭐ 扩展应用安装"
        echo ""
        echo -e "  ${YELLOW}8)${NC} 完全卸载"
        echo -e "  ${YELLOW}0)${NC} 退出"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
        read -p "请选择操作 [0-9]: " choice

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
            9)
                show_apps_menu
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
    print_info "步骤 1/7: 安装基础依赖..."
    install_base_deps

    print_info "步骤 2/7: 安装 XFCE 桌面..."
    install_xfce

    print_info "步骤 3/7: 安装 TigerVNC..."
    install_tigervnc
    configure_vnc "$vnc_password"

    print_info "步骤 4/7: 安装 noVNC..."
    install_novnc
    generate_ssl_cert

    print_info "步骤 5/7: 安装 Java JDK..."
    install_java

    print_info "步骤 6/7: 安装 Google Chrome..."
    install_chrome

    print_info "步骤 7/7: 配置系统服务..."
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
    echo -e "${YELLOW}💡 选择「扩展应用」可安装 Android Studio、Telegram、Redroid 等${NC}"
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
