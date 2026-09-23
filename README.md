# Incudal - Node Management & Installation Scripts

Incudal 宿主机节点自动化安装与防滥用管理脚本。

## 快速安装节点

### 交互式安装向导（推荐）
```bash
curl -sSL https://raw.githubusercontent.com/ceocok/incudal/main/server/templates/install.sh | sudo bash
```

### 快捷管理命令（安装后可用）
```bash
incudal
```

### 常用选项
```bash
# 仅 IPv4 安装
sudo bash install.sh --mode nat --token <YOUR_TOKEN>

# 一键安装 RFW 母鸡防火墙
sudo bash install.sh --rfw

# RFW 防滥用 (屏蔽测速/挖矿/BT/DD系统)
sudo bash /usr/local/bin/rfw-abuse

# 节点网络自愈与体检
sudo bash install.sh --repair

# 更新管理脚本与 incudal 快捷命令
sudo bash install.sh --update-script
```

## 功能特性
- **Incus 自动化部署**：支持 Debian / Ubuntu 物理机与 VPS 快速部署。
- **双栈网络与 NAT**：内置 IPv4 NAT 与原生/路由 IPv6 支持。
- **RFW 防火墙与防滥用 (Abuse Shield)**：
  - 屏蔽违规测速 (Speedtest / iPerf)
  - 屏蔽恶意挖矿 (Stratum / XMRig / 常用矿池)
  - 屏蔽 BT / PT / P2P 下载 (BitTorrent / DHT / 迅雷)
  - 屏蔽性能跑分与压测 (Geekbench / YABS / LemonBench)
  - **禁止 LXC 容器 DD 重装系统 (Anti-DD Shield)**
- **网络自愈与 Docker/UFW 兼容**：自动对齐 MTU、DNS 转发并放行网桥。
