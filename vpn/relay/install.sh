#!/usr/bin/env bash
# 中转机安装脚本
#
#   客户端 --VLESS-Reality--> 本机(中转) --SOCKS5/HTTP认证--> 落地代理 --> 互联网
#
# 本机监听两个端口，一个端口对应一个落地，客户端切端口就等于切落地。
#
# 用法（在中转机上以 root 执行）：
#   LANDING1='IP:PORT:USER:PASS' LANDING2='IP:PORT:USER:PASS' bash install.sh
#
# 装第二台中转时，把第一台输出的凭据带上，两台就共用同一套 UUID/密钥：
#   UUID=... PRIV_KEY=... PUB_KEY=... SHORT_ID=... DEST=... \
#   LANDING1='...' LANDING2='...' bash install.sh
#
# 可选：PORT1=443  PORT2=8443  DEST=www.yahoo.com  SB_VERSION=1.11.15
set -euo pipefail

# 也接受 credentials.env 里的 LANDING*_SPEC，这样重跑时
#   set -a; . /root/vpn-out/credentials.env; set +a; bash relay/install.sh
# 就够了，不用再手动贴落地的账号密码。
LANDING1="${LANDING1:-${LANDING1_SPEC:-}}"
LANDING2="${LANDING2:-${LANDING2_SPEC:-}}"
PORT0="${PORT0:-2053}"   # 从中转机本身出口，不经落地
PORT1="${PORT1:-443}"    # 转发到落地1
PORT2="${PORT2:-8443}"   # 转发到落地2
DEST="${DEST:-www.yahoo.com}"
SB_VERSION="${SB_VERSION:-}"
CONF_DIR=/etc/sing-box
OUT_DIR=/root/vpn-out

log() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[!]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -n "$LANDING1" ] || die "必须指定 LANDING1='IP:PORT:USER:PASS'"
[ -n "$LANDING2" ] || LANDING2="$LANDING1"

# 拆 IP:PORT:USER:PASS（密码里可以带冒号）
parse_landing() {
  local spec="$1" rest
  L_IP="${spec%%:*}";   rest="${spec#*:}"
  L_PORT="${rest%%:*}"; rest="${rest#*:}"
  L_USER="${rest%%:*}"
  L_PASS="${rest#*:}"
  [ -n "$L_IP" ] && [ -n "$L_PORT" ] && [ -n "$L_USER" ] && [ -n "$L_PASS" ] \
    || die "落地格式不对：$spec（应为 IP:PORT:USER:PASS）"
}

# ---------- 1. 依赖 ----------
log "安装依赖"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl tar jq openssl ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl tar jq openssl ca-certificates
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q curl tar jq openssl ca-certificates
else
  die "未识别的包管理器，请手动安装 curl tar jq openssl"
fi

# ---------- 2. 探测落地代理：是 SOCKS5 还是 HTTP？ ----------
# 顺便记下真实出口 IP，部署完可以拿来对账
detect_landing() {
  local ip=$1 port=$2 user=$3 pass=$4 scheme out
  for scheme in socks5h http; do
    out="$(curl -s --max-time 15 -x "${scheme}://${user}:${pass}@${ip}:${port}" \
           https://api.ipify.org 2>/dev/null || true)"
    if printf '%s' "$out" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      printf '%s %s' "$scheme" "$out"
      return 0
    fi
  done
  return 1
}

declare -a L_TYPE L_HOST L_PORTS L_USERS L_PASSES L_EXIT
i=0
for spec in "$LANDING1" "$LANDING2"; do
  i=$((i+1))
  parse_landing "$spec"
  log "探测落地${i} ${L_IP}:${L_PORT} 的协议"
  if ! res="$(detect_landing "$L_IP" "$L_PORT" "$L_USER" "$L_PASS")"; then
    die "落地${i} ${L_IP}:${L_PORT} 连不上，或用户名/密码不对。
     手动验证：curl -v --max-time 15 -x 'socks5h://${L_USER}:${L_PASS}@${L_IP}:${L_PORT}' https://api.ipify.org
               curl -v --max-time 15 -x 'http://${L_USER}:${L_PASS}@${L_IP}:${L_PORT}' https://api.ipify.org
     若密码含 @ : / 等特殊字符，curl 里需要 URL 编码（本脚本写进 sing-box 配置时不受影响）。"
  fi
  scheme="${res%% *}"; exitip="${res##* }"
  case "$scheme" in
    socks5h) sbtype=socks ;;
    http)    sbtype=http  ;;
  esac
  ok "落地${i}: ${sbtype}  出口 IP = ${exitip}"
  L_TYPE[$i]=$sbtype; L_HOST[$i]=$L_IP; L_PORTS[$i]=$L_PORT
  L_USERS[$i]=$L_USER; L_PASSES[$i]=$L_PASS; L_EXIT[$i]=$exitip
