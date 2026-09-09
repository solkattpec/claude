#!/usr/bin/env bash
# 生成可直接导入 Clash Verge 的配置。
# serve-sub.sh 会自动调用它；也可以在 Mac 上单独跑。
#
#   R2=<另一台中转IP> bash render.sh /root/vpn-out/credentials.env > my-vpn.yaml
#
# 四个节点 = 四个出口 IP：两台中转各自直出，加上各自转发到一个落地。
# 落地代理的账号密码只留在中转机上，不进这份配置。
#
# 节点名默认带上出口 IP，想换成地区名：
#   R1_LABEL=香港 R2_LABEL=日本 L1_LABEL=美西 L2_LABEL=美东 ...
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/config.yaml"
[ -f "$TPL" ] || { echo "找不到模板 $TPL" >&2; exit 1; }

if [ "${1:-}" != "" ]; then
  [ -f "$1" ] || { echo "凭据文件不存在：$1" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$1"
  R1="${R1:-${RELAY_IP:-}}"
fi

PUBLIC_KEY="${PUBLIC_KEY:-${PUB_KEY:-}}"
PORT0="${PORT0:-2053}"

: "${R1:?必须提供 R1（本机中转 IP）}"
: "${R2:?必须提供 R2（另一台中转 IP）}"
: "${PORT1:?必须提供 PORT1}"
: "${PORT2:?必须提供 PORT2}"
: "${UUID:?必须提供 UUID}"
: "${PUBLIC_KEY:?必须提供 PUB_KEY / PUBLIC_KEY}"
: "${SHORT_ID:?必须提供 SHORT_ID}"
: "${DEST:?必须提供 DEST}"

[ "$R1" = "$R2" ] && { echo "R1 和 R2 不能是同一台（现在都是 $R1）" >&2; exit 1; }

# ── 节点名：名字里写的就是网站看到的出口 IP ──────────────────
short_ip() { echo "$1" | cut -d. -f1,2; }
R1_LABEL="${R1_LABEL:-$(short_ip "$R1")}"
R2_LABEL="${R2_LABEL:-$(short_ip "$R2")}"
L1_LABEL="${L1_LABEL:-${LANDING1_EXIT:-落地1}}"
L2_LABEL="${L2_LABEL:-${LANDING2_EXIT:-落地2}}"

# 名字必须互不相同，否则 mihomo 会因重名节点直接报错
[ "$R1_LABEL" = "$R2_LABEL" ] && { R1_LABEL="${R1_LABEL}-a"; R2_LABEL="${R2_LABEL}-b"; }
[ "$L1_LABEL" = "$L2_LABEL" ] && { L1_LABEL="${L1_LABEL}-a"; L2_LABEL="${L2_LABEL}-b"; }

N1="直出 ${R1}"
N2="直出 ${R2}"
N3="${R1_LABEL} → ${L1_LABEL}"
N4="${R2_LABEL} → ${L2_LABEL}"

# sed 替换串里的 & \ | 要转义
esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

sed -e "s|__N1__|$(esc "$N1")|g" \
    -e "s|__N2__|$(esc "$N2")|g" \
    -e "s|__N3__|$(esc "$N3")|g" \
    -e "s|__N4__|$(esc "$N4")|g" \
    -e "s|__R1__|${R1}|g" \
    -e "s|__R2__|${R2}|g" \
    -e "s|__PORT0__|${PORT0}|g" \
    -e "s|__PORT1__|${PORT1}|g" \
    -e "s|__PORT2__|${PORT2}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__PUBLIC_KEY__|$(esc "$PUBLIC_KEY")|g" \
    -e "s|__SHORT_ID__|${SHORT_ID}|g" \
    -e "s|__DEST__|${DEST}|g" \
    "$TPL"
