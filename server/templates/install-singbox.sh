#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Incudal Sing-box NAT/VPS 一键安装脚本
# 特性:
#   1. 仅保留安全可靠的 TCP 协议 (VLESS Reality / Trojan Fallback / VMess / Shadowsocks 2022 / AnyTLS Reality)
#   2. 内置 BusyBox httpd 超轻量 Web 伪装回落 (抗 GFW 主动嗅探/异常断开特征探测)
#   3. 彻底禁用 HY2/TUIC 等易受 GFW 阻断及防火墙限制的 UDP/QUIC 协议
#   4. 内置丰富的优质 SNI 伪装域名池，默认随机选取，防止节点伪装单一
#   5. 适配 Alpine (OpenRC) 与 Debian/Ubuntu/CentOS (Systemd)
# ==============================================================================

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq busybox-extras || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq busybox || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq busybox || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
# 生成随机端口 (10000-60000)
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 优质 Reality 伪装域名池 (支持 TLS 1.3 / HTTP/2)
SNI_POOL=(
    "gateway.icloud.com"
    "itunes.apple.com"
    "download.apple.com"
    "swdist.apple.com"
    "xp.apple.com"
    "mask.icloud.com"
    "mask-api.icloud.com"
    "configuration.apple.com"
    "learn.microsoft.com"
    "azure.microsoft.com"
    "www.microsoft.com"
    "update.microsoft.com"
    "c.s-microsoft.com"
    "catalog.update.microsoft.com"
    "edge.microsoft.com"
    "assets.msn.com"
    "addons.mozilla.org"
    "telemetry.mozilla.org"
    "dl-cdn.alpinelinux.org"
    "deb.debian.org"
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "mirrors.kernel.org"
    "cdn.kernel.org"
    "crates.io"
    "pypi.org"
    "registry.npmjs.org"
    "rubygems.org"
    "www.docker.com"
    "hub.docker.com"
    "dl.google.com"
    "fonts.googleapis.com"
    "cloudflare.com"
    "blog.cloudflare.com"
    "aws.amazon.com"
    "www.amazon.com"
    "images-na.ssl-images-amazon.com"
    "www.speedtest.net"
    "www.nvidia.com"
    "www.oracle.com"
    "www.cisco.com"
    "www.intel.com"
    "www.amd.com"
    "zoom.us"
    "www.samsung.com"
    "www.tesla.com"
)

# 随机推荐一个伪装域名
RANDOM_DEFAULT_SNI="${SNI_POOL[$((RANDOM % ${#SNI_POOL[@]}))]}"

# -----------------------
# 配置 BusyBox 伪装 Web 站点 (用于抗 GFW 主动嗅探/回落)
setup_fake_web() {
    info "配置 BusyBox httpd 伪装 Web 服务 (回落后端 127.0.0.1:8080)..."
    local web_dir="/var/www/fake-site"
    mkdir -p "$web_dir"
    
    if [ ! -f "$web_dir/index.html" ]; then
        cat > "$web_dir/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Enterprise Edge Service Gateway</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #f8fafc; color: #1e293b; margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
        .card { background: #ffffff; border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -2px rgba(0,0,0,0.1); border: 1px solid #e2e8f0; padding: 40px; max-width: 520px; width: 90%; }
        .badge { display: inline-flex; align-items: center; background-color: #ecfdf5; color: #059669; font-size: 13px; font-weight: 600; padding: 4px 10px; border-radius: 9999px; margin-bottom: 16px; }
        .badge-dot { width: 8px; height: 8px; background-color: #10b981; border-radius: 50%; margin-right: 6px; }
        h1 { font-size: 22px; font-weight: 700; margin: 0 0 12px 0; color: #0f172a; }
        p { font-size: 14px; line-height: 1.6; color: #64748b; margin: 0 0 24px 0; }
        .grid { border-top: 1px solid #f1f5f9; padding-top: 20px; display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        .item-label { font-size: 12px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 4px; }
        .item-value { font-size: 14px; font-weight: 600; color: #334155; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge"><span class="badge-dot"></span>Service Active</div>
        <h1>Edge Application Gateway</h1>
        <p>This endpoint is managed by the network automation cluster. Secure ingress routing and health telemetry are operating normally.</p>
        <div class="grid">
            <div>
                <div class="item-label">Status</div>
                <div class="item-value">200 Operational</div>
            </div>
            <div>
                <div class="item-label">Protocol</div>
                <div class="item-value">HTTP/1.1 TLS</div>
            </div>
        </div>
    </div>
</body>
</html>
EOF
    fi

    # 创建启动脚本
    cat > /usr/local/bin/fake-web-server <<'EOF'
#!/bin/sh
WEB_DIR="/var/www/fake-site"
mkdir -p "$WEB_DIR"
if [ -x /usr/sbin/httpd ]; then
    exec /usr/sbin/httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
elif command -v busybox >/dev/null 2>&1; then
    exec busybox httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
elif command -v busybox-extras >/dev/null 2>&1; then
    exec busybox-extras httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
else
    exec httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
fi
EOF
    chmod +x /usr/local/bin/fake-web-server

    # 安装系统服务
    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/fake-web <<'OPENRC'
#!/sbin/openrc-run
name="fake-web"
description="BusyBox httpd Fallback Web Server"
command="/usr/local/bin/fake-web-server"
command_background="yes"
pidfile="/run/fake-web.pid"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /run
}
OPENRC
        chmod +x /etc/init.d/fake-web
        rc-update add fake-web default >/dev/null 2>&1 || true
        rc-service fake-web restart >/dev/null 2>&1 || rc-service fake-web start >/dev/null 2>&1 || true
    else
        cat > /etc/systemd/system/fake-web.service <<'SYSTEMD'
[Unit]
Description=BusyBox httpd Fallback Web Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/fake-web-server
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable fake-web >/dev/null 2>&1 || true
        systemctl restart fake-web >/dev/null 2>&1 || systemctl start fake-web >/dev/null 2>&1 || true
    fi
    info "BusyBox httpd 伪装 Web 服务已就绪 (127.0.0.1:8080)"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认节点名):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 (已取消HY2/QUIC，纯净TCP保障防火墙安全) ==="
    echo "1) VLESS Reality (推荐, 默认)"
    echo "2) VMess (TLS + WS)"
    echo "3) Shadowsocks (SS 2022 / AEAD)"
    echo "4) AnyTLS Reality"
    echo "5) Trojan (TLS + BusyBox Web回落, 强抗主动嗅探)"
    echo ""
    echo "请输入要部署的协议编号(回车默认 1, 多个用空格分隔如: 1 2):"
    read -r protocol_input
    protocol_input="${protocol_input:-1}"
    
    ENABLE_REALITY=false
    ENABLE_VMESS=false
    ENABLE_SS=false
    ENABLE_ANYTLS=false
    ENABLE_TROJAN=false
    
    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_REALITY=true ;;
            2) ENABLE_VMESS=true ;;
            3) ENABLE_SS=true ;;
            4) ENABLE_ANYTLS=true ;;
            5) ENABLE_TROJAN=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done
    
    if ! $ENABLE_REALITY && ! $ENABLE_VMESS && ! $ENABLE_SS && ! $ENABLE_ANYTLS && ! $ENABLE_TROJAN; then
        err "未选择任何协议,退出安装"
        exit 1
    fi
    
    # 保存协议选择到文件
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_VMESS=$ENABLE_VMESS
ENABLE_SS=$ENABLE_SS
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_TROJAN=$ENABLE_TROJAN
EOF
    
    info "已选择协议:"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_VMESS && echo "  - VMess (TLS + WS)"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    $ENABLE_TROJAN && echo "  - Trojan (TLS + BusyBox Web回落)"
    
    export ENABLE_REALITY
    export ENABLE_VMESS
    export ENABLE_SS
    export ENABLE_ANYTLS
    export ENABLE_TROJAN
}

# 创建配置目录并选择协议
mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi
    
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice
    
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *) 
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac
    
    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
