#!/run/current-system/sw/bin/bash
# incus-ct-create.sh — create + pin random v4/v6 + start + init + snapshot +
# print the server info block.
#
#   usage: incus-ct-create.sh <name> [--image IMG] [--cpu N] [--mem SIZE]
#                              [--disk SIZE] [--snapshot NAME|--no-snapshot] [--no-init]
#
# Defaults: image images:debian/13, cpu 4, mem 4GiB, disk 10GiB,
#           snapshot initial-YYYYmmdd, container init enabled.
#
# Requires (same dir or /usr/local/bin): incus-ipv4-alloc incus-ipv6-alloc
#                                        incus-ct-init.sh incus-ct-info.sh
set -euo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pick() { if [ -x "$HERE/$1" ]; then printf '%s' "$HERE/$1"; else printf '%s' "/usr/local/bin/$1"; fi; }

NAME=${1:?usage: incus-ct-create.sh <name> [--image IMG] [--cpu N] [--mem SIZE] [--disk SIZE] [--snapshot NAME|--no-snapshot] [--no-init]}
shift
IMAGE=images:debian/13; CPU=4; MEM=4GiB; DISK=10GiB
SNAP="initial-$(date +%Y%m%d)"; DO_INIT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --image)     IMAGE=$2; shift 2 ;;
        --cpu)       CPU=$2;   shift 2 ;;
        --mem)       MEM=$2;   shift 2 ;;
        --disk)      DISK=$2;  shift 2 ;;
        --snapshot)  SNAP=$2;  shift 2 ;;
        --no-snapshot) SNAP=""; shift ;;
        --no-init)   DO_INIT=0; shift ;;
        *) echo "error: unknown option: $1" >&2; exit 2 ;;
    esac
done

IPV4_ALLOC=$(pick incus-ipv4-alloc)
IPV6_ALLOC=$(pick incus-ipv6-alloc)
CT_INIT=$(pick incus-ct-init.sh)
CT_INFO=$(pick incus-ct-info.sh)
for f in "$IPV4_ALLOC" "$IPV6_ALLOC" "$CT_INIT" "$CT_INFO"; do
    [ -x "$f" ] || { echo "error: missing $f - install the rendered bin/* to /usr/local/bin" >&2; exit 1; }
done

incus info "$NAME" >/dev/null 2>&1 && { echo "error: instance $NAME already exists" >&2; exit 1; }

echo "[1/6] create $NAME from $IMAGE"
incus create "$IMAGE" "$NAME"

echo "[2/6] limits: cpu=$CPU mem=$MEM disk=$DISK (swap->host, nesting on)"
incus config set "$NAME" "limits.cpu=$CPU"
incus config set "$NAME" "limits.memory=$MEM"
incus config set "$NAME" limits.memory.swap=true
incus config set "$NAME" security.nesting=true
incus config device override "$NAME" root size="$DISK"

echo "[3/6] allocate + pin addresses"
V4=$("$IPV4_ALLOC" alloc "$NAME")
V6=$("$IPV6_ALLOC" alloc "$NAME")
incus config device override "$NAME" eth0 ipv4.address="$V4" ipv6.address="$V6"
echo "      pinned v4=$V4 v6=$V6"

echo "[4/6] start + wait for the pinned addresses inside the container"
incus start "$NAME"
ok4=""; ok6=""
for _ in $(seq 1 40); do
    addrs=$(incus exec "$NAME" -- ip -br a 2>/dev/null || true)
    ok4=$(printf '%s\n' "$addrs" | grep -c "${V4}/" || true)
    ok6=$(printf '%s\n' "$addrs" | grep -c "${V6}/128" || true)
    [ "$ok4" != 0 ] && [ "$ok6" != 0 ] && break
    sleep 3
done
if [ "$ok4" = 0 ]; then echo "WARNING: $V4 not seen inside $NAME (DHCPv4 problem?)" >&2; fi
if [ "$ok6" = 0 ]; then
    echo "WARNING: $V6 not seen inside $NAME - DHCPv6 lease of a deleted instance may still hold" \
         "that /128; see references/pitfalls.md #13 (lease guard + incus-ct-flush-lease.sh)" >&2
fi

PW=""
if [ "$DO_INIT" = 1 ]; then
    echo "[5/6] container init (root + random password + sshd + upgrade)"
    PW=$("$CT_INIT" "$NAME")
else
    echo "[5/6] init skipped (--no-init)"
fi

if [ -n "$SNAP" ]; then
    incus snapshot create "$NAME" "$SNAP"
    echo "[6/6] snapshot $SNAP created"
else
    echo "[6/6] snapshot skipped"
fi

echo
if [ -n "$PW" ]; then
    "$CT_INFO" "$NAME" "$PW" | tee "/root/incus-ct-${NAME}.info"
else
    "$CT_INFO" "$NAME" | tee "/root/incus-ct-${NAME}.info"
fi
chmod 600 "/root/incus-ct-${NAME}.info"
echo "info file saved: /root/incus-ct-${NAME}.info"
