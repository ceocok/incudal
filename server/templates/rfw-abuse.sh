#!/usr/bin/env bash
# ==============================================================================
# Incudal - RFW 防火墙防滥用扩展脚本 (RFW Abuse Shield)
# 功能：屏蔽 测速 (Speedtest/iPerf/cf-probe) / 挖矿 (Stratum/Pools) / BT与P2P (BitTorrent/DHT/迅雷) / 跑分压测 (Geekbench/YABS) / DD重装系统 / MTProto代理 / 代理面板 (x-ui/3x-ui/s-ui)
# 作用域：FORWARD (容器与NAT VPS实例) + OUTPUT (宿主机本身) + INPUT (入站P2P探针)
# 支持：IPv4 (iptables) + IPv6 (ip6tables) 双栈
# ==============================================================================

set -e

SCRIPT_VERSION="1.3.0"
INSTALL_PATH="/usr/local/bin/rfw-abuse"
SERVICE_PATH="/etc/systemd/system/rfw-abuse.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CHAIN_V4="RFW_ABUSE"
CHAIN_V6="RFW_ABUSE_V6"

log()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info()  { echo -e "  ${CYAN}ℹ${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error() { echo -e "  ${RED}✗${NC}  $*" >&2; }
divider() { echo -e "${DIM}  ──────────────────────────────────────────────────────────${NC}"; }

# 必须为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 权限运行！请使用 sudo bash $0"
        exit 1
    fi
}

