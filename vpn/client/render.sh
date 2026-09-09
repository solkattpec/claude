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

# ── 节点名：「中转IP前两段 → 落地出口IP」 ───────────────────────
# 箭头右边是网站实际看到的 IP。出口 IP 由 install.sh 探测后写进 credentials.env。
# 想换成自己看得懂的名字（地区之类），跑之前设这四个变量即可，例如：
#   R1_LABEL=香港 R2_LABEL=日本 L1_LABEL=美西 L2_LABEL=美东 bash render.sh ...
short_ip() { echo "$1" | cut -d. -f1,2; }

R1_LABEL="${R1_LABEL:-$(short_ip "$R1")}"
R2_LABEL="${R2_LABEL:-$(short_ip "$R2")}"
L1_LABEL="${L1_LABEL:-${LANDING1_EXIT:-落地1}}"
L2_LABEL="${L2_LABEL:-${LANDING2_EXIT:-落地2}}"

# 名字必须两两不同，否则 mihomo 会因重名节点报错
[ "$R1_LABEL" = "$R2_LABEL" ] && { R1_LABEL="${R1_LABEL}-a"; R2_LABEL="${R2_LABEL}-b"; }
[ "$L1_LABEL" = "$L2_LABEL" ] && { L1_LABEL="${L1_LABEL}-a"; L2_LABEL="${L2_LABEL}-b"; }

N11="${R1_LABEL} → ${L1_LABEL}"
N12="${R1_LABEL} → ${L2_LABEL}"
N21="${R2_LABEL} → ${L1_LABEL}"
N22="${R2_LABEL} → ${L2_LABEL}"

case "${N11}${N12}${N21}${N22}" in
  *"|"*) echo "节点名里不能有 | 字符" >&2; exit 1 ;;
esac

sed -e "s|__N11__|${N11}|g" \
    -e "s|__N12__|${N12}|g" \
    -e "s|__N21__|${N21}|g" \
    -e "s|__N22__|${N22}|g" \
    -e "s|__R1__|${R1}|g" \
    -e "s|__R2__|${R2}|g" \
    -e "s|__PORT1__|${PORT1}|g" \
    -e "s|__PORT2__|${PORT2}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__PUBLIC_KEY__|${PUBLIC_KEY}|g" \
    -e "s|__SHORT_ID__|${SHORT_ID}|g" \
    -e "s|__DEST__|${DEST}|g" \
    "$TPL"