done

# ---------- 3. 校验 Reality 伪装目标 ----------
log "校验伪装目标 $DEST 是否支持 TLS1.3 + h2"
if ! timeout 15 openssl s_client -connect "${DEST}:443" -servername "$DEST" \
      -tls1_3 -alpn h2 </dev/null 2>/dev/null | grep -q 'ALPN protocol: h2'; then
  die "$DEST 不满足要求（TLS1.3 + HTTP/2）。换一个再试：
     DEST=addons.mozilla.org / DEST=www.icloud.com / DEST=dl.google.com"
fi
ok "$DEST 可用"

# ---------- 4. 安装 sing-box ----------
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l)        ARCH=armv7 ;;
  *) die "不支持的架构 $(uname -m)" ;;
esac

if [ -z "$SB_VERSION" ]; then
  log "查询 sing-box 最新版本"
  SB_VERSION="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
                | jq -r '.tag_name' | sed 's/^v//')"
  [ -n "$SB_VERSION" ] && [ "$SB_VERSION" != "null" ] \
    || die "获取版本失败，用 SB_VERSION=1.11.15 手动指定"
fi

log "下载 sing-box v${SB_VERSION} (${ARCH})"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${ARCH}.tar.gz" \
  -o "$TMP/sb.tar.gz" || die "sing-box 下载失败"
tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
install -m 755 "$TMP"/sing-box-*/sing-box /usr/local/bin/sing-box
ok "sing-box $(/usr/local/bin/sing-box version | head -1)"

# ---------- 5. 凭据：没给就生成，给了就复用（第二台中转用） ----------
mkdir -p "$CONF_DIR" "$OUT_DIR"; chmod 700 "$OUT_DIR"
if [ -z "${UUID:-}" ] || [ -z "${PRIV_KEY:-}" ] || [ -z "${PUB_KEY:-}" ] || [ -z "${SHORT_ID:-}" ]; then
  log "生成新的 UUID / Reality 密钥对 / shortId"
  UUID="$(/usr/local/bin/sing-box generate uuid)"
  KP="$(/usr/local/bin/sing-box generate reality-keypair)"
  PRIV_KEY="$(echo "$KP" | awk '/PrivateKey/{print $2}')"
  PUB_KEY="$(echo  "$KP" | awk '/PublicKey/{print $2}')"
  SHORT_ID="$(openssl rand -hex 8)"
  [ -n "$PRIV_KEY" ] && [ -n "$PUB_KEY" ] || die "密钥生成失败"
  NEWCRED=1
else
  log "复用传入的凭据（与另一台中转保持一致）"
  NEWCRED=0
fi

# ---------- 6. 写配置 ----------
# 出站 JSON：socks 要带 version，http 不要
outbound_json() {
  local idx=$1 tag=$2
  if [ "${L_TYPE[$idx]}" = "socks" ]; then
    cat <<EOF
    {
      "type": "socks",
      "tag": "${tag}",
      "server": "${L_HOST[$idx]}",
      "server_port": ${L_PORTS[$idx]},
      "version": "5",
      "username": "${L_USERS[$idx]}",
      "password": "${L_PASSES[$idx]}"
    }
EOF
  else
    cat <<EOF
    {
      "type": "http",
      "tag": "${tag}",
      "server": "${L_HOST[$idx]}",
      "server_port": ${L_PORTS[$idx]},
      "username": "${L_USERS[$idx]}",
      "password": "${L_PASSES[$idx]}"
    }
EOF
  fi
}

