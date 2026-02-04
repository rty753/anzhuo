# Android Studio Remote Desktop

一键在云服务器上部署 Android Studio 远程开发环境，通过浏览器即可访问完整的 Android 开发 IDE。

## 功能特性

- **一键安装** - 自动完成所有配置，本地防火墙自动开放
- **浏览器访问** - 无需安装 VNC 客户端，支持任何现代浏览器
- **HTTPS 加密** - 自动生成 SSL 证书，安全传输
- **灵活配置** - 支持自定义端口和密码，或使用随机生成
- **开机自启** - systemd 服务管理，重启后自动恢复

## 系统要求

- Ubuntu 20.04 / 22.04 / 24.04
- 至少 4GB RAM（推荐 8GB+）
- 至少 20GB 磁盘空间
- 开放所选端口的防火墙规则

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rty753/anzhuo/main/install-android-studio-remote.sh)
```

或者先下载再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/rty753/anzhuo/main/install-android-studio-remote.sh -o install.sh
chmod +x install.sh
./install.sh
```

## 安装过程

脚本会提示输入：

1. **noVNC 端口** - 直接回车使用随机端口（10000-60000）
2. **VNC 密码** - 直接回车使用随机密码（16位）

安装内容：
- XFCE4 桌面环境
- TigerVNC Server
- noVNC (WebSocket 代理)
- OpenJDK 17
- Android Studio 2025.2.3.9

## 安装后唯一需要做的事

> **在云服务商控制台开放端口**（脚本会提示你具体端口号）

| 云厂商 | 操作路径 |
|--------|----------|
| 阿里云 | 安全组 → 入方向 → 添加 TCP 端口 |
| 腾讯云 | 安全组 → 入站规则 → 添加 TCP 端口 |
| 华为云 | 安全组 → 入方向规则 → 添加 TCP 端口 |
| AWS | Security Groups → Inbound → TCP |

## 使用方法

云端口开放后，浏览器直接访问：

```
https://YOUR_SERVER_IP:PORT/vnc.html
```

> 首次访问时浏览器会提示证书不安全（自签名证书），点击「高级」→「继续访问」即可。

## 常用命令

```bash
# 查看保存的配置（端口、密码）
cat ~/.android-studio-remote.conf

# 重启 VNC 服务
sudo systemctl restart vncserver@1

# 重启 noVNC 服务
sudo systemctl restart novnc

# 查看服务状态
sudo systemctl status novnc

# 查看实时日志
journalctl -u novnc -f
```

## 架构说明

```
浏览器 (HTTPS)
    │
    ▼
noVNC (WebSocket 代理) ─── SSL 加密 ───► 端口 (自定义)
    │
    ▼
TigerVNC Server ─────────────────────► localhost:5901
    │
    ▼
XFCE4 桌面环境
    │
    ▼
Android Studio
```

## 文件位置

| 文件 | 路径 |
|------|------|
| Android Studio | `/opt/android-studio/` |
| VNC 配置 | `~/.vnc/` |
| SSL 证书 | `~/.vnc/ssl/` |
| 配置文件 | `~/.android-studio-remote.conf` |
| 桌面快捷方式 | `~/Desktop/android-studio.desktop` |

## 卸载

```bash
# 停止服务
sudo systemctl stop novnc vncserver@1
sudo systemctl disable novnc vncserver@1

# 删除服务文件
sudo rm /etc/systemd/system/vncserver@.service
sudo rm /etc/systemd/system/novnc.service
sudo systemctl daemon-reload

# 删除 Android Studio
sudo rm -rf /opt/android-studio
sudo rm /usr/local/bin/android-studio

# 删除配置
rm -rf ~/.vnc
rm ~/.android-studio-remote.conf
rm ~/Desktop/android-studio.desktop
```

## License

MIT License