# 询问连接 IP 和 SNI 配置
echo ""
echo "请输入节点连接 IP 或 DDNS 域名 (NAT 小鸡可填写映射公网IP/域名，留空默认探测出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    info "已从伪装域名库中随机推荐 SNI: \033[1;32m${RANDOM_DEFAULT_SNI}\033[0m"
    echo "请输入 Reality 的 SNI 伪装域名 (留空直接回车使用推荐: ${RANDOM_DEFAULT_SNI}):"
    read -r USER_SNI
    REALITY_SNI="${USER_SNI:-$RANDOM_DEFAULT_SNI}"
    REALITY_SNI="$(echo "$REALITY_SNI" | tr -d '[:space:]')"
else
    REALITY_SNI="$RANDOM_DEFAULT_SNI"
fi

# 如果选择了 VMess 协议，询问 VMess TLS SNI 伪装域名
VMESS_SNI=""
if $ENABLE_VMESS; then
    echo ""
    if [ -n "$CUSTOM_IP" ] && ! [[ "$CUSTOM_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        DEFAULT_VMESS_SNI="$CUSTOM_IP"
    else
        DEFAULT_VMESS_SNI="${REALITY_SNI:-$RANDOM_DEFAULT_SNI}"
    fi
    info "VMess TLS 推荐 SNI: \033[1;32m${DEFAULT_VMESS_SNI}\033[0m"
    echo "请输入 VMess TLS SNI 伪装域名 (留空直接回车使用推荐: ${DEFAULT_VMESS_SNI}):"
    read -r USER_VMESS_SNI
    VMESS_SNI="${USER_VMESS_SNI:-$DEFAULT_VMESS_SNI}"
    VMESS_SNI="$(echo "$VMESS_SNI" | tr -d '[:space:]')"
fi

# 如果选择了 Trojan 协议，询问 Trojan TLS SNI 伪装域名
TROJAN_SNI=""
if $ENABLE_TROJAN; then
    echo ""
    if [ -n "$CUSTOM_IP" ] && ! [[ "$CUSTOM_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        DEFAULT_TROJAN_SNI="$CUSTOM_IP"
    else
        DEFAULT_TROJAN_SNI="${REALITY_SNI:-$RANDOM_DEFAULT_SNI}"
    fi
    info "Trojan TLS 推荐 SNI: \033[1;32m${DEFAULT_TROJAN_SNI}\033[0m"
    echo "请输入 Trojan TLS SNI 伪装域名 (留空直接回车使用推荐: ${DEFAULT_TROJAN_SNI}):"
    read -r USER_TROJAN_SNI
    TROJAN_SNI="${USER_TROJAN_SNI:-$DEFAULT_TROJAN_SNI}"
    TROJAN_SNI="$(echo "$TROJAN_SNI" | tr -d '[:space:]')"
fi

# 将用户选择写入缓存
mkdir -p /etc/sing-box
echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
echo "VMESS_SNI=$VMESS_SNI" >> /etc/sing-box/.config_cache.tmp || true
echo "TROJAN_SNI=$TROJAN_SNI" >> /etc/sing-box/.config_cache.tmp || true
if [ -f /etc/sing-box/.config_cache ]; then
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 配置端口和凭据
get_config() {
    info "开始配置端口和凭据..."
    
    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口 (留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi

    if $ENABLE_VMESS; then
        info "=== 配置 VMess (TLS + WS) ==="
        if [ -n "${SINGBOX_PORT_VMESS:-}" ]; then
            PORT_VMESS="$SINGBOX_PORT_VMESS"
        else
            read -p "请输入 VMess 端口 (留空则随机 10000-60000): " USER_PORT_VMESS
            PORT_VMESS="${USER_PORT_VMESS:-$(rand_port)}"
        fi
        read -p "请输入 VMess WebSocket 路径 (留空默认 /vmess-ws): " USER_VMESS_PATH
        VMESS_PATH="${USER_VMESS_PATH:-/vmess-ws}"
        [[ ! "$VMESS_PATH" =~ ^/ ]] && VMESS_PATH="/$VMESS_PATH"

        VMESS_UUID=$(rand_uuid)
        info "VMess 端口: $PORT_VMESS"
        info "VMess WS 路径: $VMESS_PATH"
        info "VMess UUID 已自动生成"
    fi

    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口 (留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi
    
    if $ENABLE_ANYTLS; then
        info "=== 配置 AnyTLS Reality ==="
        if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
            PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
        else
            read -p "请输入 AnyTLS Reality 端口 (留空则随机 10000-60000): " USER_PORT_ANYTLS
            PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
        fi

        ANYTLS_USER=$(openssl rand -hex 4)
        ANYTLS_PSK=$(openssl rand -base64 16)

        info "AnyTLS Reality 端口: $PORT_ANYTLS"
        info "AnyTLS Reality 用户名: $ANYTLS_USER"
        info "AnyTLS Reality 密码已自动生成"
    fi

    if $ENABLE_TROJAN; then
        info "=== 配置 Trojan (TLS + BusyBox Web回落) ==="
        if [ -n "${SINGBOX_PORT_TROJAN:-}" ]; then
            PORT_TROJAN="$SINGBOX_PORT_TROJAN"
        else
            read -p "请输入 Trojan 端口 (留空则随机 10000-60000): " USER_PORT_TROJAN
            PORT_TROJAN="${USER_PORT_TROJAN:-$(rand_port)}"
        fi
        TROJAN_PASS=$(rand_pass)
        info "Trojan 端口: $PORT_TROJAN"
        info "Trojan 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            # 方法1: 使用官方 apt/rpm 仓库 (不走 GitHub API，避免共享 IP 触发限流)
            local repo_ok=false
            if [ "$OS" = "debian" ]; then
                info "尝试通过官方 apt 仓库安装 sing-box..."
                mkdir -p /etc/apt/keyrings
                if curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc 2>/dev/null; then
                    chmod a+r /etc/apt/keyrings/sagernet.asc
                    cat > /etc/apt/sources.list.d/sagernet.list <<'APTSRC'
deb [signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *
APTSRC
                    if apt-get update -y 2>/dev/null && apt-get install -y sing-box 2>/dev/null; then
                        repo_ok=true
                        info "通过官方 apt 仓库安装成功"
                    else
                        warn "apt 仓库安装失败，尝试备用方法..."
                        rm -f /etc/apt/sources.list.d/sagernet.list
                    fi
                else
                    warn "获取 GPG 密钥失败，尝试备用方法..."
                fi
            fi

            # 方法2: 官方一键脚本 (会调用 GitHub API)
            if ! $repo_ok; then
                info "尝试通过官方一键脚本安装 sing-box..."
                if bash <(curl -fsSL https://sing-box.app/install.sh) 2>/dev/null; then
                    repo_ok=true
                    info "通过官方一键脚本安装成功"
                else
                    warn "官方脚本安装失败 (可能是 GitHub API 限流)，尝试直接下载二进制..."
                fi
            fi

            # 方法3: 直接下载二进制文件 (完全绕过 GitHub API)
            if ! $repo_ok; then
                info "尝试直接下载 sing-box 二进制文件..."
                local ARCH
                case "$(uname -m)" in
                    x86_64|amd64) ARCH="amd64" ;;
                    aarch64|arm64) ARCH="arm64" ;;
                    armv7l) ARCH="armv7" ;;
                    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
                esac
                # 尝试通过 SourceForge 镜像获取最新版本或使用固定稳定版
                local SB_VERSION=""
                # 先尝试从 GitHub API 获取版本 (可能被限流)
                SB_VERSION=$(curl -sfL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
                    | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/' || true)
                # 如果 API 失败，从网页抓取版本号
                if [ -z "$SB_VERSION" ]; then
                    SB_VERSION=$(curl -sfL "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null \
                        -o /dev/null -w '%{redirect_url}' | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || true)
                fi
                # 如果仍然失败，从 sing-box.app 安装脚本页面获取
                if [ -z "$SB_VERSION" ]; then
                    SB_VERSION=$(curl -sfL "https://sing-box.app/install.sh" 2>/dev/null \
                        | grep -oP 'LATEST_VERSION="?\K[0-9]+\.[0-9]+\.[0-9]+' || true)
                fi
                # 最终回退到已知稳定版本
                if [ -z "$SB_VERSION" ]; then
                    SB_VERSION="1.11.1"
                    warn "无法自动获取最新版本，使用回退版本: $SB_VERSION"
                fi
                info "目标版本: sing-box v${SB_VERSION} (${ARCH})"
                local DL_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${ARCH}.tar.gz"
                local TMP_DIR
                TMP_DIR=$(mktemp -d)
                if curl -fSL --retry 3 --retry-delay 5 "$DL_URL" -o "${TMP_DIR}/sing-box.tar.gz"; then
                    tar -xzf "${TMP_DIR}/sing-box.tar.gz" -C "${TMP_DIR}"
                    local BIN_PATH
                    BIN_PATH=$(find "${TMP_DIR}" -name sing-box -type f | head -1)
                    if [ -n "$BIN_PATH" ] && [ -f "$BIN_PATH" ]; then
                        install -m 755 "$BIN_PATH" /usr/bin/sing-box
                        repo_ok=true
                        info "sing-box 二进制文件已安装到 /usr/bin/sing-box"
                    else
                        err "解压后未找到 sing-box 可执行文件"
                    fi
                else
                    err "下载 sing-box 二进制文件失败"
                fi
                rm -rf "${TMP_DIR}"
            fi

            if ! $repo_ok; then
                err "所有安装方法均失败，请检查网络连接"
                exit 1
            fi
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    
    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 TLS 证书 (用于 VMess / Trojan)
generate_tls_cert() {
    if ! $ENABLE_VMESS && ! $ENABLE_TROJAN; then
        return 0
    fi
    info "配置 TLS 证书..."
    mkdir -p /etc/sing-box
    local cert_file="/etc/sing-box/vmess.crt"
    local key_file="/etc/sing-box/vmess.key"
    local cert_sni="${TROJAN_SNI:-${VMESS_SNI:-$RANDOM_DEFAULT_SNI}}"
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout "$key_file" \
            -out "$cert_file" \
            -days 3650 \
            -subj "/CN=${cert_sni}" >/dev/null 2>&1 || {
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$key_file" \
                -out "$cert_file" \
                -days 3650 \
                -subj "/CN=${cert_sni}" >/dev/null 2>&1
        }
        info "已自动生成 TLS 自签名证书 (有效期 10 年, 域名: ${cert_sni})"
    else
        info "使用已有 TLS 证书: $cert_file"
    fi

    if $ENABLE_TROJAN; then
        setup_fake_web
    fi
}

generate_tls_cert

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$$.json"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_VMESS; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_VMESS'
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": PORT_VMESS_PLACEHOLDER,
      "users": [
        {
          "name": "default",
          "uuid": "UUID_VMESS_PLACEHOLDER",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "PATH_VMESS_PLACEHOLDER"
      },
      "tls": {
        "enabled": true,
        "server_name": "SNI_VMESS_PLACEHOLDER",
        "certificate_path": "/etc/sing-box/vmess.crt",
        "key_path": "/etc/sing-box/vmess.key"
      }
    }
INBOUND_VMESS
        sed -i "s|PORT_VMESS_PLACEHOLDER|$PORT_VMESS|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_VMESS_PLACEHOLDER|$VMESS_UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|PATH_VMESS_PLACEHOLDER|$VMESS_PATH|g" "$TEMP_INBOUNDS"
        sed -i "s|SNI_VMESS_PLACEHOLDER|$VMESS_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_SS; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_ANYTLS; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

        sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
        sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
        sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_TROJAN; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TROJAN'
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": PORT_TROJAN_PLACEHOLDER,
      "users": [
        {
          "name": "default",
          "password": "PASS_TROJAN_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "SNI_TROJAN_PLACEHOLDER",
        "certificate_path": "/etc/sing-box/vmess.crt",
        "key_path": "/etc/sing-box/vmess.key"
      },
      "fallback": {
        "server": "127.0.0.1",
        "server_port": 8080
      }
    }
INBOUND_TROJAN
        sed -i "s|PORT_TROJAN_PLACEHOLDER|$PORT_TROJAN|g" "$TEMP_INBOUNDS"
        sed -i "s|PASS_TROJAN_PLACEHOLDER|$TROJAN_PASS|g" "$TEMP_INBOUNDS"
        sed -i "s|SNI_TROJAN_PLACEHOLDER|$TROJAN_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD
    
    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    
    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败,但继续执行"

    # 保存配置缓存
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_VMESS=$ENABLE_VMESS
ENABLE_SS=$ENABLE_SS
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_TROJAN=$ENABLE_TROJAN
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF

    $ENABLE_VMESS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
VMESS_PORT=$PORT_VMESS
VMESS_UUID=$VMESS_UUID
VMESS_PATH=$VMESS_PATH
VMESS_SNI=$VMESS_SNI
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOF

    $ENABLE_TROJAN && cat >> /etc/sing-box/.config_cache <<CACHEEOF
PORT_TROJAN=$PORT_TROJAN
TROJAN_PASS=$TROJAN_PASS
TROJAN_SNI=$TROJAN_SNI
CACHEEOF

    # 写入 CUSTOM_IP
    echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

create_config
info "配置生成完成，准备设置服务..."

# -----------------------
# 设置系统服务
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接 IP 或域名: $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请在客户端手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接 (仅安全 TCP 协议)
generate_uris() {
    local host="$PUB_IP"
    
    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_VMESS; then
        local vmess_json="{\"v\":\"2\",\"ps\":\"vmess${suffix}\",\"add\":\"${host}\",\"port\":\"${PORT_VMESS}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${VMESS_SNI}\",\"path\":\"${VMESS_PATH}\",\"tls\":\"tls\",\"sni\":\"${VMESS_SNI}\"}"
        local vmess_b64
        vmess_b64=$(printf "%s" "$vmess_json" | base64 -w0 2>/dev/null || printf "%s" "$vmess_json" | base64 | tr -d '\n')
        echo "=== VMess (TLS + WS) ==="
        echo "vmess://${vmess_b64}"
        echo ""
    fi

    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_user_encoded=$(printf "%s" "$ANYTLS_USER" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== AnyTLS Reality ==="
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi

    if $ENABLE_TROJAN; then
        local trojan_pass_encoded
        trojan_pass_encoded=$(printf "%s" "$TROJAN_PASS" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Trojan (TLS + BusyBox Web回落) ==="
        echo "trojan://${trojan_pass_encoded}@${host}:${PORT_TROJAN}?security=tls&sni=${TROJAN_SNI}&allowInsecure=1#trojan${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_REALITY && echo "   VLESS Reality 端口: $PORT_REALITY | UUID: $UUID"
$ENABLE_VMESS && echo "   VMess (TLS+WS) 端口: $PORT_VMESS | UUID: $VMESS_UUID | WS 路径: $VMESS_PATH | SNI: $VMESS_SNI"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_ANYTLS && echo "   AnyTLS 端口: $PORT_ANYTLS | 用户: $ANYTLS_USER | 密码: $ANYTLS_PSK"
$ENABLE_TROJAN && echo "   Trojan 端口: $PORT_TROJAN | 密码: $TROJAN_PASS | SNI: $TROJAN_SNI | Web回落: 127.0.0.1:8080"
echo "   连接地址: $PUB_IP"
echo "   Reality 伪装 SNI: ${REALITY_SNI}"
echo ""
info "📂 文件位置:"
echo "   配置文件: $CONFIG_PATH"
echo "   系统服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="

# -----------------------
# 创建 sb 管理快捷命令
SB_PATH="/usr/local/bin/sb"
info "正在创建 sb 管理面板: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    if [ -f /etc/init.d/fake-web ] && [ "$OS" = "alpine" ]; then
        rc-service fake-web start >/dev/null 2>&1 || true
    elif [ -f /etc/systemd/system/fake-web.service ]; then
        systemctl start fake-web >/dev/null 2>&1 || true
    fi
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"
}
service_stop() {
    if [ -f /etc/init.d/fake-web ] && [ "$OS" = "alpine" ]; then
        rc-service fake-web stop >/dev/null 2>&1 || true
    elif [ -f /etc/systemd/system/fake-web.service ]; then
        systemctl stop fake-web >/dev/null 2>&1 || true
    fi
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"
}
service_restart() {
    if [ -f /etc/init.d/fake-web ] && [ "$OS" = "alpine" ]; then
        rc-service fake-web restart >/dev/null 2>&1 || rc-service fake-web start >/dev/null 2>&1 || true
    elif [ -f /etc/systemd/system/fake-web.service ]; then
        systemctl restart fake-web >/dev/null 2>&1 || systemctl start fake-web >/dev/null 2>&1 || true
    fi
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"
}
service_status() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager
    if [ -f /etc/init.d/fake-web ] && [ "$OS" = "alpine" ]; then
        echo "--- fake-web (BusyBox httpd) ---"
        rc-service fake-web status || true
    elif [ -f /etc/systemd/system/fake-web.service ]; then
        echo "--- fake-web (BusyBox httpd) ---"
        systemctl status fake-web --no-pager || true
    fi
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

# URL 编码
url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi
    
    # 优先加载 .protocols 文件
    PROTOCOL_FILE="/etc/sing-box/.protocols"
    if [ -f "$PROTOCOL_FILE" ]; then
        . "$PROTOCOL_FILE"
    fi
    
    # 加载缓存文件
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi
    
    REALITY_SNI="${REALITY_SNI:-gateway.icloud.com}"
    ENABLE_REALITY="${ENABLE_REALITY:-false}"
    ENABLE_VMESS="${ENABLE_VMESS:-false}"
    ENABLE_SS="${ENABLE_SS:-false}"
    ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
    ENABLE_TROJAN="${ENABLE_TROJAN:-false}"
    CUSTOM_IP="${CUSTOM_IP:-}"

    # 读取各协议配置
    if [ "${ENABLE_VMESS:-false}" = "true" ]; then
        VMESS_PORT=$(jq -r '.inbounds[] | select(.type=="vmess") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        VMESS_UUID=$(jq -r '.inbounds[] | select(.type=="vmess") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        VMESS_PATH=$(jq -r '.inbounds[] | select(.type=="vmess") | .transport.path // "/vmess-ws"' "$CONFIG_PATH" | head -n1)
        VMESS_SNI=$(jq -r '.inbounds[] | select(.type=="vmess") | .tls.server_name // empty' "$CONFIG_PATH" | head -n1)
        VMESS_PATH="${VMESS_PATH:-/vmess-ws}"
        VMESS_SNI="${VMESS_SNI:-$REALITY_SNI}"
    fi

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        SS_PSK=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .password // empty' "$CONFIG_PATH" | head -n1)
        SS_METHOD=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method // empty' "$CONFIG_PATH" | head -n1)
    fi

    # Reality 公共参数
    if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        REALITY_SID=$(jq -r '
            .inbounds[]
            | select(.tls.reality.enabled == true)
            | .tls.reality.short_id[0] // empty
        ' "$CONFIG_PATH" | head -n1)

        [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
    fi

    # VLESS Reality 专属参数
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
    fi

    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        ANYTLS_PORT=$(jq -r '.inbounds[] | select(.type=="anytls") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        ANYTLS_USER=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].name // empty' "$CONFIG_PATH" | head -n1)
        ANYTLS_PSK=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi

    if [ "${ENABLE_TROJAN:-false}" = "true" ]; then
        TROJAN_PORT=$(jq -r '.inbounds[] | select(.type=="trojan") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        TROJAN_PASS=$(jq -r '.inbounds[] | select(.type=="trojan") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
        TROJAN_SNI=$(jq -r '.inbounds[] | select(.type=="trojan") | .tls.server_name // empty' "$CONFIG_PATH" | head -n1)
        TROJAN_SNI="${TROJAN_SNI:-$REALITY_SNI}"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo "YOUR_SERVER_IP"
}

# 生成并保存 URI
generate_uris() {
    read_config || return 1

    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_VMESS:-false}" = "true" ]; then
        local vmess_json="{\"v\":\"2\",\"ps\":\"vmess${node_suffix}\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${VMESS_SNI}\",\"path\":\"${VMESS_PATH}\",\"tls\":\"tls\",\"sni\":\"${VMESS_SNI}\"}"
        local vmess_b64
        vmess_b64=$(printf "%s" "$vmess_json" | base64 -w0 2>/dev/null || printf "%s" "$vmess_json" | base64 | tr -d '\n')
        echo "=== VMess (TLS + WS) ===" >> "$URI_FILE"
        echo "vmess://${vmess_b64}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_user_encoded=$(url_encode "$ANYTLS_USER")
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$URI_FILE"
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_TROJAN:-false}" = "true" ]; then
        trojan_pass_encoded=$(url_encode "$TROJAN_PASS")
        echo "=== Trojan (TLS + BusyBox Web回落) ===" >> "$URI_FILE"
        echo "trojan://${trojan_pass_encoded}@${PUBLIC_IP}:${TROJAN_PORT}?security=tls&sni=${TROJAN_SNI}&allowInsecure=1#trojan${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    info "URI 已保存到: $URI_FILE"
}

# 查看 URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi
    
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"
    
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

# 重置 Vless Reality 端口
action_reset_reality() {
    read_config || return 1
    
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi
    
    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置 VMess 端口
action_reset_vmess() {
    read_config || return 1
    
    if [ "${ENABLE_VMESS:-false}" != "true" ]; then
        err "VMess 协议未启用"
        return 1
    fi
    
    read -p "输入新的 VMess 端口(回车保持 $VMESS_PORT): " new_port
    new_port="${new_port:-$VMESS_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vmess" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 VMess 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置 SS 端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置 AnyTLS Reality 端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS Reality 端口(回车保持 $ANYTLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="anytls" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置 Trojan 端口与密码
action_reset_trojan() {
    read_config || return 1
    
    if [ "${ENABLE_TROJAN:-false}" != "true" ]; then
        err "Trojan 协议未启用"
        return 1
    fi
    
    read -p "输入新的 Trojan 端口(回车保持 $TROJAN_PORT): " new_port
    new_port="${new_port:-$TROJAN_PORT}"

    read -p "输入新的 Trojan 密码(回车保持原有密码): " new_pass
    new_pass="${new_pass:-$TROJAN_PASS}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" --arg pass "$new_pass" '
    .inbounds |= map(if .type=="trojan" then .listen_port = $port | .users[0].password = $pass else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Trojan 配置"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新 sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-service fake-web stop 2>/dev/null || true
        rc-update del fake-web default 2>/dev/null || true
        rm -f /etc/init.d/fake-web
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop fake-web 2>/dev/null || true
        systemctl disable fake-web 2>/dev/null || true
        rm -f /etc/systemd/system/fake-web.service
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt /var/www/fake-site /usr/local/bin/fake-web-server 2>/dev/null || true
    info "卸载完成"
}

# 生成中转线路机脚本
action_generate_relay() {
    read_config || return 1
    
    # 检查是否启用了 SS
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 协议,中转线路机脚本需要先部署 SS 作为落地入站"
        read -p "是否现在部署 SS 协议?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 协议..."
            
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_SS_PORT
            SS_PORT="${USER_SS_PORT:-$(rand_port)}"
            SS_PSK=$(rand_pass)
            SS_METHOD="aes-128-gcm"
            
            info "SS 端口: $SS_PORT | 密码已自动生成"
            
            info "正在停止服务..."
            service_stop || warn "停止服务失败"
            
            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            
            # 添加 SS inbound
            jq --argjson port "$SS_PORT" --arg psk "$SS_PSK" '
            .inbounds += [{
              "type": "shadowsocks",
              "listen": "::",
              "listen_port": $port,
              "method": "aes-128-gcm",
              "password": $psk,
              "tag": "ss-in"
            }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            
            # 更新缓存和协议标记
            sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$CACHE_FILE" 2>/dev/null || echo "ENABLE_SS=true" >> "$CACHE_FILE"
            echo "SS_PORT=$SS_PORT" >> "$CACHE_FILE"
            echo "SS_PSK=$SS_PSK" >> "$CACHE_FILE"
            echo "SS_METHOD=$SS_METHOD" >> "$CACHE_FILE"
            
            PROTOCOL_FILE="/etc/sing-box/.protocols"
            if [ -f "$PROTOCOL_FILE" ]; then
                sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$PROTOCOL_FILE"
            else
                echo "ENABLE_SS=true" >> "$PROTOCOL_FILE"
            fi
            
            ENABLE_SS=true
            
            info "SS 已部署 - 端口: $SS_PORT"
            service_start || warn "启动服务失败"
            sleep 1
            
            read_config
        else
            err "取消生成线路机脚本"
            return 1
        fi
    fi
    
    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="/tmp/relay-install.sh"
    
    info "正在生成线路机脚本: $RELAY_SCRIPT"
    
    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")

RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

mkdir -p /etc/sing-box
echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt

echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
echo ""
info "💡 链接已保存到: /etc/sing-box/relay_uri.txt"
info "💡 查看链接命令: cat /etc/sing-box/relay_uri.txt"
RELAY_EOF

    # 替换占位符
    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|${REALITY_SNI:-gateway.icloud.com}|g" "$RELAY_SCRIPT"
    
    chmod +x "$RELAY_SCRIPT"
    
    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    cat "$RELAY_SCRIPT"
    echo "----------------------------------------"
    echo ""
    info "在线路机执行命令示例："
    echo "   nano /tmp/relay-install.sh 保存后执行"
    echo "   chmod +x /tmp/relay-install.sh && bash /tmp/relay-install.sh"
    echo ""
    info "复制执行完成后，即可在线路机完成 sing-box 中转节点部署。"
}

# 重新安装其它协议 (删除当前协议并安装新协议)
action_reinstall_protocols() {
    echo ""
    info "=========================================="
    info "=== 重新安装其它协议 (将删除当前协议配置) ==="
    info "=========================================="
    read -p "确认重新安装其它协议? 当前所有节点协议将被覆盖(y/N): " confirm_reinstall
    if [[ ! "$confirm_reinstall" =~ ^[Yy]$ ]]; then
        info "已取消重新安装"
        return 0
    fi

    # 1. 选择新协议
    echo ""
    info "=== 选择要部署的协议 (纯净TCP保障防火墙安全) ==="
    echo "1) VLESS Reality (推荐, 默认)"
    echo "2) VMess (TLS + WS)"
    echo "3) Shadowsocks (SS 2022 / AEAD)"
    echo "4) AnyTLS Reality"
    echo "5) Trojan (TLS + BusyBox Web回落, 强抗主动嗅探)"
    echo ""
    read -p "请输入要部署的协议编号(回车默认 1, 多个用空格分隔如: 1 2): " protocol_input
    protocol_input="${protocol_input:-1}"

    local NEW_ENABLE_REALITY=false
    local NEW_ENABLE_VMESS=false
    local NEW_ENABLE_SS=false
    local NEW_ENABLE_ANYTLS=false
    local NEW_ENABLE_TROJAN=false

    for num in $protocol_input; do
        case "$num" in
            1) NEW_ENABLE_REALITY=true ;;
            2) NEW_ENABLE_VMESS=true ;;
            3) NEW_ENABLE_SS=true ;;
            4) NEW_ENABLE_ANYTLS=true ;;
            5) NEW_ENABLE_TROJAN=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done

    if ! $NEW_ENABLE_REALITY && ! $NEW_ENABLE_VMESS && ! $NEW_ENABLE_SS && ! $NEW_ENABLE_ANYTLS && ! $NEW_ENABLE_TROJAN; then
        err "未选择任何有效协议，取消操作"
        return 1
    fi

    # 2. 如果选了 SS，选择加密方式
    local NEW_SS_METHOD="2022-blake3-aes-128-gcm"
    if $NEW_ENABLE_SS; then
        echo ""
        info "=== 选择 Shadowsocks 加密方式 ==="
        echo "1) 2022-blake3-aes-128-gcm (推荐)"
        echo "2) aes-128-gcm"
        read -p "请输入选择(默认为 1): " ss_method_choice
        case "${ss_method_choice:-1}" in
            1) NEW_SS_METHOD="2022-blake3-aes-128-gcm" ;;
            2) NEW_SS_METHOD="aes-128-gcm" ;;
            *) NEW_SS_METHOD="2022-blake3-aes-128-gcm" ;;
        esac
    fi

    # 3. 节点连接 IP 或 DDNS
    echo ""
    read_config 2>/dev/null || true
    local default_ip="${CUSTOM_IP:-$(get_public_ip)}"
    read -p "请输入节点连接 IP 或 DDNS 域名 (留空保持: ${default_ip}): " user_custom_ip
    user_custom_ip="$(echo "${user_custom_ip:-$default_ip}" | tr -d '[:space:]')"

    # 4. 如果选了 Reality (VLESS 或 AnyTLS)，配置 SNI
    local NEW_REALITY_SNI=""
    if $NEW_ENABLE_REALITY || $NEW_ENABLE_ANYTLS; then
        local sni_pool=(
            "gateway.icloud.com"
            "itunes.apple.com"
            "download.apple.com"
            "mask.icloud.com"
            "learn.microsoft.com"
            "azure.microsoft.com"
            "www.microsoft.com"
            "edge.microsoft.com"
            "dl-cdn.alpinelinux.org"
            "deb.debian.org"
            "cloudflare.com"
            "aws.amazon.com"
            "www.speedtest.net"
            "www.nvidia.com"
        )
        local random_sni="${sni_pool[$((RANDOM % ${#sni_pool[@]}))]}"
        local current_sni="${REALITY_SNI:-$random_sni}"
        echo ""
        info "已推荐 SNI: \033[1;32m${current_sni}\033[0m"
        read -p "请输入 Reality 的 SNI 伪装域名 (留空保持: ${current_sni}): " user_sni
        NEW_REALITY_SNI="${user_sni:-$current_sni}"
        NEW_REALITY_SNI="$(echo "$NEW_REALITY_SNI" | tr -d '[:space:]')"
    fi

    # 5. 配置各协议端口和凭据
    local NEW_PORT_REALITY=""
    local NEW_UUID=""
    if $NEW_ENABLE_REALITY; then
        echo ""
        info "=== 配置 VLESS Reality ==="
        read -p "请输入 VLESS Reality 端口 (留空则随机 10000-60000): " input_port
        NEW_PORT_REALITY="${input_port:-$(rand_port)}"
        NEW_UUID=$(rand_uuid)
        info "VLESS Reality 端口: $NEW_PORT_REALITY | UUID 已自动生成"
    fi

    local NEW_PORT_VMESS=""
    local NEW_VMESS_UUID=""
    local NEW_VMESS_PATH=""
    local NEW_VMESS_SNI=""
    if $NEW_ENABLE_VMESS; then
        echo ""
        info "=== 配置 VMess (TLS + WS) ==="
        read -p "请输入 VMess 端口 (留空则随机 10000-60000): " input_port
        NEW_PORT_VMESS="${input_port:-$(rand_port)}"
        read -p "请输入 VMess WebSocket 路径 (留空默认 /vmess-ws): " input_path
        NEW_VMESS_PATH="${input_path:-/vmess-ws}"
        [[ ! "$NEW_VMESS_PATH" =~ ^/ ]] && NEW_VMESS_PATH="/$NEW_VMESS_PATH"

        local default_vmess_sni
        if [ -n "$user_custom_ip" ] && ! [[ "$user_custom_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            default_vmess_sni="$user_custom_ip"
        else
            default_vmess_sni="${NEW_REALITY_SNI:-gateway.icloud.com}"
        fi
        read -p "请输入 VMess TLS SNI 伪装域名 (留空保持: ${default_vmess_sni}): " input_vmess_sni
        NEW_VMESS_SNI="${input_vmess_sni:-$default_vmess_sni}"
        NEW_VMESS_SNI="$(echo "$NEW_VMESS_SNI" | tr -d '[:space:]')"

        NEW_VMESS_UUID=$(rand_uuid)
        info "VMess 端口: $NEW_PORT_VMESS | WS 路径: $NEW_VMESS_PATH | SNI: $NEW_VMESS_SNI"
        info "VMess UUID 已自动生成"

    fi

    local NEW_PORT_SS=""
    local NEW_PSK_SS=""
    if $NEW_ENABLE_SS; then
        echo ""
        info "=== 配置 Shadowsocks (SS) ==="
        read -p "请输入 SS 端口 (留空则随机 10000-60000): " input_port
        NEW_PORT_SS="${input_port:-$(rand_port)}"
        NEW_PSK_SS=$(rand_pass)
        info "SS 端口: $NEW_PORT_SS | 加密方式: $NEW_SS_METHOD | 密码已自动生成"
    fi

    local NEW_PORT_ANYTLS=""
    local NEW_ANYTLS_USER=""
    local NEW_ANYTLS_PSK=""
    if $NEW_ENABLE_ANYTLS; then
        echo ""
        info "=== 配置 AnyTLS Reality ==="
        read -p "请输入 AnyTLS Reality 端口 (留空则随机 10000-60000): " input_port
        NEW_PORT_ANYTLS="${input_port:-$(rand_port)}"
        NEW_ANYTLS_USER=$(openssl rand -hex 4)
        NEW_ANYTLS_PSK=$(openssl rand -base64 16)
        info "AnyTLS Reality 端口: $NEW_PORT_ANYTLS | 用户名: $NEW_ANYTLS_USER | 密码已自动生成"
    fi

    local NEW_PORT_TROJAN=""
    local NEW_TROJAN_PASS=""
    local NEW_TROJAN_SNI=""
    if $NEW_ENABLE_TROJAN; then
        echo ""
        info "=== 配置 Trojan (TLS + BusyBox Web回落) ==="
        read -p "请输入 Trojan 端口 (留空则随机 10000-60000): " input_port
        NEW_PORT_TROJAN="${input_port:-$(rand_port)}"
        read -p "请输入 Trojan 密码 (留空自动生成): " input_pass
        NEW_TROJAN_PASS="${input_pass:-$(rand_pass)}"

        local default_trojan_sni
        if [ -n "$user_custom_ip" ] && ! [[ "$user_custom_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            default_trojan_sni="$user_custom_ip"
        else
            default_trojan_sni="${NEW_REALITY_SNI:-gateway.icloud.com}"
        fi
        read -p "请输入 Trojan TLS SNI 伪装域名 (留空保持: ${default_trojan_sni}): " input_trojan_sni
        NEW_TROJAN_SNI="${input_trojan_sni:-$default_trojan_sni}"
        NEW_TROJAN_SNI="$(echo "$NEW_TROJAN_SNI" | tr -d '[:space:]')"

        info "Trojan 端口: $NEW_PORT_TROJAN | SNI: $NEW_TROJAN_SNI | 密码已设置"
    fi

    # 生成 TLS 证书 (VMess / Trojan) 并配置 fake-web
    if $NEW_ENABLE_VMESS || $NEW_ENABLE_TROJAN; then
        local target_sni="${NEW_TROJAN_SNI:-${NEW_VMESS_SNI:-gateway.icloud.com}}"
        mkdir -p /etc/sing-box
        if [ ! -f /etc/sing-box/vmess.crt ] || [ ! -f /etc/sing-box/vmess.key ]; then
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
                -keyout /etc/sing-box/vmess.key -out /etc/sing-box/vmess.crt -days 3650 \
                -subj "/CN=${target_sni}" >/dev/null 2>&1 || {
                openssl req -x509 -newkey rsa:2048 -nodes \
                    -keyout /etc/sing-box/vmess.key -out /etc/sing-box/vmess.crt -days 3650 \
                    -subj "/CN=${target_sni}" >/dev/null 2>&1
            }
        fi
        if $NEW_ENABLE_TROJAN; then
            case "$OS" in
                alpine) apk add --no-cache busybox-extras >/dev/null 2>&1 || true ;;
                debian|redhat) apt-get install -y busybox >/dev/null 2>&1 || yum install -y busybox >/dev/null 2>&1 || true ;;
            esac
            local web_dir="/var/www/fake-site"
            mkdir -p "$web_dir"
            if [ ! -f "$web_dir/index.html" ]; then
                cat > "$web_dir/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Enterprise Edge Service Gateway</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #f8fafc; color: #1e293b; margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
        .card { background: #ffffff; border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -2px rgba(0,0,0,0.1); border: 1px solid #e2e8f0; padding: 40px; max-width: 520px; width: 90%; }
        .badge { display: inline-flex; align-items: center; background-color: #ecfdf5; color: #059669; font-size: 13px; font-weight: 600; padding: 4px 10px; border-radius: 9999px; margin-bottom: 16px; }
        .badge-dot { width: 8px; height: 8px; background-color: #10b981; border-radius: 50%; margin-right: 6px; }
        h1 { font-size: 22px; font-weight: 700; margin: 0 0 12px 0; color: #0f172a; }
        p { font-size: 14px; line-height: 1.6; color: #64748b; margin: 0 0 24px 0; }
        .grid { border-top: 1px solid #f1f5f9; padding-top: 20px; display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        .item-label { font-size: 12px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 4px; }
        .item-value { font-size: 14px; font-weight: 600; color: #334155; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge"><span class="badge-dot"></span>Service Active</div>
        <h1>Edge Application Gateway</h1>
        <p>This endpoint is managed by the network automation cluster. Secure ingress routing and health telemetry are operating normally.</p>
        <div class="grid">
            <div>
                <div class="item-label">Status</div>
                <div class="item-value">200 Operational</div>
            </div>
            <div>
                <div class="item-label">Protocol</div>
                <div class="item-value">HTTP/1.1 TLS</div>
            </div>
        </div>
    </div>
</body>
</html>
EOF
            fi
            cat > /usr/local/bin/fake-web-server <<'EOF'
#!/bin/sh
WEB_DIR="/var/www/fake-site"
mkdir -p "$WEB_DIR"
if [ -x /usr/sbin/httpd ]; then
    exec /usr/sbin/httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
elif command -v busybox >/dev/null 2>&1; then
    exec busybox httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
elif command -v busybox-extras >/dev/null 2>&1; then
    exec busybox-extras httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
else
    exec httpd -f -p 127.0.0.1:8080 -h "$WEB_DIR"
fi
EOF
            chmod +x /usr/local/bin/fake-web-server
            if [ "$OS" = "alpine" ]; then
                cat > /etc/init.d/fake-web <<'OPENRC'
#!/sbin/openrc-run
name="fake-web"
description="BusyBox httpd Fallback Web Server"
command="/usr/local/bin/fake-web-server"
command_background="yes"
pidfile="/run/fake-web.pid"
depend() { need net; }
start_pre() { checkpath --directory --mode 0755 /run; }
OPENRC
                chmod +x /etc/init.d/fake-web
                rc-update add fake-web default >/dev/null 2>&1 || true
                rc-service fake-web restart >/dev/null 2>&1 || rc-service fake-web start >/dev/null 2>&1 || true
            else
                cat > /etc/systemd/system/fake-web.service <<'SYSTEMD'
[Unit]
Description=BusyBox httpd Fallback Web Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/fake-web-server
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SYSTEMD
                systemctl daemon-reload >/dev/null 2>&1 || true
                systemctl enable fake-web >/dev/null 2>&1 || true
                systemctl restart fake-web >/dev/null 2>&1 || systemctl start fake-web >/dev/null 2>&1 || true
            fi
        fi
    fi

    # 6. 生成 Reality 密钥对 (如需要)
    local NEW_REALITY_PK=""
    local NEW_REALITY_PUB=""
    local NEW_REALITY_SID=""
    if $NEW_ENABLE_REALITY || $NEW_ENABLE_ANYTLS; then
        info "生成 Reality 密钥对..."
        local reality_keys
        reality_keys=$(sing-box generate reality-keypair 2>&1) || {
            err "生成 Reality 密钥失败"
            return 1
        }
        NEW_REALITY_PK=$(echo "$reality_keys" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
        NEW_REALITY_PUB=$(echo "$reality_keys" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
        NEW_REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
            err "生成 Reality ShortID 失败"
            return 1
        }
        echo -n "$NEW_REALITY_PUB" > /etc/sing-box/.reality_pub
        echo -n "$NEW_REALITY_SID" > /etc/sing-box/.reality_sid
    fi

    # 7. 停止服务并备份旧配置
    info "正在停止 sing-box 服务..."
    service_stop || warn "停止服务失败"
    [ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"

    # 8. 生成新配置文件
    info "正在写入新配置文件..."
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$$.json"
    > "$TEMP_INBOUNDS"
    local need_comma=false

    if $NEW_ENABLE_REALITY; then
        cat >> "$TEMP_INBOUNDS" <<INBOUND_REALITY
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $NEW_PORT_REALITY,
      "users": [
        {
          "uuid": "$NEW_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$NEW_REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$NEW_REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$NEW_REALITY_PK",
          "short_id": ["$NEW_REALITY_SID"]
        }
      }
    }
INBOUND_REALITY
        need_comma=true
    fi

    if $NEW_ENABLE_VMESS; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<INBOUND_VMESS
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": $NEW_PORT_VMESS,
      "users": [
        {
          "name": "default",
          "uuid": "$NEW_VMESS_UUID",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$NEW_VMESS_PATH"
      },
      "tls": {
        "enabled": true,
        "server_name": "$NEW_VMESS_SNI",
        "certificate_path": "/etc/sing-box/vmess.crt",
        "key_path": "/etc/sing-box/vmess.key"
      }
    }
INBOUND_VMESS
        need_comma=true
    fi

    if $NEW_ENABLE_SS; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<INBOUND_SS
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": $NEW_PORT_SS,
      "method": "$NEW_SS_METHOD",
      "password": "$NEW_PSK_SS",
      "tag": "ss-in"
    }
INBOUND_SS
        need_comma=true
    fi

    if $NEW_ENABLE_ANYTLS; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<INBOUND_ANYTLS
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $NEW_PORT_ANYTLS,
      "users": [
        {
          "name": "$NEW_ANYTLS_USER",
          "password": "$NEW_ANYTLS_PSK"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "$NEW_REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$NEW_REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$NEW_REALITY_PK",
          "short_id": [
            "$NEW_REALITY_SID"
          ]
        }
      }
    }
INBOUND_ANYTLS
        need_comma=true
    fi

    if $NEW_ENABLE_TROJAN; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<INBOUND_TROJAN
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": $NEW_PORT_TROJAN,
      "users": [
        {
          "name": "default",
          "password": "$NEW_TROJAN_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$NEW_TROJAN_SNI",
        "certificate_path": "/etc/sing-box/vmess.crt",
        "key_path": "/etc/sing-box/vmess.key"
      },
      "fallback": {
        "server": "127.0.0.1",
        "server_port": 8080
      }
    }
INBOUND_TROJAN
        need_comma=true
    fi

    cat > "$CONFIG_PATH" <<CONFIG_HEAD
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD

    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    rm -f "$TEMP_INBOUNDS"

    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    # 9. 保存协议标记与缓存
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_REALITY=$NEW_ENABLE_REALITY
ENABLE_VMESS=$NEW_ENABLE_VMESS
ENABLE_SS=$NEW_ENABLE_SS
ENABLE_ANYTLS=$NEW_ENABLE_ANYTLS
ENABLE_TROJAN=$NEW_ENABLE_TROJAN
EOF

    cat > "$CACHE_FILE" <<CACHEEOF
ENABLE_REALITY=$NEW_ENABLE_REALITY
ENABLE_VMESS=$NEW_ENABLE_VMESS
ENABLE_SS=$NEW_ENABLE_SS
ENABLE_ANYTLS=$NEW_ENABLE_ANYTLS
ENABLE_TROJAN=$NEW_ENABLE_TROJAN
CUSTOM_IP=$user_custom_ip
CACHEEOF

    $NEW_ENABLE_REALITY && cat >> "$CACHE_FILE" <<CACHEEOF
REALITY_PORT=$NEW_PORT_REALITY
REALITY_UUID=$NEW_UUID
REALITY_PK=$NEW_REALITY_PK
REALITY_SID=$NEW_REALITY_SID
REALITY_PUB=$NEW_REALITY_PUB
REALITY_SNI=$NEW_REALITY_SNI
CACHEEOF

    $NEW_ENABLE_VMESS && cat >> "$CACHE_FILE" <<CACHEEOF
VMESS_PORT=$NEW_PORT_VMESS
VMESS_UUID=$NEW_VMESS_UUID
VMESS_PATH=$NEW_VMESS_PATH
VMESS_SNI=$NEW_VMESS_SNI
CACHEEOF

    $NEW_ENABLE_SS && cat >> "$CACHE_FILE" <<CACHEEOF
SS_PORT=$NEW_PORT_SS
SS_PSK=$NEW_PSK_SS
SS_METHOD=$NEW_SS_METHOD
CACHEEOF

    $NEW_ENABLE_ANYTLS && cat >> "$CACHE_FILE" <<CACHEEOF
ANYTLS_PORT=$NEW_PORT_ANYTLS
ANYTLS_USER=$NEW_ANYTLS_USER
ANYTLS_PSK=$NEW_ANYTLS_PSK
CACHEEOF

    $NEW_ENABLE_TROJAN && cat >> "$CACHE_FILE" <<CACHEEOF
PORT_TROJAN=$NEW_PORT_TROJAN
TROJAN_PASS=$NEW_TROJAN_PASS
TROJAN_SNI=$NEW_TROJAN_SNI
CACHEEOF

    # 10. 检查配置并启动服务
    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 && info "新配置文件验证通过" || warn "配置文件验证未通过，请检查"
    fi

    info "正在启动服务..."
    service_start || warn "服务启动失败"
    sleep 1

    info "🎉 协议重新安装完成！"
    action_view_uri || true
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true
    
    cat <<'MENU'

==========================
 Sing-box 管理面板 (快捷命令: sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    local option=4
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi

    if [ "${ENABLE_VMESS:-false}" = "true" ]; then
        echo "$option) 重置 VMess 端口"
        MENU_MAP[$option]="reset_vmess"
        option=$((option + 1))
    fi

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    if [ "${ENABLE_TROJAN:-false}" = "true" ]; then
        echo "$option) 重置 Trojan 端口与密码"
        MENU_MAP[$option]="reset_trojan"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    echo "$option) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    echo "$option) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    echo "$option) 查看状态"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    echo "$option) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="relay"
    echo "$option) 生成中转线路机脚本(出口为本机 SS 协议)"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    echo "$option) 卸载 sing-box"
    option=$((option + 1))

    MENU_MAP[$option]="reinstall_protocols"
    echo "$option) 重新安装其它协议"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt
    
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_reality) action_reset_reality ;;
                reset_vmess) action_reset_vmess ;;
                reset_ss) action_reset_ss ;;
                reset_anytls) action_reset_anytls ;;
                reset_trojan) action_reset_trojan ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                reinstall_protocols) action_reinstall_protocols ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb 2>/dev/null || true
info "✅ 管理面板已创建, 可在终端直接输入 sb 打开管理面板"
