#!/usr/bin/env bash
# 中转机备选方案：realm（用户态 TCP 转发）
#
# 什么时候用它而不是 install.sh：
#   - VPS 商家的虚拟化/内核不支持 nftables NAT（OpenVZ、部分 LXC）
#   - 落地机只有域名没有固定 IP（realm 支持域名，DNAT 不支持）
#   - 想要转发日志、或一台中转转发多个落地
#
# 用法：
#   LANDING=5.6.7.8:443 bash realm-alternative.sh
#   LANDING=landing.example.com:443 RELAY_PORT=443 bash realm-alternative.sh
set -euo pipefail

LANDING="${LANDING:-}"
RELAY_PORT="${RELAY_PORT:-443}"

log() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -n "$LANDING" ] || die "必须指定 LANDING=<落地机地址:端口>"
case "$LANDING" in *:*) ;; *) die "LANDING 格式应为 host:port" ;; esac

export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl tar jq >/dev/null; }
command -v jq   >/dev/null 2>&1 || apt-get install -y -qq jq >/dev/null

case "$(uname -m)" in
  x86_64|amd64)  RARCH=x86_64-unknown-linux-gnu ;;
  aarch64|arm64) RARCH=aarch64-unknown-linux-gnu ;;
  *) die "不支持的架构 $(uname -m)" ;;
esac

log "下载 realm"
VER="$(curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest | jq -r .tag_name)"
[ -n "$VER" ] && [ "$VER" != "null" ] || die "获取 realm 版本失败"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/zhboner/realm/releases/download/${VER}/realm-${RARCH}.tar.gz" -o "$TMP/realm.tar.gz" \
  || die "下载失败"
tar -xzf "$TMP/realm.tar.gz" -C "$TMP"
install -m 755 "$TMP/realm" /usr/local/bin/realm
ok "realm ${VER} 已安装"

log "写入配置"
mkdir -p /etc/realm
cat > /etc/realm/config.toml <<EOF
[log]
level = "warn"

[network]
no_tcp = false
use_udp = false
tcp_timeout = 300
zero_copy = true
fast_open = true

[[endpoints]]
listen = "0.0.0.0:${RELAY_PORT}"
remote = "${LANDING}"
EOF

cat > /etc/systemd/system/realm.service <<'EOF'
[Unit]
Description=realm TCP relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/sysctl.d/99-relay.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
sysctl -p /etc/sysctl.d/99-relay.conf >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable --now realm >/dev/null 2>&1
sleep 2
systemctl is-active --quiet realm || { journalctl -u realm -n 30 --no-pager; die "realm 启动失败"; }

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${RELAY_PORT}/tcp" >/dev/null
fi

RELAY_IP="$(curl -fsSL --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
echo
ok "realm 中转已就绪：${RELAY_IP}:${RELAY_PORT} -> ${LANDING}"
echo "注意：如果之前跑过 install.sh，先执行 systemctl disable --now relay-forward 避免端口冲突"
