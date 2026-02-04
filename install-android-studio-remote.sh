#!/bin/bash

#============================================================================
# Android Studio 远程桌面一键安装脚本
# 支持 HTTPS + 自定义/随机端口 + 自定义/随机密码
# 适用于 Ubuntu 20.04/22.04/24.04
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
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#============================================================================
# 生成随机端口和密码
#============================================================================
generate_random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        # 检查端口是否被占用
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
        return 1  # 端口被占用
    else
        return 0  # 端口可用
    fi
}

#============================================================================
# 用户输入配置
#============================================================================
clear
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   Android Studio 远程桌面安装脚本${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# 获取端口
DEFAULT_PORT=$(generate_random_port)
echo -e "${YELLOW}请输入 noVNC 端口 [直接回车使用随机端口: $DEFAULT_PORT]:${NC}"
read -p "> " INPUT_PORT

if [ -z "$INPUT_PORT" ]; then
    NOVNC_PORT=$DEFAULT_PORT
    print_info "使用随机端口: $NOVNC_PORT"
else
    # 验证输入是否为数字
    if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]]; then
        print_error "端口必须是数字！"
        exit 1
    fi
    # 验证端口范围
    if [ "$INPUT_PORT" -lt 1024 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        print_error "端口必须在 1024-65535 之间！"
        exit 1
    fi
    # 检查端口是否被占用
    if ! check_port_available "$INPUT_PORT"; then
        print_error "端口 $INPUT_PORT 已被占用！"
        exit 1
    fi
    NOVNC_PORT=$INPUT_PORT
    print_info "使用指定端口: $NOVNC_PORT"
fi

echo ""

# 获取密码
DEFAULT_PASSWORD=$(generate_random_password)
echo -e "${YELLOW}请输入 VNC 密码 [直接回车使用随机密码: $DEFAULT_PASSWORD]:${NC}"
read -p "> " INPUT_PASSWORD

if [ -z "$INPUT_PASSWORD" ]; then
    VNC_PASSWORD=$DEFAULT_PASSWORD
    print_info "使用随机密码: $VNC_PASSWORD"
else
    # 密码长度检查
    if [ ${#INPUT_PASSWORD} -lt 6 ]; then
        print_error "密码至少需要 6 个字符！"
        exit 1
    fi
    VNC_PASSWORD=$INPUT_PASSWORD
    print_info "使用指定密码: $VNC_PASSWORD"
fi

echo ""

# 配置确认
VNC_PORT=5901
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo ~$CURRENT_USER)
CONFIG_FILE="$HOME_DIR/.android-studio-remote.conf"

echo -e "${CYAN}--------------------------------------------${NC}"
echo -e "  端口: ${GREEN}$NOVNC_PORT${NC}"
echo -e "  密码: ${GREEN}$VNC_PASSWORD${NC}"
echo -e "${CYAN}--------------------------------------------${NC}"
echo ""
echo -e "${YELLOW}按回车开始安装，Ctrl+C 取消...${NC}"
read

#============================================================================
# 1. 系统更新和基础依赖
#============================================================================
print_info "步骤 1/8: 更新系统并安装基础依赖..."

sudo apt-get update
sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    wget \
    curl \
    git \
    unzip \
    net-tools \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common

print_success "基础依赖安装完成"

#============================================================================
# 2. 安装 XFCE 桌面环境
#============================================================================
print_info "步骤 2/8: 安装 XFCE 桌面环境..."

sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    xfce4 xfce4-goodies dbus-x11

print_success "XFCE 桌面环境安装完成"

#============================================================================
# 3. 安装 TigerVNC Server
#============================================================================
print_info "步骤 3/8: 安装 TigerVNC Server..."

sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    tigervnc-standalone-server tigervnc-common

# 创建 VNC 密码
mkdir -p $HOME_DIR/.vnc
echo "$VNC_PASSWORD" | vncpasswd -f > $HOME_DIR/.vnc/passwd
chmod 600 $HOME_DIR/.vnc/passwd

# 创建 VNC 启动脚本
cat > $HOME_DIR/.vnc/xstartup << 'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
exec startxfce4
EOF

chmod +x $HOME_DIR/.vnc/xstartup

print_success "TigerVNC 安装完成"

#============================================================================
# 4. 安装 noVNC（支持浏览器访问）
#============================================================================
print_info "步骤 4/8: 安装 noVNC..."

sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    novnc python3-websockify python3-numpy

# 生成自签名 SSL 证书
SSL_DIR="$HOME_DIR/.vnc/ssl"
mkdir -p $SSL_DIR

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout $SSL_DIR/novnc.key \
    -out $SSL_DIR/novnc.crt \
    -days 365 \
    -subj "/C=CN/ST=State/L=City/O=Organization/CN=localhost"

# 合并证书和私钥（websockify 需要）
cat $SSL_DIR/novnc.key $SSL_DIR/novnc.crt > $SSL_DIR/novnc.pem
chmod 600 $SSL_DIR/novnc.pem

print_success "noVNC 安装完成，SSL 证书已生成"

#============================================================================
# 5. 安装 Java JDK（Android Studio 依赖）
#============================================================================
print_info "步骤 5/8: 安装 Java JDK..."

sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    openjdk-17-jdk

print_success "Java JDK 安装完成"

#============================================================================
# 6. 下载并安装 Android Studio
#============================================================================
print_info "步骤 6/8: 下载并安装 Android Studio..."

ANDROID_STUDIO_URL="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2025.2.3.9/android-studio-2025.2.3.9-linux.tar.gz"
ANDROID_STUDIO_DIR="/opt/android-studio"
DOWNLOAD_DIR="/tmp"

# 下载 Android Studio
print_info "正在下载 Android Studio（约 1.5GB，请耐心等待）..."
wget -q --show-progress -O $DOWNLOAD_DIR/android-studio.tar.gz "$ANDROID_STUDIO_URL"

# 解压安装
print_info "正在解压安装..."
sudo rm -rf $ANDROID_STUDIO_DIR
sudo tar -xzf $DOWNLOAD_DIR/android-studio.tar.gz -C /opt/
rm -f $DOWNLOAD_DIR/android-studio.tar.gz

# 创建桌面快捷方式
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

# 创建命令行启动链接
sudo ln -sf /opt/android-studio/bin/studio.sh /usr/local/bin/android-studio

print_success "Android Studio 安装完成"

#============================================================================
# 7. 安装 Google Chrome 浏览器
#============================================================================
print_info "步骤 7/8: 安装 Google Chrome 浏览器..."

# 下载并安装 Google Chrome
wget -q -O /tmp/google-chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    /tmp/google-chrome.deb || sudo apt-get install -f -y
rm -f /tmp/google-chrome.deb

# 设置 Chrome 为默认浏览器
sudo update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
sudo update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null || true

# 创建桌面快捷方式
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

# 配置 XFCE 默认浏览器
mkdir -p $HOME_DIR/.config/xfce4
cat > $HOME_DIR/.config/xfce4/helpers.rc << EOF
WebBrowser=google-chrome
EOF

print_success "Google Chrome 安装完成并设置为默认浏览器"

#============================================================================
# 8. 创建系统服务
#============================================================================
print_info "步骤 8/8: 创建系统服务..."

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

# noVNC 服务（HTTPS）
sudo tee /etc/systemd/system/novnc.service > /dev/null << EOF
[Unit]
Description=noVNC WebSocket Proxy
After=vncserver@1.service
Requires=vncserver@1.service

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/websockify --web=/usr/share/novnc --cert=$SSL_DIR/novnc.pem $NOVNC_PORT localhost:$VNC_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 重载并启动服务
sudo systemctl daemon-reload
sudo systemctl enable vncserver@1.service
sudo systemctl enable novnc.service
sudo systemctl start vncserver@1.service
sleep 3
sudo systemctl start novnc.service

print_success "系统服务创建并启动完成"

#============================================================================
# 配置本地防火墙（仅开放本脚本使用的端口）
#============================================================================
print_info "配置本地防火墙（仅开放端口 $NOVNC_PORT）..."

# UFW 防火墙（Ubuntu 默认）
if command -v ufw &> /dev/null; then
    sudo ufw allow $NOVNC_PORT/tcp comment "noVNC for Android Studio" 2>/dev/null || true
    print_success "UFW 已开放端口 $NOVNC_PORT"
fi

# Firewalld 防火墙（CentOS/RHEL）
if command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --add-port=$NOVNC_PORT/tcp --permanent 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
    print_success "Firewalld 已开放端口 $NOVNC_PORT"
fi

# iptables 直接添加规则（备用方案）
if command -v iptables &> /dev/null && ! command -v ufw &> /dev/null && ! command -v firewall-cmd &> /dev/null; then
    sudo iptables -I INPUT -p tcp --dport $NOVNC_PORT -j ACCEPT 2>/dev/null || true
    print_success "iptables 已开放端口 $NOVNC_PORT"
fi

#============================================================================
# 保存配置信息
#============================================================================
cat > $CONFIG_FILE << EOF
# Android Studio 远程桌面配置
# 生成时间: $(date)

NOVNC_PORT=$NOVNC_PORT
VNC_PASSWORD=$VNC_PASSWORD
VNC_PORT=$VNC_PORT
EOF

chmod 600 $CONFIG_FILE

#============================================================================
# 获取服务器 IP
#============================================================================
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_SERVER_IP")

#============================================================================
# 完成提示
#============================================================================
echo ""
echo "============================================================"
echo -e "${GREEN}✅ 安装完成！${NC}"
echo "============================================================"
echo ""
echo -e "${RED}⚠️  重要：请在云服务商控制台开放端口 $NOVNC_PORT ${NC}"
echo "------------------------------------------------------------"
echo -e "  阿里云:  安全组 → 入方向 → 添加 TCP 端口 $NOVNC_PORT"
echo -e "  腾讯云:  安全组 → 入站规则 → 添加 TCP 端口 $NOVNC_PORT"
echo -e "  华为云:  安全组 → 入方向规则 → 添加 TCP 端口 $NOVNC_PORT"
echo -e "  AWS:     Security Groups → Inbound → TCP $NOVNC_PORT"
echo "------------------------------------------------------------"
echo ""
echo -e "${CYAN}📌 访问信息（云端口开放后即可访问）：${NC}"
echo "------------------------------------------------------------"
echo -e "  访问地址:  ${GREEN}https://$PUBLIC_IP:$NOVNC_PORT/vnc.html${NC}"
echo -e "  VNC 密码:  ${GREEN}$VNC_PASSWORD${NC}"
echo "------------------------------------------------------------"
echo ""
echo -e "${CYAN}📋 常用命令：${NC}"
echo "------------------------------------------------------------"
echo "  查看配置:    cat $CONFIG_FILE"
echo "  重启 VNC:    sudo systemctl restart vncserver@1"
echo "  重启 noVNC:  sudo systemctl restart novnc"
echo "  查看状态:    sudo systemctl status novnc"
echo "  查看日志:    journalctl -u novnc -f"
echo "------------------------------------------------------------"
echo ""
echo -e "${YELLOW}💡 首次访问时，浏览器会提示证书不安全，点击「高级」→「继续访问」即可${NC}"
echo ""
