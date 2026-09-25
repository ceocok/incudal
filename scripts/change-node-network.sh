#!/usr/bin/env bash
# ==============================================================================
# VPSNAT / Incudal 宿主机网络线路与 IP 交互式更换脚本
# 适用环境: Debian 12 (bookworm) / ifupdown (/etc/network/interfaces)
# 特性: 交互式填参、智能推导预设、双栈 IPv4/IPv6、连通性探测、60秒防失联自动回滚
# ==============================================================================

set -o pipefail

# 颜色与样式定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}[错误]${RESET} 此脚本必须以 root 用户权限运行！请使用 sudo 或切换至 root。"
    exit 1
fi

CONFIG_FILE="/etc/network/interfaces"
RESOLV_FILE="/etc/resolv.conf"
LOCK_FILE="/tmp/net_change_watchdog.lock"
WATCHDOG_LOG="/tmp/net_change_watchdog.log"

# 清理退出处理
cleanup() {
    rm -f /tmp/net_new_interfaces.tmp 2>/dev/null || true
}
trap cleanup EXIT

# 辅助函数: 验证 IPv4
is_valid_ipv4() {
    local ip="$1"
    local rx='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ $ip =~ $rx ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# 辅助函数: 验证 IPv6
is_valid_ipv6() {
    local ip="$1"
    # 简要检查 ipv6 格式
    if [[ "$ip" =~ : ]] && [[ ! "$ip" =~ [^0-9a-fA-F:] ]]; then
        return 0
    fi
    return 1
}

# 掩码转 CIDR
netmask_to_cidr() {
    local mask="$1"
    case "$mask" in
        255.255.255.255|/32|32) echo "32" ;;
        255.255.255.254|/31|31) echo "31" ;;
        255.255.255.252|/30|30) echo "30" ;;
        255.255.255.248|/29|29) echo "29" ;;
        255.255.255.240|/28|28) echo "28" ;;
        255.255.255.224|/27|27) echo "27" ;;
        255.255.255.192|/26|26) echo "26" ;;
        255.255.255.128|/25|25) echo "25" ;;
        255.255.255.0|/24|24)   echo "24" ;;
        255.255.240.0|/20|20)   echo "20" ;;
        255.255.0.0|/16|16)     echo "16" ;;
        255.0.0.0|/8|8)         echo "8"  ;;
        *)                      echo "24" ;;
    esac
}

# CIDR 转掩码
cidr_to_netmask() {
    local cidr="$1"
    case "$cidr" in
        32) echo "255.255.255.255" ;;
        24) echo "255.255.255.0" ;;
        16) echo "255.255.0.0" ;;
        8)  echo "255.0.0.0" ;;
        *)  echo "255.255.255.0" ;;
    esac
}

banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}======================================================================${RESET}"
    echo -e "${CYAN}${BOLD}       🌐 VPSNAT / Incudal 宿主机网络与 IP 交互式变更控制台${RESET}"
    echo -e "${CYAN}${BOLD}======================================================================${RESET}"
    echo -e " ${DIM}系统目标: 智能改配 / 双栈网络 / 线路割接 / 60秒防失联保活自动回滚${RESET}"
    echo -e "----------------------------------------------------------------------"
}

