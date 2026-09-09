#!/usr/bin/env bash
# 在中转机上生成客户端配置，并对外提供一个 Clash Verge 可以直接导入的订阅链接。
#
# 必须先跑完 relay/install.sh（两台中转都要跑完）。
#
# 用法（在【中转1】上以 root 执行）：
#   R2=<中转2的IP> bash relay/serve-sub.sh
#
# 可选：
#   SUB_PORT=<端口>   默认随机高位端口
#   TTL=1800          链接存活秒数，默认 30 分钟后自动关（导完就没了，最安全）
#   KEEP=1            常驻不关，Clash 才能自动更新订阅（链接一直暴露，自己权衡）
set -euo pipefail

CRED=/root/vpn-out/credentials.env
DIR="$(cd "$(dirname "$0")/.." && pwd)"      # vpn/
SUBDIR=/var/lib/clash-sub
TTL="${TTL:-1800}"
KEEP="${KEEP:-0}"

log() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[!]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -f "$CRED" ] || die "找不到 $CRED，先跑 relay/install.sh"
[ -f "$DIR/client/render.sh" ] || die "找不到 $DIR/client/render.sh，请在克隆出来的仓库目录里执行"
command -v python3 >/dev/null 2>&1 || die "需要 python3：apt-get install -y python3"

# shellcheck disable=SC1090
. "$CRED"
: "${R2:?必须指定 R2=<另一台中转的IP>}"
[ -n "${RELAY_IP:-}" ] || die "$CRED 里没有 RELAY_IP"

# 端口和 token 存下来复用，重跑时链接不变
# —— Clash Verge 里点「更新」就能拿到新配置，不用重新添加订阅。
# 想换一条全新链接（比如怀疑旧的泄露了）：NEW_TOKEN=1 bash relay/serve-sub.sh
mkdir -p "$SUBDIR"; chmod 700 "$SUBDIR"
META="$SUBDIR/.sub-meta"
if [ "${NEW_TOKEN:-0}" != "1" ] && [ -f "$META" ]; then
  # shellcheck disable=SC1090
  . "$META"
fi
SUB_PORT="${SUB_PORT:-${SAVED_PORT:-$(shuf -i 20000-60000 -n 1)}}"
TOKEN="${SAVED_TOKEN:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
printf 'SAVED_PORT=%s\nSAVED_TOKEN=%s\n' "$SUB_PORT" "$TOKEN" > "$META"
chmod 600 "$META"

# ---------- 1. 渲染客户端配置 ----------
log "渲染客户端配置"
rm -f "$SUBDIR"/*.yaml
R1="$RELAY_IP" R2="$R2" bash "$DIR/client/render.sh" "$CRED" > "$SUBDIR/${TOKEN}.yaml"
chmod 600 "$SUBDIR/${TOKEN}.yaml"
grep -q '__' "$SUBDIR/${TOKEN}.yaml" && die "配置里还有没填的占位符"
ok "已生成（$(wc -l < "$SUBDIR/${TOKEN}.yaml") 行）"

# ---------- 2. 只认 token 路径的极简 HTTP 服务 ----------
# 不开目录列表，路径不对一律 404，扫端口的人拿不到东西
cat > "$SUBDIR/server.py" <<'PYEOF'
import http.server, socketserver, os, sys

TOKEN = os.environ["SUB_TOKEN"]
FILE  = os.environ["SUB_FILE"]
PORT  = int(os.environ["SUB_PORT"])

class H(http.server.BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def _head(self):
        """路径对就写响应头并返回内容，否则 404。"""
        if self.path != "/" + TOKEN + ".yaml":
            self.send_error(404)
            return None
        with open(FILE, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", 'attachment; filename="my-vpn.yaml"')
        self.send_header("Profile-Update-Interval", "24")
        self.end_headers()
        return data

    # 有些客户端会先发 HEAD 探测，不实现的话会收到 501
    def do_HEAD(self):
        self._head()

    def do_GET(self):
        data = self._head()
        if data is None:
            return
        self.wfile.write(data)
        sys.stderr.write("served to %s\n" % self.address_string())
        sys.stderr.flush()

    def log_message(self, fmt, *a):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("0.0.0.0", PORT), H) as s:
    s.serve_forever()
PYEOF

# ---------- 3. 放行端口 ----------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${SUB_PORT}/tcp" >/dev/null 2>&1 || true
fi

# ---------- 4. 起服务 ----------
systemctl stop clash-sub 2>/dev/null || true
systemctl reset-failed clash-sub 2>/dev/null || true

if [ "$KEEP" = "1" ]; then
  RUNCMD=(/usr/bin/python3 "$SUBDIR/server.py")
  LIFE="常驻（Clash 可自动更新订阅）"
else
  RUNCMD=(/usr/bin/timeout "$TTL" /usr/bin/python3 "$SUBDIR/server.py")
  LIFE="${TTL} 秒后自动关闭"
fi

systemd-run --unit=clash-sub --collect \
  --setenv=SUB_TOKEN="$TOKEN" \
  --setenv=SUB_FILE="$SUBDIR/${TOKEN}.yaml" \
  --setenv=SUB_PORT="$SUB_PORT" \
  "${RUNCMD[@]}" >/dev/null

sleep 1
systemctl is-active --quiet clash-sub || { journalctl -u clash-sub -n 20 --no-pager; die "订阅服务没起来"; }

# ---------- 5. 自检 ----------
URL="http://${RELAY_IP}:${SUB_PORT}/${TOKEN}.yaml"
log "自检"
if curl -fsS --max-time 8 "http://127.0.0.1:${SUB_PORT}/${TOKEN}.yaml" | head -1 | grep -q '^#'; then
  ok "本机自取正常"
else
  warn "本机自取异常，检查 journalctl -u clash-sub"
fi

echo
ok "订阅链接已就绪（${LIFE}）"
echo "════════════════════════════════════════════════════════"
echo "$URL"
echo "════════════════════════════════════════════════════════"
echo
# 二维码：手机/平板扫一下就能导入，不用手输长链接
if [ "${QR:-1}" = "1" ]; then
  if ! command -v qrencode >/dev/null 2>&1; then
    if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q qrencode >/dev/null 2>&1 || true
    elif command -v yum     >/dev/null 2>&1; then yum install -y -q qrencode >/dev/null 2>&1 || true
    fi
  fi
  if command -v qrencode >/dev/null 2>&1; then
    echo "手机 / 平板扫这个二维码导入（终端窗口调大一点才扫得到）："
    echo
    qrencode -t ANSIUTF8 -m 2 "$URL"
    echo
  else
    warn "装不上 qrencode，跳过二维码；手动复制上面的链接也一样"
  fi
fi

echo "Clash Verge 一键导入（Mac 上直接点/在浏览器地址栏敲）："
echo "clash://install-config?url=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$URL")"
echo
echo "或者在 Clash Verge：配置 → 右上角 + → Remote → 粘贴上面那条 http 链接"
echo
echo "导完就关掉（不留后门）：  systemctl stop clash-sub"
echo "看谁取过：                journalctl -u clash-sub"
echo "重跑本脚本链接不变，Clash Verge 里点「更新」即可拿到新配置。"
echo "想换一条全新链接：        NEW_TOKEN=1 bash relay/serve-sub.sh"
echo "给别的设备导、时间不够：  TTL=7200 bash relay/serve-sub.sh   （链接存活 2 小时）"
