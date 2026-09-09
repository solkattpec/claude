#!/usr/bin/env bash
# 落地机安装脚本：sing-box + VLESS-XTLS-Vision-Reality
#
# 用法（在落地机上以 root 执行）：
#   RELAY_IP=1.2.3.4 bash install.sh
#
# 可选环境变量：
#   PORT=443                  监听端口
#   DEST=www.yahoo.com        Reality 伪装目标（需支持 TLS1.3 + h2）
#   RELAY_IP=<中转机IP>       只允许该 IP 访问监听端口（强烈建议填）
#   SB_VERSION=1.11.15        指定 sing-box 版本，默认取最新 release
set -euo pipefail

PORT="${PORT:-443}"
DEST="${DEST:-www.yahoo.com}"
RELAY_IP="${RELAY_IP:-}"
SB_VERSION="${SB_VERSION:-}"
CONF_DIR=/etc/sing-box
OUT_DIR=/root/vpn-out

log()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"

# ---------- 1. 依赖 ----------
log "安装依赖"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl tar jq openssl ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl tar jq openssl ca-certificates
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q curl tar jq openssl ca-certificates
else
  die "未识别的包管理器，请手动安装 curl tar jq openssl"
fi

# ---------- 2. 校验 Reality 伪装目标 ----------
log "校验伪装目标 $DEST 是否支持 TLS1.3 + h2"
if ! timeout 12 openssl s_client -connect "${DEST}:443" -servername "$DEST" \
      -tls1_3 -alpn h2 </dev/null 2>/dev/null | grep -q 'ALPN protocol: h2'; then
  die "$DEST 不满足要求（TLS1.3 + HTTP/2）。换一个再试，例如：
     DEST=addons.mozilla.org / DEST=www.icloud.com / DEST=dl.google.com"
fi
ok "$DEST 可用"

# ---------- 3. 安装 sing-box ----------
case "$(uname -m)" in
  x86_64|amd64)   ARCH=amd64 ;;
  aarch64|arm64)  ARCH=arm64 ;;
  armv7l)         ARCH=armv7 ;;
  *) die "不支持的架构 $(uname -m)" ;;
esac

if [ -z "$SB_VERSION" ]; then
  log "查询 sing-box 最新版本"
  SB_VERSION="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
                | jq -r '.tag_name' | sed 's/^v//')"
  [ -n "$SB_VERSION" ] && [ "$SB_VERSION" != "null" ] || die "获取版本失败，请用 SB_VERSION=1.11.15 手动指定"
fi

log "下载 sing-box v${SB_VERSION} (${ARCH})"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${ARCH}.tar.gz"
curl -fsSL "$URL" -o "$TMP/sb.tar.gz" || die "下载失败：$URL"
tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
install -m 755 "$TMP"/sing-box-*/sing-box /usr/local/bin/sing-box
ok "sing-box $(/usr/local/bin/sing-box version | head -1)"

# ---------- 4. 生成凭据 ----------
log "生成 UUID / Reality 密钥对 / shortId"
mkdir -p "$CONF_DIR" "$OUT_DIR"
chmod 700 "$OUT_DIR"

UUID="$(/usr/local/bin/sing-box generate uuid)"
KEYPAIR="$(/usr/local/bin/sing-box generate reality-keypair)"
PRIV_KEY="$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')"
PUB_KEY="$(echo  "$KEYPAIR" | awk '/PublicKey/{print $2}')"
SHORT_ID="$(openssl rand -hex 8)"
[ -n "$PRIV_KEY" ] && [ -n "$PUB_KEY" ] || die "密钥生成失败"

# ---------- 5. 写配置 ----------
log "写入 $CONF_DIR/config.json"
cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DEST}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${DEST}", "server_port": 443 },
          "private_key": "${PRIV_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
chmod 600 "$CONF_DIR/config.json"
/usr/local/bin/sing-box check -c "$CONF_DIR/config.json" || die "配置校验未通过"

# ---------- 6. systemd ----------
log "配置 systemd 服务"
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /var/lib/sing-box
systemctl daemon-reload
systemctl enable --now sing-box >/dev/null 2>&1
sleep 2
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; die "sing-box 启动失败"; }
ok "sing-box 已启动并设为开机自启"

# ---------- 7. BBR ----------
log "开启 BBR + fq"
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
ok "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"

# ---------- 8. 防火墙 ----------
if [ -n "$RELAY_IP" ]; then
  log "限制 ${PORT}/tcp 仅允许 ${RELAY_IP} 访问"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow from "$RELAY_IP" to any port "$PORT" proto tcp >/dev/null
    ok "已加 ufw 规则"
  else
    echo "  提示：未检测到启用中的 ufw。若落地机有别的防火墙，请自行放行 ${PORT}/tcp（源 ${RELAY_IP}）"
  fi
else
  echo "  提示：未设置 RELAY_IP，端口对全网开放。建议重跑并带上 RELAY_IP=<中转机IP>"
fi

# ---------- 9. 输出客户端配置 ----------
LANDING_IP="$(curl -fsSL --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"

cat > "$OUT_DIR/credentials.env" <<EOF
LANDING_IP=${LANDING_IP}
PORT=${PORT}
UUID=${UUID}
PUBLIC_KEY=${PUB_KEY}
SHORT_ID=${SHORT_ID}
DEST=${DEST}
EOF
chmod 600 "$OUT_DIR/credentials.env"

cat > "$OUT_DIR/clash-proxy.yaml" <<EOF
  - name: "landing"
    type: vless
    server: __中转机IP__
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${DEST}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: "${SHORT_ID}"
EOF

echo
ok "落地机部署完成"
echo "────────────────────────────────────────────────────────"
echo " 落地机 IP : ${LANDING_IP}"
echo " 端口      : ${PORT}"
echo " UUID      : ${UUID}"
echo " PublicKey : ${PUB_KEY}"
echo " ShortId   : ${SHORT_ID}"
echo " Dest/SNI  : ${DEST}"
echo "────────────────────────────────────────────────────────"
echo
echo "接下来在【中转机】上执行："
echo "  LANDING_IP=${LANDING_IP} LANDING_PORT=${PORT} bash relay/install.sh"
echo
echo "客户端节点配置（server 换成中转机 IP）已写到："
echo "  $OUT_DIR/clash-proxy.yaml"
echo "凭据备份：$OUT_DIR/credentials.env"