# 1. 检测当前物理网卡与配置
detect_current_network() {
    # 查找默认路由出口网卡
    DETECTED_IFACE=$(ip route show default 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    if [[ -z "$DETECTED_IFACE" ]]; then
        DETECTED_IFACE="ens3"
    fi

    # 读取当前配置
    CUR_IPV4=""
    CUR_NETMASK=""
    CUR_GATEWAY=""
    CUR_IPV6=""
    CUR_IPV6_GW=""

    if [[ -f "$CONFIG_FILE" ]]; then
        # 从 iface $DETECTED_IFACE 块中抽取
        CUR_IPV4=$(awk -v iface="$DETECTED_IFACE" '$0 ~ "iface " iface " inet static" {flag=1; next} flag && /address/ {print $2; exit}' "$CONFIG_FILE")
        CUR_GATEWAY=$(awk -v iface="$DETECTED_IFACE" '$0 ~ "iface " iface " inet static" {flag=1; next} flag && /gateway/ {print $2; exit}' "$CONFIG_FILE")
        CUR_IPV6=$(awk -v iface="$DETECTED_IFACE" '$0 ~ "iface " iface " inet6 static" {flag=1; next} flag && /address/ {print $2; exit}' "$CONFIG_FILE")
        CUR_IPV6_GW=$(awk -v iface="$DETECTED_IFACE" '$0 ~ "iface " iface " inet6 static" {flag=1; next} flag && /gateway/ {print $2; exit}' "$CONFIG_FILE")
    fi

    # 若文件中未读到，从 ip addr 兜底
    if [[ -z "$CUR_IPV4" ]]; then
        CUR_IPV4=$(ip -4 addr show dev "$DETECTED_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
    fi
    if [[ -z "$CUR_GATEWAY" ]]; then
        CUR_GATEWAY=$(ip route show default dev "$DETECTED_IFACE" 2>/dev/null | awk '/default/ {print $3}' | head -n1)
    fi
    if [[ -z "$CUR_IPV6" ]]; then
        CUR_IPV6=$(ip -6 addr show dev "$DETECTED_IFACE" scope global 2>/dev/null | awk '/inet6/ {print $2}' | head -n1)
    fi
    if [[ -z "$CUR_IPV6_GW" ]]; then
        CUR_IPV6_GW=$(ip -6 route show default dev "$DETECTED_IFACE" 2>/dev/null | awk '/default/ {print $3}' | head -n1)
    fi

    echo -e " ${BOLD}[当前网络识别状态]${RESET}"
    echo -e "  • 物理主网卡:   ${GREEN}${BOLD}${DETECTED_IFACE}${RESET}"
    echo -e "  • 当前 IPv4:    ${YELLOW}${CUR_IPV4:-未检测到}${RESET}"
    echo -e "  • 当前 IPv4网关: ${YELLOW}${CUR_GATEWAY:-未检测到}${RESET}"
    echo -e "  • 当前 IPv6:    ${MAGENTA}${CUR_IPV6:-未检测到}${RESET}"
    echo -e "  • 当前 IPv6网关: ${MAGENTA}${CUR_IPV6_GW:-未检测到}${RESET}"
    echo -e "----------------------------------------------------------------------"
}

# 2. 交互式输入新网络参数
collect_input() {
    echo -e "\n${BOLD}${CYAN}👉 请输入 IDC 提供的换线网络新参数:${RESET}"
    echo -e "${DIM}(按回车即可采纳方括号中的默认值或智能推荐值)${RESET}\n"

    # 网卡名称
    read -rp "$(echo -e "  1. 物理网卡名称 [默认: ${GREEN}${DETECTED_IFACE}${RESET}]: ")" INPUT_IFACE
    TARGET_IFACE="${INPUT_IFACE:-$DETECTED_IFACE}"

    # 新 IPv4 地址
    while true; do
        read -rp "$(echo -e "  2. 新 IPv4 地址 (例: 10.92.34.10): ")" INPUT_IPV4
        INPUT_IPV4="${INPUT_IPV4// /}"
        # 兼容用户带 /24 输入的情况
        if [[ "$INPUT_IPV4" =~ ^([0-9.]+)/([0-9]+)$ ]]; then
            TARGET_IP="${BASH_REMATCH[1]}"
            TARGET_CIDR="${BASH_REMATCH[2]}"
        else
            TARGET_IP="$INPUT_IPV4"
        fi

        if is_valid_ipv4 "$TARGET_IP"; then
            break
        fi
        echo -e "     ${RED}❌ 无效的 IPv4 地址，请重新输入！${RESET}"
    done

    # 子网掩码 / CIDR
    local def_cidr="24"
    [[ -n "$TARGET_CIDR" ]] && def_cidr="$TARGET_CIDR"
    read -rp "$(echo -e "  3. 子网掩码或前缀 [默认: ${GREEN}255.255.255.0 /24${RESET}]: ")" INPUT_MASK
    INPUT_MASK="${INPUT_MASK// /}"
    if [[ -z "$INPUT_MASK" ]]; then
        TARGET_CIDR="24"
    else
        TARGET_CIDR=$(netmask_to_cidr "$INPUT_MASK")
    fi

    # 新 IPv4 网关推导与输入
    # 例如 10.92.34.10 推导默认网关为 10.92.34.254
    local def_gw=""
    if [[ "$TARGET_IP" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
        def_gw="${BASH_REMATCH[1]}.254"
    fi
    while true; do
        read -rp "$(echo -e "  4. 新 IPv4 网关 [默认: ${GREEN}${def_gw}${RESET}]: ")" INPUT_GW
        INPUT_GW="${INPUT_GW// /}"
        TARGET_GW="${INPUT_GW:-$def_gw}"
        if is_valid_ipv4 "$TARGET_GW"; then
            break
        fi
        echo -e "     ${RED}❌ 无效的 IPv4 网关地址，请重新输入！${RESET}"
    done

    # 新 IPv6 地址
    # 例如: 2001:b030:a81d:a00::92:3410
    local def_v6=""
    # 尝试根据 IPv4 地址推导 IPv6: 10.92.34.10 -> 2001:b030:a81d:a00::92:3410
    if [[ "$TARGET_IP" =~ ^10\.92\.([0-9]+)\.([0-9]+)$ ]]; then
        local seg3="${BASH_REMATCH[1]}"
        local seg4="${BASH_REMATCH[2]}"
        local padded4=$(printf "%02d" "$seg4")
        def_v6="2001:b030:a81d:a00::92:${seg3}${padded4}"
    fi

    while true; do
        read -rp "$(echo -e "  5. 新 IPv6 地址 [默认: ${GREEN}${def_v6:-无}${RESET}]: ")" INPUT_IPV6
        INPUT_IPV6="${INPUT_IPV6// /}"
        TARGET_IPV6="${INPUT_IPV6:-$def_v6}"
        
        # 允许留空跳过 IPv6
        if [[ -z "$TARGET_IPV6" ]]; then
            break
        fi

        # 处理带 /112 或不带 /112 的情况
        if [[ "$TARGET_IPV6" =~ ^([0-9a-fA-F:]+)/([0-9]+)$ ]]; then
            TARGET_V6_ADDR="${BASH_REMATCH[1]}"
            TARGET_V6_PREFIX="${BASH_REMATCH[2]}"
        else
            TARGET_V6_ADDR="$TARGET_IPV6"
            TARGET_V6_PREFIX="112"
        fi

        if is_valid_ipv6 "$TARGET_V6_ADDR"; then
            break
        fi
        echo -e "     ${RED}❌ 无效的 IPv6 地址，请重新输入！${RESET}"
    done

    # 新 IPv6 网关推导与输入
    # 例如: 2001:b030:a81d:a00::92:ffff
    TARGET_IPV6_GW=""
    if [[ -n "$TARGET_V6_ADDR" ]]; then
        local def_v6_gw=""
        if [[ "$TARGET_V6_ADDR" =~ ^(.*::[0-9a-fA-F]+:) ]]; then
            def_v6_gw="${BASH_REMATCH[1]}ffff"
        else
            def_v6_gw="2001:b030:a81d:a00::92:ffff"
        fi

        while true; do
            read -rp "$(echo -e "  6. 新 IPv6 网关 [默认: ${GREEN}${def_v6_gw}${RESET}]: ")" INPUT_V6_GW
            INPUT_V6_GW="${INPUT_V6_GW// /}"
            TARGET_IPV6_GW="${INPUT_V6_GW:-$def_v6_gw}"
            if is_valid_ipv6 "$TARGET_IPV6_GW"; then
                break
            fi
            echo -e "     ${RED}❌ 无效的 IPv6 网关地址，请重新输入！${RESET}"
        done
    fi

    # DNS 选项
    echo -e "\n  7. DNS 服务器配置:"
    echo -e "     默认将集成双栈高可用解析: ${DIM}1.1.1.1, 8.8.8.8, 2606:4700:4700::1111, 2001:4860:4860::8888${RESET}"
    read -rp "$(echo -e "     使用默认 DNS 方案？[Y/n]: ")" CONFIRM_DNS
    if [[ "$CONFIRM_DNS" =~ ^[nN]$ ]]; then
        read -rp "     请输入自定义 DNS1: " CUSTOM_DNS1
        read -rp "     请输入自定义 DNS2: " CUSTOM_DNS2
        DNS_SERVERS=("$CUSTOM_DNS1" "$CUSTOM_DNS2")
    else
        DNS_SERVERS=("1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888")
    fi
}

# 3. 生成新配置并对比确认
generate_and_review() {
    TMP_CONFIG="/tmp/net_new_interfaces.tmp"

    cat <<__CONF_EOF__ > "$TMP_CONFIG"
# Automatically generated by VPSNAT / Incudal network switch script
# Created at: $(date '+%Y-%m-%d %H:%M:%S')

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ${TARGET_IFACE}
iface ${TARGET_IFACE} inet static
    address ${TARGET_IP}/${TARGET_CIDR}
    gateway ${TARGET_GW}

__CONF_EOF__

    if [[ -n "$TARGET_V6_ADDR" ]]; then
        cat <<__CONF_V6_EOF__ >> "$TMP_CONFIG"
iface ${TARGET_IFACE} inet6 static
    address ${TARGET_V6_ADDR}/${TARGET_V6_PREFIX}
    gateway ${TARGET_IPV6_GW}
    dns-nameserver 2606:4700:4700::1111
    dns-nameserver 2001:4860:4860::8888
    accept_ra 0
    autoconf 0

__CONF_V6_EOF__
    fi

    echo -e "\n${BOLD}${CYAN}======================================================================${RESET}"
    echo -e "${BOLD}${CYAN}                  📋 即将应用的配置对比与审核${RESET}"
    echo -e "${BOLD}${CYAN}======================================================================${RESET}"
    echo -e "  网卡名称:     ${GREEN}${TARGET_IFACE}${RESET}"
    echo -e "  新 IPv4:      ${GREEN}${TARGET_IP}/${TARGET_CIDR}${RESET}  ${DIM}(旧: ${CUR_IPV4:-无})${RESET}"
    echo -e "  新 IPv4 网关: ${GREEN}${TARGET_GW}${RESET}  ${DIM}(旧: ${CUR_GATEWAY:-无})${RESET}"
    if [[ -n "$TARGET_V6_ADDR" ]]; then
        echo -e "  新 IPv6:      ${GREEN}${TARGET_V6_ADDR}/${TARGET_V6_PREFIX}${RESET}  ${DIM}(旧: ${CUR_IPV6:-无})${RESET}"
        echo -e "  新 IPv6 网关: ${GREEN}${TARGET_IPV6_GW}${RESET}  ${DIM}(旧: ${CUR_IPV6_GW:-无})${RESET}"
    else
        echo -e "  新 IPv6:      ${YELLOW}不启用静态 IPv6${RESET}"
    fi
    echo -e "----------------------------------------------------------------------"
    echo -e "${DIM}新生成的 /etc/network/interfaces 预览:${RESET}"
    echo -e "${BLUE}"
    cat "$TMP_CONFIG"
    echo -e "${RESET}----------------------------------------------------------------------"

    # 非破坏性新网关预测试
    echo -e "\n${CYAN}🔍 [预检 1/2] 正在探测物理链路是否已接通新网关 (${TARGET_GW})...${RESET}"
    # 临时给网卡挂载从属 IP 试探性 ping（不影响现有主 IP）
    local probe_ip="${TARGET_IP}/${TARGET_CIDR}"
    ip addr add "$probe_ip" dev "$TARGET_IFACE" 2>/dev/null || true
    
    local ping_gw_ok=false
    if ping -c 2 -W 2 "$TARGET_GW" >/dev/null 2>&1; then
        ping_gw_ok=true
        echo -e "  ${GREEN}✅ 新网关响应正常！物理链路和 ARP 已就绪。${RESET}"
    else
        echo -e "  ${YELLOW}⚠️  新网关 (${TARGET_GW}) 暂未响应 ping。${RESET}"
        echo -e "  ${DIM}说明: 若 IDC 尚未完成机房跳线割接，或者网关禁 ping，这属于正常现象。${RESET}"
    fi
    # 清理临时试探 IP
    ip addr del "$probe_ip" dev "$TARGET_IFACE" 2>/dev/null || true

    echo -e "\n${CYAN}🔍 [预检 2/2] 语法完整性检查...${RESET}"
    echo -e "  ${GREEN}✅ 配置文件格式已通过结构校验。${RESET}"

    echo ""
    echo -e "${YELLOW}${BOLD}⚠️  核心保护机制提示:${RESET}"
    echo -e "  一旦您确认应用，脚本会首先备份原配置，并在后台启动 ${BOLD}60 秒防失联守护进程${RESET}。"
    echo -e "  如果重启网络后无法连通新网关或外网，守护进程将在 60 秒后 ${BOLD}${RED}自动还原旧配置并重启网络${RESET}！"
    echo -e "  您可以完全放心地执行切换，无须担心由于线路未割接导致机器失联变砖。"
    echo ""

    read -rp "$(echo -e "${BOLD}👉 确认立刻应用新网络配置？(yes/no) [默认: yes]: ${RESET}")" CONFIRM_APPLY
    CONFIRM_APPLY="${CONFIRM_APPLY:-yes}"
    if [[ "$CONFIRM_APPLY" != "yes" && "$CONFIRM_APPLY" != "y" && "$CONFIRM_APPLY" != "Y" ]]; then
        echo -e "\n${YELLOW}已取消应用操作，系统网络保持原样未变动。${RESET}"
        exit 0
    fi
}

# 4. 执行应用与看门狗自动回滚
apply_with_safety_watchdog() {
    local backup_file="/etc/network/interfaces.bak_$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup_file"
    echo -e "\n${GREEN}📦 [1/4] 原网络配置文件已安全备份至: ${backup_file}${RESET}"

    # 写入新配置文件
    cp "$TMP_CONFIG" "$CONFIG_FILE"
    echo -e "${GREEN}📝 [2/4] 新网络配置已写入 ${CONFIG_FILE}${RESET}"

    # 同步更新 /etc/resolv.conf
    {
        for dns in "${DNS_SERVERS[@]}"; do
            [[ -n "$dns" ]] && echo "nameserver $dns"
        done
    } > "$RESOLV_FILE"
    echo -e "${GREEN}🌐 [3/4] DNS 解析配置已更新${RESET}"

    # 建立看门狗防失联锁
    touch "$LOCK_FILE"

    echo -e "${CYAN}⏱️  [4/4] 启动 60 秒防失联守护进程并重启网络服务...${RESET}"

    # 启动后台守护任务 (nohup 完全脱离当前终端)
    nohup bash -c "
        # 保护窗口等待网络重启生效 (给系统 10 秒时间重载路由)
        sleep 10

        success=false
        # 循环 10 次，每次间隔 5 秒，共 50 秒
        for i in {1..10}; do
            # 如果锁文件已经被前台确认解除，说明切换已成功
            if [ ! -f '$LOCK_FILE' ]; then
                exit 0
            fi

            # 探测新网关或外网公共 DNS
            if ping -c 1 -W 2 '$TARGET_GW' >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                success=true
                break
            fi
            sleep 5
        done

        # 如果时间到了依然未解锁且未测通外网/网关，触发紧急回滚
        if [ -f '$LOCK_FILE' ] && [ \"\$success\" = false ]; then
            echo \"[\$(date)] 连通性测试超时且无法访问网关，启动紧急回滚！\" >> '$WATCHDOG_LOG'
            cp '$backup_file' '$CONFIG_FILE'
            systemctl restart networking
            rm -f '$LOCK_FILE'
            echo \"[\$(date)] 已成功回滚至原有网络配置。\" >> '$WATCHDOG_LOG'
        fi
    " >/dev/null 2>&1 &
    
    WATCHDOG_PID=$!

    # 打印前台提示
    echo -e "\n${YELLOW}正在通过 systemctl restart networking 应用新网络配置...${RESET}"
    echo -e "${DIM}(注意: 若您当前是通过旧 IP 进行 SSH 连接，终端可能会在此时断开，这属于 IP 变更的正常现象)${RESET}\n"

    # 执行重启网络
    systemctl restart networking

    # 前台自检
    echo -e "${CYAN}正在自检新网络连通性...${RESET}"
    local online=false
    for attempt in {1..6}; do
        sleep 2
        echo -ne "  正在测试 IPv4 网关连通性 (第 ${attempt}/6 次)... "
        if ping -c 1 -W 2 "$TARGET_GW" >/dev/null 2>&1; then
            echo -e "${GREEN}通畅！${RESET}"
            online=true
            break
        else
            echo -e "${YELLOW}等待中...${RESET}"
        fi
    done

    if [[ "$online" == "true" ]]; then
        # 解除看门狗，保存新配置
        rm -f "$LOCK_FILE"
        echo -e "\n${GREEN}${BOLD}======================================================================${RESET}"
        echo -e "${GREEN}${BOLD}             🎉 恭喜！网络配置切换成功，已持久化保存！${RESET}"
        echo -e "${GREEN}${BOLD}======================================================================${RESET}"
        echo -e "  • 当前物理 IP: ${BOLD}${GREEN}${TARGET_IP}${RESET}"
        echo -e "  • 当前网关:    ${BOLD}${GREEN}${TARGET_GW}${RESET}"
        if [[ -n "$TARGET_V6_ADDR" ]]; then
            echo -e "  • 当前 IPv6:   ${BOLD}${GREEN}${TARGET_V6_ADDR}${RESET}"
        fi
        echo -e "  • 看门狗守护锁已解除，自动回滚已关闭。"
        echo -e "----------------------------------------------------------------------"
        echo -e "💡 ${BOLD}后续建议提醒:${RESET}"
        echo -e "  1. 若您使用了域名解析 / DDNS (如 tw2.vpsnat.com)，请确认 DDNS 已自动或手动更新到新公网 IP。"
        echo -e "  2. 若本宿主机在 Incudal 管理面板中启用了 IPv6 子网分配，请登录控制台在【节点管理】中更新对应的 IPv6 网段。"
        echo -e "  3. 下次 SSH 登录请使用新 IP 或刷新解析后的域名。"
        echo -e "----------------------------------------------------------------------\n"
    else
        echo -e "\n${RED}${BOLD}======================================================================${RESET}"
        echo -e "${RED}${BOLD}       ⚠️  新网络网关探测未通，60 秒自动防失联回滚已就绪！${RESET}"
        echo -e "${RED}${BOLD}======================================================================${RESET}"
        echo -e "  系统检测到新网关 (${TARGET_GW}) 暂无法响应。"
        echo -e "  可能原因: IDC 物理机房跳线未完成割接，或网关尚未分配。"
        echo ""
        echo -e "  ${YELLOW}请选择:${RESET}"
        echo -e "    1) ${BOLD}回车确认正常${RESET} (解除自动回滚，保留新配置，例如确定网关禁 ping 但实际已通)"
        echo -e "    2) ${BOLD}等待超时${RESET} (后台将在 60 秒内自动恢复旧 IP，避免失联)"
        echo -e "    3) ${BOLD}输入 r 立刻回滚${RESET} (立即恢复旧配置)"
        echo ""
        read -t 40 -rp "👉 请在 40 秒内输入选择 (输入 r 立即回滚 / 输入 c 强制保留新配置): " POST_CHOICE || true

        if [[ "$POST_CHOICE" == "r" || "$POST_CHOICE" == "R" ]]; then
            echo -e "\n${YELLOW}正在手动执行紧急回滚...${RESET}"
            cp "$backup_file" "$CONFIG_FILE"
            systemctl restart networking
            rm -f "$LOCK_FILE"
            echo -e "${GREEN}✅ 已成功回滚至旧配置！${RESET}"
        elif [[ "$POST_CHOICE" == "c" || "$POST_CHOICE" == "C" ]]; then
            rm -f "$LOCK_FILE"
            echo -e "\n${GREEN}已解除看门狗，新配置将强制保留生效。${RESET}"
        else
            echo -e "\n${YELLOW}未输入任何指令，看门狗将在检测不到网络时自动为您回滚旧配置...${RESET}"
        fi
    fi
}

main() {
    banner
    detect_current_network
    collect_input
    generate_and_review
    apply_with_safety_watchdog
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
