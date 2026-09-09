#!/usr/bin/env bash
# 把 config.yaml 的占位符填上，生成可直接导入 Clash Verge 的配置。
# 在你的 Mac 上运行（bash 3.2 兼容）。
#
# 方式 A —— 用落地机生成的凭据文件（推荐）：
#   scp root@落地机IP:/root/vpn-out/credentials.env .
#   RELAY_IP=1.2.3.4 bash render.sh credentials.env > ~/Desktop/my-vpn.yaml
#
# 方式 B —— 全部手填：
#   RELAY_IP=1.2.3.4 PORT=443 UUID=... PUBLIC_KEY=... SHORT_ID=... DEST=www.yahoo.com \
#     bash render.sh > ~/Desktop/my-vpn.yaml
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/config.yaml"
[ -f "$TPL" ] || { echo "找不到模板 $TPL" >&2; exit 1; }

if [ "${1:-}" != "" ]; then
  [ -f "$1" ] || { echo "凭据文件不存在：$1" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$1"
fi

: "${RELAY_IP:?必须提供 RELAY_IP（中转机 IP）}"
: "${PORT:?必须提供 PORT}"
: "${UUID:?必须提供 UUID}"
: "${PUBLIC_KEY:?必须提供 PUBLIC_KEY}"
: "${SHORT_ID:?必须提供 SHORT_ID}"
: "${DEST:?必须提供 DEST}"

sed -e "s|__RELAY_IP__|${RELAY_IP}|g" \
    -e "s|__PORT__|${PORT}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__PUBLIC_KEY__|${PUBLIC_KEY}|g" \
    -e "s|__SHORT_ID__|${SHORT_ID}|g" \
    -e "s|__DEST__|${DEST}|g" \
    "$TPL"

