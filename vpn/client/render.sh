#!/usr/bin/env bash
# 生成可直接导入 Clash Verge 的配置。在你的 Mac 上运行（bash 3.2 兼容）。
#
# 方式 A —— 用中转1 生成的凭据文件（推荐）：
#   scp root@<中转1IP>:/root/vpn-out/credentials.env .
#   R2=<中转2IP> bash render.sh credentials.env > ~/Desktop/my-vpn.yaml
#
# 方式 B —— 全部手填：
#   R1=1.1.1.1 R2=2.2.2.2 PORT1=443 PORT2=8443 \
#   UUID=... PUB_KEY=... SHORT_ID=... DEST=www.yahoo.com \
#     bash render.sh > ~/Desktop/my-vpn.yaml
#
# 输出含节点凭据，别提交到 git、别发群里。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/config.yaml"
[ -f "$TPL" ] || { echo "找不到模板 $TPL" >&2; exit 1; }

if [ "${1:-}" != "" ]; then
  [ -f "$1" ] || { echo "凭据文件不存在：$1" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$1"
  # credentials.env 里中转自己的 IP 叫 RELAY_IP，没显式给 R1 就用它
  R1="${R1:-${RELAY_IP:-}}"
fi

# 兼容两种写法：PUB_KEY（脚本输出）/ PUBLIC_KEY（手填）
PUBLIC_KEY="${PUBLIC_KEY:-${PUB_KEY:-}}"

: "${R1:?必须提供 R1（中转1 IP）}"
: "${R2:?必须提供 R2（中转2 IP）}"
: "${PORT1:?必须提供 PORT1}"
: "${PORT2:?必须提供 PORT2}"
: "${UUID:?必须提供 UUID}"
: "${PUBLIC_KEY:?必须提供 PUB_KEY / PUBLIC_KEY}"
: "${SHORT_ID:?必须提供 SHORT_ID}"
: "${DEST:?必须提供 DEST}"

sed -e "s|__R1__|${R1}|g" \
    -e "s|__R2__|${R2}|g" \
    -e "s|__PORT1__|${PORT1}|g" \
    -e "s|__PORT2__|${PORT2}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__PUBLIC_KEY__|${PUBLIC_KEY}|g" \
    -e "s|__SHORT_ID__|${SHORT_ID}|g" \
    -e "s|__DEST__|${DEST}|g" \
    "$TPL"