# 依赖检查与安装
check_dependencies() {
    local need_install=()
    if ! command -v iptables >/dev/null 2>&1; then
        need_install+=("iptables")
    fi

    if [[ ${#need_install[@]} -gt 0 ]]; then
        info "正在安装必要组件: ${need_install[*]} ..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y -qq "${need_install[@]}"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${need_install[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${need_install[@]}"
        fi
    fi

    # 加载 xt_string 内核模块 (DPI 字符串匹配所需)
    modprobe xt_string >/dev/null 2>&1 || true
    modprobe iptable_filter >/dev/null 2>&1 || true
    modprobe ip6table_filter >/dev/null 2>&1 || true
}

# 动态检测当前机器的 SSH 端口（防止误杀导致失联）
detect_ssh_ports() {
    local ports=()
    # 从 ss / netstat 读取监听端口
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r p; do
            [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done < <(ss -tlnp 2>/dev/null | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u)
    fi

    # 如果没读到，从 sshd_config 兜底
    if [[ ${#ports[@]} -eq 0 && -f /etc/ssh/sshd_config ]]; then
        while IFS= read -r p; do
            [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done < <(grep -E '^Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -u)
    fi

    # 兜底默认 22
    ports+=(22)

    # 去重组合为逗号分隔字符串
    local unique_ports
    unique_ports=$(printf "%s\n" "${ports[@]}" | sort -u | paste -sd, -)
    echo "${unique_ports:-22}"
}

# 检查 IPv6 支持
has_ipv6() {
    command -v ip6tables >/dev/null 2>&1 && [[ -f /proc/net/if_inet6 ]]
}

# 独立 DD 域名黑洞（dnsmasq 继承宿主机 /etc/hosts，容器解析即黑洞）
apply_dd_dns_sinkhole() {
    local marker="# Incudal Anti-DD Sinkhole"
    local domains="moeclub.org cx9208.com iso.qaq.wiki leitbogioro.org"
    if ! grep -q "$marker" /etc/hosts 2>/dev/null; then
        {
            echo "$marker"
            echo "127.0.0.1 $domains"
            echo "::1 $domains"
        } >> /etc/hosts 2>/dev/null || true
    fi
}

clean_dd_dns_sinkhole() {
    if [[ -f /etc/hosts ]] && grep -q "# Incudal Anti-DD Sinkhole" /etc/hosts 2>/dev/null; then
        sed -i '/# Incudal Anti-DD Sinkhole/,+2d' /etc/hosts 2>/dev/null || true
    fi
}

# 宿主机实时反滥用与违规代理守护进程（秒级击毙容器内运行的 DD 脚本、MTProto 代理与 x-ui/3x-ui/s-ui 面板）
apply_antidd_daemon() {
    local enable_dd="${1:-true}"
    local enable_mt="${2:-true}"
    local enable_panel="${3:-true}"

    # 若三项均未开启，则停用守护服务
    if [[ "$enable_dd" != "true" && "$enable_mt" != "true" && "$enable_panel" != "true" ]]; then
        stop_antidd_daemon
        return 0
    fi

    # 动态组装进程匹配正则
    local patterns=()
    if [[ "$enable_dd" == "true" ]]; then
        patterns+=("OsMutation|reinstall\\.sh|InstallNET|NewReinstall|debi\\.sh|clean-vps|G-Reinstall")
    fi
    if [[ "$enable_mt" == "true" ]]; then
        patterns+=("(^|[ /])(mtg|mtproto-proxy|teleproxy|mtp-proxy|mtproxy)([[:space:]]|$)")
    fi
    if [[ "$enable_panel" == "true" ]]; then
        patterns+=("(^|[ /])(x-ui|3x-ui|s-ui|v2-ui)([[:space:]]|$)|/(x-ui|3x-ui|s-ui|v2-ui)/|x-ui\\.sh|3x-ui\\.sh|s-ui\\.sh")
    fi
    # 违规测速与探针进程 (cf-probe / CloudflareSpeedTest)
    patterns+=("(^|[ /])(cf-probe|CloudflareSpeedTest|cf-speedtest)([[:space:]]|$)|cf-probe\\.sh")

    local combined_pattern
    combined_pattern=$(IFS='|'; echo "${patterns[*]}")

    cat > /usr/local/bin/rfw-antidd-daemon << EOF
#!/usr/bin/env bash
# Incudal Anti-Abuse Real-Time Process Killer (DD, MTProto, ProxyPanels & cf-probe)
PATTERN="${combined_pattern}"
while true; do
    # 扫描属于容器命名空间的进程 (UID >= 1000000 属于 Incus 映射的用户命名空间)
    pids=\$(ps -eo uid,pid,args 2>/dev/null | awk -v pat="\$PATTERN" '\$1 >= 1000000 && \$0 ~ pat && \$0 !~ /rfw-antidd/ {print \$2}')
    for p in \$pids; do
        if kill -9 "\$p" 2>/dev/null; then
            logger -t rfw-antidd "Killed rogue container process (Anti-Abuse/DD/MTProto/Panel/cf-probe): PID \$p"
        fi
    done
    sleep 0.5
done
EOF
    chmod +x /usr/local/bin/rfw-antidd-daemon

    cat > /etc/systemd/system/rfw-antidd.service << 'EOF'
[Unit]
Description=Incudal Anti-Abuse Real-Time Process Killer (DD, MTProto, ProxyPanels & cf-probe)
After=incus.service

[Service]
Type=simple
ExecStart=/usr/local/bin/rfw-antidd-daemon
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now rfw-antidd.service >/dev/null 2>&1 || true
    log "已启动宿主机反滥用违规进程 (DD/MTProto/代理面板/cf-probe) 秒级巡检守护服务 (rfw-antidd)"
}

stop_antidd_daemon() {
    systemctl stop rfw-antidd.service 2>/dev/null || true
    systemctl disable rfw-antidd.service 2>/dev/null || true
    rm -f /etc/systemd/system/rfw-antidd.service /usr/local/bin/rfw-antidd-daemon 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# 容器内文件锁：破坏 OsMutation、MTProto、x-ui/3x-ui/s-ui 面板与 cf-probe 的安装与执行工作流
apply_container_traps() {
    local enable_dd="${1:-true}"
    local enable_mt="${2:-true}"
    local enable_panel="${3:-true}"

    command -v incus >/dev/null 2>&1 || return 0
    local containers
    containers=$(incus list status=running type=container -c n --format csv 2>/dev/null || true)
    local count=0
    for ct in $containers; do
        [[ -z "$ct" ]] && continue
        # 1. 锁死 /x，破坏 DD 脚本工作区
        if [[ "$enable_dd" == "true" ]]; then
            incus exec "$ct" -- sh -c 'touch /x 2>/dev/null && chmod 000 /x 2>/dev/null && chattr +i /x 2>/dev/null || true' 2>/dev/null || true
            incus exec "$ct" -- sh -c '
                for f in /root/OsMutation.sh /root/reinstall.sh /root/InstallNET.sh /root/NewReinstall.sh /usr/local/bin/OsMutation.sh; do
                    if [ ! -f "$f" ]; then
                        echo "#!/bin/sh" > "$f" 2>/dev/null
                        echo "echo \"\033[1;31m[错误] 当前环境为 Incudal LXC 容器，禁止执行 DD 重装系统！\033[0m\"" >> "$f" 2>/dev/null
                        echo "exit 1" >> "$f" 2>/dev/null
                        chmod 755 "$f" 2>/dev/null || true
                    fi
                done
            ' 2>/dev/null || true
        fi
        # 2. 拦截并占位 MTProto 代理二进制文件
        if [[ "$enable_mt" == "true" ]]; then
            incus exec "$ct" -- sh -c '
                for f in /usr/local/bin/mtg /usr/bin/mtg /usr/local/bin/mtproto-proxy /usr/bin/mtproto-proxy; do
                    if [ ! -f "$f" ]; then
                        echo "#!/bin/sh" > "$f" 2>/dev/null
                        echo "echo \"\033[1;31m[错误] 本节点严禁运行 Telegram MTProto 代理服务！\033[0m\"" >> "$f" 2>/dev/null
                        echo "exit 1" >> "$f" 2>/dev/null
                        chmod 755 "$f" 2>/dev/null || true
                    fi
                done
            ' 2>/dev/null || true
        fi
        # 3. 拦截并占位 x-ui / 3x-ui / s-ui / v2-ui 面板主程序与命令
        if [[ "$enable_panel" == "true" ]]; then
            incus exec "$ct" -- sh -c '
                for d in /usr/local/x-ui /usr/local/3x-ui /usr/local/s-ui /usr/local/v2-ui; do
                    if [ ! -d "$d" ]; then
                        mkdir -p "$d" 2>/dev/null || true
                    fi
                done
                for f in /usr/local/x-ui/x-ui /usr/local/3x-ui/3x-ui /usr/local/s-ui/s-ui /usr/local/v2-ui/v2-ui /usr/bin/x-ui /usr/bin/3x-ui /usr/bin/s-ui /usr/bin/v2-ui; do
                    if [ ! -f "$f" ]; then
                        echo "#!/bin/sh" > "$f" 2>/dev/null
                        echo "echo \"\033[1;31m[错误] 本节点严禁运行 x-ui / 3x-ui / s-ui 等代理面板服务！\033[0m\"" >> "$f" 2>/dev/null
                        echo "exit 1" >> "$f" 2>/dev/null
                        chmod 755 "$f" 2>/dev/null || true
                    fi
                done
            ' 2>/dev/null || true
        fi
        # 4. 拦截并占位 cf-probe / Cloudflare 测速与探测程序，停用常驻服务
        incus exec "$ct" -- sh -c '
            for f in /usr/local/bin/cf-probe /usr/bin/cf-probe /usr/local/bin/CloudflareSpeedTest /usr/bin/CloudflareSpeedTest; do
                if [ -f "$f" ] || [ ! -e "$f" ]; then
                    echo "#!/bin/sh" > "$f" 2>/dev/null
                    echo "echo \"\033[1;31m[错误] 本节点严禁运行 cf-probe / Cloudflare 测速探针服务！\033[0m\"" >> "$f" 2>/dev/null
                    echo "exit 1" >> "$f" 2>/dev/null
                    chmod 755 "$f" 2>/dev/null || true
                fi
            done
            if [ -f /etc/init.d/cf-probe ]; then
                rc-service cf-probe stop 2>/dev/null || true
                rc-update del cf-probe default 2>/dev/null || true
            fi
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop cf-probe 2>/dev/null || true
                systemctl disable cf-probe 2>/dev/null || true
            fi
        ' 2>/dev/null || true
        count=$((count+1))
    done
    if [ "$count" -gt 0 ]; then
        log "已为当前运行的 $count 个容器布署防 DD / 防 MTProto / 防代理面板 / 防 cf-probe 物理工作区锁"
    fi
}

# 清理自建链与挂载
clean_rules() {
    info "正在清理旧的 RFW 防滥用规则..."

    # IPv4 清理
    if command -v iptables >/dev/null 2>&1; then
        iptables -D FORWARD -j "$CHAIN_V4" 2>/dev/null || true
        iptables -D OUTPUT -j "$CHAIN_V4" 2>/dev/null || true
        iptables -D INPUT -j "$CHAIN_V4" 2>/dev/null || true
        iptables -F "$CHAIN_V4" 2>/dev/null || true
        iptables -X "$CHAIN_V4" 2>/dev/null || true
    fi

    # IPv6 清理
    if has_ipv6; then
        ip6tables -D FORWARD -j "$CHAIN_V6" 2>/dev/null || true
        ip6tables -D OUTPUT -j "$CHAIN_V6" 2>/dev/null || true
        ip6tables -D INPUT -j "$CHAIN_V6" 2>/dev/null || true
        ip6tables -F "$CHAIN_V6" 2>/dev/null || true
        ip6tables -X "$CHAIN_V6" 2>/dev/null || true
    fi

    clean_dd_dns_sinkhole
    stop_antidd_daemon
    log "已清理现有防护规则"
}

# 应用核心防护规则
apply_rules() {
    local enable_speedtest="${1:-true}"
    local enable_mining="${2:-true}"
    local enable_bt="${3:-true}"
    local enable_bench="${4:-true}"
    local enable_antidd="${5:-true}"
    local enable_mtproto="${6:-true}"
    local enable_proxypanel="${7:-true}"

    check_dependencies
    clean_rules

    local ssh_ports
    ssh_ports=$(detect_ssh_ports)
    info "检测到 SSH 端口 [${ssh_ports}]，已自动纳入安全白名单"

    # ========================== 1. 初始化 IPv4 链 ==========================
    iptables -N "$CHAIN_V4"

    # 1.1 白名单放行（避免误伤业务或管理失联）
    # 本地回环
    iptables -A "$CHAIN_V4" -i lo -j RETURN
    iptables -A "$CHAIN_V4" -o lo -j RETURN
    # ICMP Ping/MTU 探测
    iptables -A "$CHAIN_V4" -p icmp -j RETURN
    # 管理端口 (SSH)
    iptables -A "$CHAIN_V4" -p tcp -m multiport --dports "$ssh_ports" -j RETURN
    iptables -A "$CHAIN_V4" -p tcp -m multiport --sports "$ssh_ports" -j RETURN
    # 核心网络基础协议 (DNS, NTP, DHCP)
    iptables -A "$CHAIN_V4" -p udp --dport 53 -j RETURN
    iptables -A "$CHAIN_V4" -p tcp --dport 53 -j RETURN
    iptables -A "$CHAIN_V4" -p udp --sport 53 -j RETURN
    iptables -A "$CHAIN_V4" -p udp --dport 123 -j RETURN
    iptables -A "$CHAIN_V4" -p udp -m multiport --dports 67,68 -j RETURN

    # ========================== 2. 初始化 IPv6 链 ==========================
    if has_ipv6; then
        ip6tables -N "$CHAIN_V6"
        ip6tables -A "$CHAIN_V6" -i lo -j RETURN
        ip6tables -A "$CHAIN_V6" -o lo -j RETURN
        ip6tables -A "$CHAIN_V6" -p icmpv6 -j RETURN
        ip6tables -A "$CHAIN_V6" -p tcp -m multiport --dports "$ssh_ports" -j RETURN
        ip6tables -A "$CHAIN_V6" -p tcp -m multiport --sports "$ssh_ports" -j RETURN
        ip6tables -A "$CHAIN_V6" -p udp --dport 53 -j RETURN
        ip6tables -A "$CHAIN_V6" -p tcp --dport 53 -j RETURN
        ip6tables -A "$CHAIN_V6" -p udp --sport 53 -j RETURN
        ip6tables -A "$CHAIN_V6" -p udp --dport 123 -j RETURN
        ip6tables -A "$CHAIN_V6" -p udp -m multiport --dports 546,547 -j RETURN
    fi

    # ========================== 3. 屏蔽测速 (Speedtest) ==========================
    if [[ "$enable_speedtest" == "true" ]]; then
        info "正在加载【测速拦截】规则 (Speedtest / iPerf / Fast)..."
        # 3.1 测速专用端口拦截 (iperf/iperf3)
        iptables -A "$CHAIN_V4" -p tcp --dport 5201 -j REJECT --reject-with tcp-reset
        iptables -A "$CHAIN_V4" -p udp --dport 5201 -j DROP
        if has_ipv6; then
            ip6tables -A "$CHAIN_V6" -p tcp --dport 5201 -j REJECT --reject-with tcp-reset
            ip6tables -A "$CHAIN_V6" -p udp --dport 5201 -j DROP
        fi

        # 3.2 常见测速服务特征关键词 (HTTP/TLS SNI / URL 载荷匹配)
        local speedtest_keywords=(
            "speedtest"
            "speedtest.net"
            "speedtest.cn"
            "fast.com"
            "speed.cloudflare.com"
            "cf-probe"
            "CloudflareSpeedTest"
            "ookla"
            "test.ustc.edu.cn"
            "10000.gd.cn"
            "db.laomoe.com"
            "jiyou.cloud"
            "speedtestcustom.com"
        )
        for kw in "${speedtest_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            fi
        done
        log "测速拦截规则已生效"
    fi

    # ========================== 4. 屏蔽挖矿 (Mining) ==========================
    if [[ "$enable_mining" == "true" ]]; then
        info "正在加载【挖矿拦截】规则 (Stratum / XMRig / 常用矿池)..."
        # 4.1 典型矿池公认端口拦截
        local mining_ports="3333,4444,5555,6666,7777,8888,9999,14433,14444"
        iptables -A "$CHAIN_V4" -p tcp -m multiport --dports "$mining_ports" -j REJECT --reject-with tcp-reset
        if has_ipv6; then
            ip6tables -A "$CHAIN_V6" -p tcp -m multiport --dports "$mining_ports" -j REJECT --reject-with tcp-reset
        fi

        # 4.2 Stratum 协议握手与 JSON-RPC 关键词特征
        local mining_stratum_keywords=(
            "stratum+tcp"
            "stratum+udp"
            "stratum+ssl"
            "mining.subscribe"
            "mining.authorize"
            "mining.submit"
            "eth_submitLogin"
            "eth_submitHashrate"
        )
        for kw in "${mining_stratum_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1000 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1000 -j DROP 2>/dev/null || true
            fi
        done

        # 4.3 知名矿池域名特征
        local mining_pool_keywords=(
            "ethermine.org"
            "f2pool.com"
            "antpool.com"
            "nanopool.org"
            "nicehash.com"
            "supportxmr.com"
            "moneroocean.stream"
            "pool.minexmr.com"
            "2miners.com"
            "hashvault.pro"
            "xmrig"
        )
        for kw in "${mining_pool_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1000 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1000 -j DROP 2>/dev/null || true
            fi
        done
        log "挖矿拦截规则已生效"
    fi

    # ========================== 5. 屏蔽 BT / P2P 下载 (BitTorrent) ==========================
    if [[ "$enable_bt" == "true" ]]; then
        info "正在加载【BT/P2P拦截】规则 (BitTorrent / DHT / 迅雷)..."
        # 5.1 常用 BT / PT / Tracker / DHT 端口拦截
        iptables -A "$CHAIN_V4" -p tcp --dport 6881:6889 -j DROP
        iptables -A "$CHAIN_V4" -p udp --dport 6881:6889 -j DROP
        iptables -A "$CHAIN_V4" -p tcp --dport 6969 -j DROP
        iptables -A "$CHAIN_V4" -p udp --dport 6969 -j DROP
        iptables -A "$CHAIN_V4" -p tcp --dport 51413 -j DROP
        iptables -A "$CHAIN_V4" -p udp --dport 51413 -j DROP
        iptables -A "$CHAIN_V4" -p tcp -m multiport --dports 4662,4672 -j DROP
        iptables -A "$CHAIN_V4" -p udp -m multiport --dports 4662,4672 -j DROP
        if has_ipv6; then
            ip6tables -A "$CHAIN_V6" -p tcp --dport 6881:6889 -j DROP
            ip6tables -A "$CHAIN_V6" -p udp --dport 6881:6889 -j DROP
            ip6tables -A "$CHAIN_V6" -p tcp --dport 6969 -j DROP
            ip6tables -A "$CHAIN_V6" -p udp --dport 6969 -j DROP
            ip6tables -A "$CHAIN_V6" -p tcp --dport 51413 -j DROP
            ip6tables -A "$CHAIN_V6" -p udp --dport 51413 -j DROP
            ip6tables -A "$CHAIN_V6" -p tcp -m multiport --dports 4662,4672 -j DROP
            ip6tables -A "$CHAIN_V6" -p udp -m multiport --dports 4662,4672 -j DROP
        fi

        # 5.2 BitTorrent 握手协议、Tracker 与 DHT 报文特征
        local bt_keywords=(
            "BitTorrent"
            "BitTorrent protocol"
            "peer_id="
            "info_hash"
            ".torrent"
            "announce"
            "announce_peer"
            "get_peers"
            "find_node"
            "d1:ad2:id20:"
            "xunlei"
            "sandai"
            "Thunder"
            "XLLiveUD"
        )
        for kw in "${bt_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1000 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1000 -j DROP 2>/dev/null || true
            fi
        done
        log "BT/P2P 拦截规则已生效"
    fi

    # ========================== 6. 屏蔽性能跑分与压测 (Benchmark) ==========================
    if [[ "$enable_bench" == "true" ]]; then
        info "正在加载【性能跑分/压测拦截】规则 (Geekbench / YABS / SuperBench / UnixBench)..."
        local bench_keywords=(
            "yabs.sh"
            "geekbench"
            "geekbench.com"
            "cdn.geekbench.com"
            "bench.sh"
            "superbench"
            "superbench.sh"
            "lemonbench"
            "ilemonra.in"
            "ilemonrain.com"
            "unixbench"
            "byte-unixbench"
            "ecs.sh"
            "fusionbench"
            "bench.monster"
            "vpsbench"
            "sysbench"
            "coremark"
        )
        for kw in "${bench_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            fi
        done
        log "性能跑分/压测拦截规则已生效"
    fi

    # ========================== 7. 屏蔽系统重装与 DD 脚本 (Anti-DD) ==========================
    if [[ "$enable_antidd" == "true" ]]; then
        info "正在加载【DD重装脚本拦截】规则 (reinstall.sh / InstallNET / OsMutation / MoeClub)..."
        local dd_keywords=(
            # 常见 DD 脚本文件名与命令参数
            "reinstall.sh"
            "InstallNET.sh"
            "OsMutation.sh"
            "OsMutationKvm.sh"
            "NewReinstall.sh"
            "debi.sh"
            "clean-vps"
            "G-Reinstall"
            # 知名 DD 脚本仓库路径与作者标识
            "bin456789/reinstall"
            "leitbogioro/Tools"
            "Linux_reinstall"
            "MoeClub/Note"
            "MoeClub/Linux-Reinstall"
            "LloydAsp/OsMutation"
            "fcurrk/reinstall"
            "cx9208/Linux-Reinstall"
            "bohanyang/debi"
            "teddysun/across"
            "veip007/dd"
            "52fancy/G-Reinstall"
            "tianhe-xyz/Linux-Reinstall"
            "nat-ee/reinstall"
            # 知名独立 DD 站点与分发域名
            "moeclub.org"
            "cx9208.com"
            "iso.qaq.wiki"
            "leitbogioro.org"
        )
        for kw in "${dd_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            fi
        done

        # 宿主机 hosts 域名黑洞（Incus 网桥 dnsmasq 默认读取 /etc/hosts，容器解析即黑洞）
        apply_dd_dns_sinkhole
        log "DD重装脚本拦截规则已生效"
    else
        clean_dd_dns_sinkhole
    fi

    # ========================== 8. 屏蔽 Telegram MTProto 代理 (Anti-MTProto) ==========================
    if [[ "$enable_mtproto" == "true" ]]; then
        info "正在加载【Telegram MTProto 代理拦截】规则 (MTG / mtproto-proxy / 协议握手)..."
        # 8.1 传统 MTProto TCP 握手特征拦截 (Intermediate: 0xeeeeeeee, Padded: 0xdddddddd)
        iptables -A "$CHAIN_V4" -p tcp -m u32 --u32 "0>>22&0x3C@0=0xeeeeeeee" -m comment --comment "Block-MTProto-Intermediate" -j REJECT --reject-with tcp-reset 2>/dev/null || true
        iptables -A "$CHAIN_V4" -p tcp -m u32 --u32 "0>>22&0x3C@0=0xdddddddd" -m comment --comment "Block-MTProto-Padded" -j REJECT --reject-with tcp-reset 2>/dev/null || true

        # 8.2 MTG / MTProto 推广与分享链接、安装脚本与仓库特征匹配
        local mtproto_keywords=(
            "t.me/proxy?"
            "tg://proxy?"
            "9seconds/mtg"
            "mtg-install.sh"
            "mtproto-proxy"
            "MTG_SECRET"
        )
        for kw in "${mtproto_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            fi
        done
        log "Telegram MTProto 代理拦截规则已生效"
    fi

    # ========================== 9. 屏蔽代理面板安装与分发 (Anti-ProxyPanel) ==========================
    if [[ "$enable_proxypanel" == "true" ]]; then
        info "正在加载【代理面板拦截】规则 (x-ui / 3x-ui / s-ui / v2-ui)..."
        local panel_keywords=(
            "vaxilu/x-ui"
            "MHSanaei/3x-ui"
            "FranzKafkaYu/x-ui"
            "alireza0/s-ui"
            "sprov0/v2-ui"
            "x-ui/releases/download"
            "3x-ui/releases/download"
            "s-ui/releases/download"
            "x-ui-linux"
            "s-ui-linux"
        )
        for kw in "${panel_keywords[@]}"; do
            iptables -A "$CHAIN_V4" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            if has_ipv6; then
                ip6tables -A "$CHAIN_V6" -m string --string "$kw" --algo bm --to 1500 -j DROP 2>/dev/null || true
            fi
        done
        log "代理面板 (x-ui/3x-ui/s-ui) 拦截规则已生效"
    fi

    # ========================== 10. 激活秒级违规进程查杀守护与容器工作区锁 ==========================
    apply_antidd_daemon "$enable_antidd" "$enable_mtproto" "$enable_proxypanel"
    apply_container_traps "$enable_antidd" "$enable_mtproto" "$enable_proxypanel"

    # ========================== 11. 链尾部安全放行 ==========================
    # 任何未被违规特征命中的正常流量，安全返回系统常规转发链
    iptables -A "$CHAIN_V4" -j RETURN
    if has_ipv6; then
        ip6tables -A "$CHAIN_V6" -j RETURN
    fi

    # ========================== 12. 挂载到系统内核链最前端 ==========================
    # FORWARD (覆盖所有 Incus 容器与 NAT VPS 实例流量)
    iptables -I FORWARD 1 -j "$CHAIN_V4"
    # OUTPUT (覆盖宿主机自身发起的流量)
    iptables -I OUTPUT 1 -j "$CHAIN_V4"
    # INPUT (覆盖入站非法探针)
    iptables -I INPUT 1 -j "$CHAIN_V4"

    if has_ipv6; then
        ip6tables -I FORWARD 1 -j "$CHAIN_V6"
        ip6tables -I OUTPUT 1 -j "$CHAIN_V6"
        ip6tables -I INPUT 1 -j "$CHAIN_V6"
    fi

    # ========================== 13. 开机持久化服务配置 ==========================
    setup_persistence
}

# 安装开机自愈服务
setup_persistence() {
    # 1. 将自身安装到系统全局路径
    if [[ ! -f "$INSTALL_PATH" || "$0" != "$INSTALL_PATH" ]]; then
        cp "$0" "$INSTALL_PATH" 2>/dev/null || true
        chmod +x "$INSTALL_PATH" 2>/dev/null || true
    fi

    # 2. 写入 systemd 自愈服务
    cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=Incudal RFW Abuse Shield (Speedtest, Mining and BT Blocker)
After=network.target incus.service docker.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rfw-abuse start --silent
ExecStop=/usr/local/bin/rfw-abuse stop --silent
ExecReload=/usr/local/bin/rfw-abuse start --silent

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable rfw-abuse.service >/dev/null 2>&1 || true

    # 3. 兼容已有的 incus-network-compat.sh（若存在）
    local compat_script="/usr/local/bin/incus-network-compat.sh"
    if [[ -f "$compat_script" ]] && ! grep -q "rfw-abuse" "$compat_script"; then
        echo "" >> "$compat_script"
        echo "# 保持 RFW 防滥用规则在网络重启后优先挂载" >> "$compat_script"
        echo "command -v /usr/local/bin/rfw-abuse >/dev/null 2>&1 && /usr/local/bin/rfw-abuse start --silent || true" >> "$compat_script"
    fi
}

# 查看拦截统计状态
show_status() {
    echo ""
    divider
    echo -e "  ${BOLD}RFW 防滥用防火墙状态与拦截统计${NC}"
    divider
    echo ""

    if ! iptables -L "$CHAIN_V4" -n >/dev/null 2>&1; then
        warn "当前系统未启用 RFW 防滥用规则 (链 $CHAIN_V4 不存在)"
        return 0
    fi

    echo -e "  ${GREEN}● 规则链运行正常${NC} (开机守护: $(systemctl is-active rfw-abuse.service 2>/dev/null || echo "未激活"))"
    echo ""
    echo -e "  ${BOLD}IPv4 拦截规则明细 (前 15 项活跃计数)：${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
    iptables -L "$CHAIN_V4" -v -n --line-numbers | head -n 25
    echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"

    if has_ipv6 && ip6tables -L "$CHAIN_V6" -n >/dev/null 2>&1; then
        echo ""
        echo -e "  ${BOLD}IPv6 拦截规则明细 (前 10 项活跃计数)：${NC}"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
        ip6tables -L "$CHAIN_V6" -v -n --line-numbers | head -n 15
        echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
    fi
    echo ""
}

# 卸载功能
uninstall() {
    info "正在卸载 RFW 防滥用防火墙..."
    systemctl stop rfw-abuse.service 2>/dev/null || true
    systemctl disable rfw-abuse.service 2>/dev/null || true
    rm -f "$SERVICE_PATH" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    clean_rules
    rm -f "$INSTALL_PATH" 2>/dev/null || true

    # 从 incus-network-compat.sh 移除调用
    if [[ -f "/usr/local/bin/incus-network-compat.sh" ]]; then
        sed -i '/rfw-abuse/d' /usr/local/bin/incus-network-compat.sh 2>/dev/null || true
    fi

    log "RFW 防滥用防火墙已彻底卸载并还原系统网络！"
}

# 兼容管道执行时的控制台输入读取
safe_read() {
    local prompt="$1"
    local var_name="$2"
    echo -ne "$prompt"
    if [ -t 0 ]; then
        read -r "$var_name" || true
    elif [ -c /dev/tty ]; then
        read -r "$var_name" </dev/tty 2>/dev/null || true
    else
        read -r "$var_name" || true
    fi
}

# 交互式菜单
show_menu() {
    clear
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}       ${BOLD}Incudal - RFW 防滥用防火墙 (Abuse Shield) v${SCRIPT_VERSION}${NC}        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${DIM}拦截违规测速 / 恶意挖矿 / BT下载 / 跑分压测 / DD重装 / MTProto / 代理面板 · 保护母机与NAT VPS${NC}  ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local current_status="${RED}未运行${NC}"
    if iptables -L "$CHAIN_V4" -n >/dev/null 2>&1; then
        current_status="${GREEN}运行中 (已防护)${NC}"
    fi
    echo -e "  当前状态: ${current_status}"
    echo ""
    divider
    echo -e "  ${BOLD}请选择操作：${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  一键开启全量防护  ${DIM}─  屏蔽 测速 + 挖矿 + BT/P2P + 跑分压测 + DD重装 + MTProto代理 + 代理面板(x-ui/3x-ui/s-ui) (强烈推荐)${NC}"
    echo -e "    ${CYAN}2)${NC}  自定义选择防护项  ${DIM}─  自由勾选开启测速、挖矿、BT、跑分、DD重装、MTProto或代理面板${NC}"
    echo -e "    ${CYAN}3)${NC}  查看拦截统计状态  ${DIM}─  查看实时命中数据包与流量${NC}"
    echo -e "    ${YELLOW}4)${NC}  停止防护 (清除规则) ${DIM}─  临时停用拦截，保留自愈脚本${NC}"
    echo -e "    ${RED}5)${NC}  彻底卸载          ${DIM}─  移除守护服务与防火墙脚本${NC}"
    echo -e "    ${DIM}0)  返回上级菜单（从 incudal 进入时返回主菜单）${NC}"
    echo ""
    local choice=""
    safe_read "  ${BOLD}请输入选项 [0-5]: ${NC}" choice

    case "$choice" in
        1)
            echo ""
            apply_rules "true" "true" "true" "true" "true" "true" "true"
            echo ""
            log "全量防护已成功开启并配置开机自愈！"
            ;;
        2)
            echo ""
            echo -e "  ${DIM}以下每一步输入 0 可返回上级菜单${NC}"
            local opt_speed="" opt_mine="" opt_bt="" opt_bench="" opt_dd="" opt_mtproto="" opt_proxypanel=""
            safe_read "  是否屏蔽测速 (Speedtest/iPerf/Fast)？[Y/n]: " opt_speed
            [[ "$opt_speed" == "0" ]] && return 0
            local b_speed="true"
            [[ "${opt_speed:-Y}" =~ ^[nN]$ ]] && b_speed="false"

            safe_read "  是否屏蔽挖矿 (Stratum/常见矿池/XMRig)？[Y/n]: " opt_mine
            [[ "$opt_mine" == "0" ]] && return 0
            local b_mine="true"
            [[ "${opt_mine:-Y}" =~ ^[nN]$ ]] && b_mine="false"

            safe_read "  是否屏蔽BT/P2P下载 (BitTorrent/DHT/迅雷)？[Y/n]: " opt_bt
            [[ "$opt_bt" == "0" ]] && return 0
            local b_bt="true"
            [[ "${opt_bt:-Y}" =~ ^[nN]$ ]] && b_bt="false"

            safe_read "  是否屏蔽性能跑分/压测 (Geekbench/YABS/SuperBench/UnixBench)？[Y/n]: " opt_bench
            [[ "$opt_bench" == "0" ]] && return 0
            local b_bench="true"
            [[ "${opt_bench:-Y}" =~ ^[nN]$ ]] && b_bench="false"

            safe_read "  是否屏蔽系统重装与DD脚本 (reinstall.sh/InstallNET/OsMutation)？[Y/n]: " opt_dd
            [[ "$opt_dd" == "0" ]] && return 0
            local b_dd="true"
            [[ "${opt_dd:-Y}" =~ ^[nN]$ ]] && b_dd="false"

            safe_read "  是否屏蔽Telegram MTProto代理服务 (MTG/mtproto-proxy/防被墙)？[Y/n]: " opt_mtproto
            [[ "$opt_mtproto" == "0" ]] && return 0
            local b_mtproto="true"
            [[ "${opt_mtproto:-Y}" =~ ^[nN]$ ]] && b_mtproto="false"

            safe_read "  是否屏蔽代理面板服务 (x-ui/3x-ui/s-ui/v2-ui/防封禁)？[Y/n]: " opt_proxypanel
            [[ "$opt_proxypanel" == "0" ]] && return 0
            local b_proxypanel="true"
            [[ "${opt_proxypanel:-Y}" =~ ^[nN]$ ]] && b_proxypanel="false"

            echo ""
            apply_rules "$b_speed" "$b_mine" "$b_bt" "$b_bench" "$b_dd" "$b_mtproto" "$b_proxypanel"
            echo ""
            log "自定义防护规则已成功应用！"
            ;;
        3)
            show_status
            ;;
        4)
            clean_rules
            log "防护规则已停止并清除！"
            ;;
        5)
            uninstall
            ;;
        0|*)
            exit 0
            ;;
    esac
}

# 主入口解析
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "用法: $0 [start|stop|status|uninstall|--all|--speedtest-only|--mining-only|--bt-only|--benchmark-only|--antidd-only|--mtproto-only|--proxypanel-only]"
    exit 0
fi

check_root

case "${1:-}" in
    start|apply|enable)
        if [[ "${2:-}" == "--silent" ]]; then
            apply_rules "true" "true" "true" "true" "true" "true" "true" >/dev/null 2>&1
        else
            echo ""
            apply_rules "true" "true" "true" "true" "true" "true" "true"
            echo ""
            log "RFW 防滥用规则（测速/挖矿/BT/性能跑分/DD重装/MTProto/代理面板）已成功启动！"
        fi
        ;;
    stop|clear|disable)
        if [[ "${2:-}" == "--silent" ]]; then
            clean_rules >/dev/null 2>&1
        else
            clean_rules
        fi
        ;;
    status)
        show_status
        ;;
    uninstall)
        uninstall
        ;;
    --all)
        apply_rules "true" "true" "true" "true" "true" "true" "true"
        ;;
    --speedtest-only)
        apply_rules "true" "false" "false" "false" "false" "false" "false"
        ;;
    --mining-only)
        apply_rules "false" "true" "false" "false" "false" "false" "false"
        ;;
    --bt-only)
        apply_rules "false" "false" "true" "false" "false" "false" "false"
        ;;
    --benchmark-only|--bench-only)
        apply_rules "false" "false" "false" "true" "false" "false" "false"
        ;;
    --antidd-only|--anti-dd-only)
        apply_rules "false" "false" "false" "false" "true" "false" "false"
        ;;
    --mtproto-only|--anti-mtproto-only)
        apply_rules "false" "false" "false" "false" "false" "true" "false"
        ;;
    --proxypanel-only|--panel-only|--anti-panel-only)
        apply_rules "false" "false" "false" "false" "false" "false" "true"
        ;;
    --help|-h)
        echo "用法: $0 [start|stop|status|uninstall|--all|--speedtest-only|--mining-only|--bt-only|--benchmark-only|--antidd-only|--mtproto-only|--proxypanel-only]"
        exit 0
        ;;
    *)
        # 无参执行默认进入菜单
        show_menu
        ;;
esac
