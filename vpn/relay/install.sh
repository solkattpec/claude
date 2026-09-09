#!/usr/bin/env bash
# 中转机安装脚本：nftables 端口直通转发（DNAT + masquerade）
#
# 中转机只做内核态 TCP 转发，不解密、不落盘任何流量。
# 加密从你的 Mac 一路端到端到落地机。
#
# 用法（在中转机上以 root 执行）：
#   LANDING_IP=5.6.7.8 bash install.sh
#
# 可选环境变量：
#   RELAY_PORT=443      中转机对外监听端口（客户端连这个）
#   LANDING_PORT=443    落地机 sing-box 的端口
set -euo pipefail

LANDING_IP="${LANDING_IP:-}"
RELAY_PORT="${RELAY_PORT:-443}"
LANDING_PORT="${LANDING_PORT:-443}"

log()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -n "$LANDING_IP" ] || die "必须指定 LANDING_IP=<落地机IP>"
[[ "$LANDING_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "LANDING_IP 需要是 IPv4 地址"

# ---------- 1. 依赖 ----------
log "安装 nftables"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq nftables curl >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q nftables curl
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q nftables curl
else
  die "未识别的包管理器，请手动安装 nftables"
fi

# ---------- 2. 开启转发 ----------
log "开启 IPv4 转发 + BBR"
cat > /etc/sysctl.d/99-relay.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
EOF
sysctl -p /etc/sysctl.d/99-relay.conf >/dev/null 2>&1 || true
ok "ip_forward=$(sysctl -n net.ipv4.ip_forward)  拥塞控制=$(sysctl -n net.ipv4.tcp_congestion_control)"

# ---------- 3. 转发规则 ----------
# 用独立的 table，不动系统已有的 nftables/iptables 规则
log "写入转发规则 ${RELAY_PORT}/tcp -> ${LANDING_IP}:${LANDING_PORT}"
mkdir -p /etc/nftables.d
cat > /etc/nftables.d/relay-forward.nft <<EOF
#!/usr/sbin/nft -f
table ip relay
delete table ip relay

table ip relay {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${RELAY_PORT} dnat to ${LANDING_IP}:${LANDING_PORT}
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr ${LANDING_IP} tcp dport ${LANDING_PORT} masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        ip daddr ${LANDING_IP} tcp dport ${LANDING_PORT} accept
        ct state established,related accept
    }
}
EOF
chmod 644 /etc/nftables.d/relay-forward.nft
nft -f /etc/nftables.d/relay-forward.nft || die "nftables 规则加载失败"
ok "规则已生效"

# ---------- 4. 开机自启 ----------
log "配置开机自动加载"
cat > /etc/systemd/system/relay-forward.service <<'EOF'
[Unit]
Description=Relay port forwarding (nftables DNAT)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/relay-forward.nft
ExecStop=-/usr/sbin/nft delete table ip relay

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable relay-forward.service >/dev/null 2>&1
ok "已设为开机自启"

# ---------- 5. 放行端口 ----------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  log "放行 ufw ${RELAY_PORT}/tcp"
  ufw allow "${RELAY_PORT}/tcp" >/dev/null
  ok "已放行"
fi

# ---------- 6. 自检 ----------
if command -v iptables >/dev/null 2>&1 && iptables -S FORWARD 2>/dev/null | head -1 | grep -q -- '-P FORWARD DROP'; then
  echo "  [!] 检测到 iptables FORWARD 链默认策略是 DROP（常见于装了 Docker 的机器）。"
  echo "      转发可能被它拦掉。修复：iptables -I FORWARD -d ${LANDING_IP} -p tcp --dport ${LANDING_PORT} -j ACCEPT"
fi

RELAY_IP="$(curl -fsSL --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
log "自检：从中转机直连落地机 ${LANDING_IP}:${LANDING_PORT}"
if timeout 6 bash -c "</dev/tcp/${LANDING_IP}/${LANDING_PORT}" 2>/dev/null; then
  ok "落地机端口可达"
else
  echo "  [!] 连不上落地机端口。检查：落地机 sing-box 是否在跑、防火墙是否放行了本机 IP (${RELAY_IP})"
fi

echo
ok "中转机部署完成"
echo "────────────────────────────────────────────────────────"
echo " 中转机 IP : ${RELAY_IP}     <-- 客户端 server 填这个"
echo " 监听端口  : ${RELAY_PORT}"
echo " 转发到    : ${LANDING_IP}:${LANDING_PORT}"
echo "────────────────────────────────────────────────────────"
echo
echo "查看规则：  nft list table ip relay"
echo "查看连接：  conntrack -L 2>/dev/null | grep ${LANDING_IP}"
echo "临时停用：  systemctl stop relay-forward"
