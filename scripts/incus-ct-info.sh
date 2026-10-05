#!/run/current-system/sw/bin/bash
# incus-ct-info.sh — print the server info block for one container.
#
#   usage: incus-ct-info.sh <name> [password]
set -euo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME=${1:?usage: incus-ct-info.sh <name> [password]}
PW=${2:-}
IPV4_ALLOC=/usr/local/bin/incus-ipv4-alloc
IPV6_ALLOC=/usr/local/bin/incus-ipv6-alloc

cfg=$(incus config show "$NAME" 2>/dev/null) || { echo "error: no such instance: $NAME" >&2; exit 1; }

PIN4=$(printf '%s\n' "$cfg" | awk '/^  eth0:/{f=1} f&&/ipv4.address:/{print $2; exit}')
PIN6=$(printf '%s\n' "$cfg" | awk '/^  eth0:/{f=1} f&&/ipv6.address:/{print $2; exit}')
ACT=$(incus exec "$NAME" -- ip -br a 2>/dev/null | grep -v '^lo' || true)
ACT4=$(printf '%s\n' "$ACT" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | head -1 || true)
ACT6=$(printf '%s\n' "$ACT" | grep -oE '([0-9a-fA-F:]{6,})/[0-9]+' | grep -v '^fe80' | head -1 || true)
STATE=$(incus list "$NAME" -c s --format csv 2>/dev/null | head -1 || echo '?')
HOSTN=$(incus exec "$NAME" -- hostname 2>/dev/null || echo '?')
CPU=$(incus config get "$NAME" limits.cpu 2>/dev/null || echo '-')
MEM=$(incus config get "$NAME" limits.memory 2>/dev/null || echo '-')
SWAP=$(incus config get "$NAME" limits.memory.swap 2>/dev/null || echo '-')
NEST=$(incus config get "$NAME" security.nesting 2>/dev/null || echo '-')
DISK=$(printf '%s\n' "$cfg" | awk '/^  root:/{f=1} f&&/size:/{print $2; exit}')
SNAPS=$(incus snapshot list "$NAME" --format csv 2>/dev/null | cut -d, -f1 | grep -vE '^(NAME)?$' | paste -sd, - || true)

echo "============================================================"
printf ' container : %s  (%s)\n' "$NAME" "${STATE:-?}"
printf ' hostname  : %s\n' "$HOSTN"
printf ' IPv4 (LAN): %s\n' "${ACT4:-not seen}"
printf ' IPv6 (WAN): %s\n' "${ACT6:-not seen}"
printf ' pinned    : v4=%s  v6=%s\n' "${PIN4:-none}" "${PIN6:-none}"
printf ' login     : root@%s   password: %s\n' "${ACT4%%/*}" "${PW:-<shown when created>}"
printf '   ssh -4 root@%s\n' "${ACT4%%/*}"
printf '   ssh -6 root@%s\n' "${ACT6%%/*}"
printf ' resources : cpu=%s mem=%s swap=%s nesting=%s disk=%s\n' "$CPU" "$MEM" "$SWAP" "$NEST" "${DISK:-default}"
printf ' snapshots : %s\n' "${SNAPS:-none}"
printf ' allocator : v4=%s v6=%s\n' "$("$IPV4_ALLOC" show "$NAME" 2>/dev/null || echo -)" "$("$IPV6_ALLOC" show "$NAME" 2>/dev/null || echo -)"
echo "============================================================"