inbound_json() {
  local tag=$1 port=$2
  cat <<EOF
    {
      "type": "vless",
      "tag": "${tag}",
      "listen": "::",
      "listen_port": ${port},
      "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
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
EOF
}

log "写入 $CONF_DIR/config.json"
{
  echo '{'
  echo '  "log": { "level": "warn", "timestamp": true },'
  echo '  "inbounds": ['
  inbound_json "in-direct" "$PORT0"; echo '    ,'
  inbound_json "in-l1" "$PORT1"; echo '    ,'
  inbound_json "in-l2" "$PORT2"
  echo '  ],'
  echo '  "outbounds": ['
  outbound_json 1 "landing1"; echo '    ,'
  outbound_json 2 "landing2"; echo '    ,'
  echo '    { "type": "direct", "tag": "direct" }'
  echo '  ],'
  echo '  "route": {'
  echo '    "rules": ['
  echo '      { "inbound": ["in-direct"], "outbound": "direct" },'
  echo '      { "inbound": ["in-l1"], "outbound": "landing1" },'
  echo '      { "inbound": ["in-l2"], "outbound": "landing2" }'
  echo '    ],'
  echo '    "final": "landing1"'
  echo '  }'
  echo '}'
} > "$CONF_DIR/config.json"
chmod 600 "$CONF_DIR/config.json"
jq empty "$CONF_DIR/config.json" || die "生成的 JSON 有语法错误"
/usr/local/bin/sing-box check -c "$CONF_DIR/config.json" || die "sing-box 配置校验未通过"
ok "配置校验通过"

# ---------- 7. systemd ----------
log "配置 systemd"
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
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box \
  || { journalctl -u sing-box -n 30 --no-pager; die "sing-box 启动失败"; }
ok "sing-box 已启动并设为开机自启"

# ---------- 8. BBR ----------
log "开启 BBR + fq"
cat > /etc/sysctl.d/99-relay.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
EOF
sysctl -p /etc/sysctl.d/99-relay.conf >/dev/null 2>&1 || true
ok "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"

# ---------- 9. 放行端口 ----------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT0}/tcp" >/dev/null
  ufw allow "${PORT1}/tcp" >/dev/null; ufw allow "${PORT2}/tcp" >/dev/null
  ok "ufw 已放行 ${PORT0},${PORT1},${PORT2}/tcp"
fi

# ---------- 10. 输出 ----------
RELAY_IP="$(curl -fsSL --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
cat > "$OUT_DIR/credentials.env" <<EOF
RELAY_IP=${RELAY_IP}
PORT0=${PORT0}
PORT1=${PORT1}
PORT2=${PORT2}
UUID=${UUID}
PRIV_KEY=${PRIV_KEY}
PUB_KEY=${PUB_KEY}
SHORT_ID=${SHORT_ID}
DEST=${DEST}
LANDING1_EXIT=${L_EXIT[1]}
LANDING2_EXIT=${L_EXIT[2]}
LANDING1_SPEC='${L_HOST[1]}:${L_PORTS[1]}:${L_USERS[1]}:${L_PASSES[1]}'
LANDING2_SPEC='${L_HOST[2]}:${L_PORTS[2]}:${L_USERS[2]}:${L_PASSES[2]}'
LANDING1_TYPE=${L_TYPE[1]}
LANDING2_TYPE=${L_TYPE[2]}
EOF
chmod 600 "$OUT_DIR/credentials.env"

echo
ok "中转机部署完成：${RELAY_IP}"
echo "────────────────────────────────────────────────────────"
echo " ${RELAY_IP}:${PORT0}  ->  直出（出口就是本机 ${RELAY_IP}）"
echo " ${RELAY_IP}:${PORT1}  ->  落地1 ${L_HOST[1]}:${L_PORTS[1]} (${L_TYPE[1]})  出口 ${L_EXIT[1]}"
echo " ${RELAY_IP}:${PORT2}  ->  落地2 ${L_HOST[2]}:${L_PORTS[2]} (${L_TYPE[2]})  出口 ${L_EXIT[2]}"
echo "────────────────────────────────────────────────────────"
echo " UUID      : ${UUID}"
echo " PublicKey : ${PUB_KEY}"
echo " ShortId   : ${SHORT_ID}"
echo " Dest/SNI  : ${DEST}"
echo "────────────────────────────────────────────────────────"
if [ "$NEWCRED" = "1" ]; then
  echo
  echo "在【第二台中转】上执行下面这条，两台就共用同一套凭据："
  echo
  echo "  UUID='${UUID}' PRIV_KEY='${PRIV_KEY}' PUB_KEY='${PUB_KEY}' \\"
  echo "  SHORT_ID='${SHORT_ID}' DEST='${DEST}' \\"
  echo "  LANDING1='${L_HOST[1]}:${L_PORTS[1]}:${L_USERS[1]}:${L_PASSES[1]}' \\"
  echo "  LANDING2='${L_HOST[2]}:${L_PORTS[2]}:${L_USERS[2]}:${L_PASSES[2]}' \\"
  echo "  bash install.sh"
fi
echo
echo "凭据备份：$OUT_DIR/credentials.env"
