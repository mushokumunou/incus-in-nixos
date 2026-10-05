#!/usr/bin/env bash
# render-site.sh — turn site.conf + templates/ into a deployable file set.
#
#   usage: render-site.sh <site.conf> [outdir]     (default outdir: ./rendered)
#
# Every template may contain @@KEY@@ tokens; each is replaced by the value of KEY
# from site.conf. Missing values and leftover tokens are hard errors, so a typo
# can never silently reach a rendered config.
set -euo pipefail

CONF=${1:?usage: render-site.sh <site.conf> [outdir]}
OUT=${2:-rendered}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATES=${TEMPLATES:-$HERE/../templates}

[ -r "$CONF" ] || { echo "error: cannot read $CONF" >&2; exit 1; }
[ -d "$TEMPLATES" ] || { echo "error: templates dir not found: $TEMPLATES" >&2; exit 1; }

# --- load site.conf ----------------------------------------------------------
set -a
# shellcheck disable=SC1090
. "$CONF"
set +a

# --- required keys -----------------------------------------------------------
missing=""
for key in IFACE HOST_IPV4 LAN_GATEWAY LAN_PREFIX POOL_V4_START POOL_V4_END \
           V6_POOL_PREFIX V6_PREFIX_LEN V6_HOST_SUFFIX_HEX V6_BRIDGE_SUFFIX_HEX V6_GATEWAY; do
    eval "val=\${$key:-}"
    [ -n "$val" ] || missing="$missing $key"
done
[ -z "$missing" ] || { echo "error: site.conf is missing:$missing" >&2; exit 1; }

# --- defaults + derived values ----------------------------------------------
: "${HOSTNAME:=$(cat /etc/hostname 2>/dev/null || echo nixos)}"
: "${DNS:=1.1.1.1 8.8.8.8}"
: "${SEARCH_DOMAIN:=local}"
: "${TIMEZONE:=Etc/UTC}"
: "${STORAGE_DRIVER:=btrfs}"
: "${CPU_MODULE:=kvm-amd}"
: "${STATE_VERSION:=26.05}"
: "${FLAKE_REF:=/etc/nixos#${HOSTNAME}}"
: "${IMAGE:=images:debian/13}"
: "${DEFAULT_CPU:=4}"
: "${DEFAULT_MEMORY:=4GiB}"
: "${DEFAULT_DISK:=10GiB}"

DHCP_V4_RANGE="${LAN_PREFIX}.${POOL_V4_START}-${LAN_PREFIX}.${POOL_V4_END}"
HOST_IPV6="${V6_POOL_PREFIX}:${V6_HOST_SUFFIX_HEX}"
V6_BRIDGE_ADDRESS="${V6_POOL_PREFIX}:${V6_BRIDGE_SUFFIX_HEX}"
V6_SUBNET="${V6_POOL_PREFIX}:0/${V6_PREFIX_LEN}"
# nix list of DNS servers: "1.1.1.1" "8.8.8.8"
DNS_NIX_LIST=$(printf '"%s" ' $DNS | sed 's/ *$//')

# --- build the sed program ---------------------------------------------------
declare -a SED_ARGS=()
while IFS='=' read -r key value; do
    key="${key%%[[:space:]]*}"
    case "$key" in ''|\#*) continue ;; esac
    value="${value%$'\r'}"
    SED_ARGS+=(-e "s|@@${key}@@|${value}|g")
done < "$CONF"
for kv in \
    "DHCP_V4_RANGE=$DHCP_V4_RANGE" \
    "HOST_IPV6=$HOST_IPV6" \
    "V6_BRIDGE_ADDRESS=$V6_BRIDGE_ADDRESS" \
    "V6_SUBNET=$V6_SUBNET" \
    "DNS_NIX_LIST=$DNS_NIX_LIST" ; do
    SED_ARGS+=(-e "s|@@${kv%%=*}@@|${kv#*=}|g")
done

# --- render templates --------------------------------------------------------
mkdir -p "$OUT/bin"
for tpl in "$TEMPLATES"/*.tpl; do
    base=$(basename "$tpl" .tpl)
    if [ "$base" = "configuration.nix" ]; then
        dest="$OUT/configuration.nix"
        sed "${SED_ARGS[@]}" "$tpl" > "$dest"
    else
        dest="$OUT/bin/$base"
        sed "${SED_ARGS[@]}" "$tpl" > "$dest"
        chmod 0755 "$dest"
    fi
    echo "rendered -> $dest"
done

# --- site-independent helpers (Path B) --------------------------------------
for s in incus-ct-create.sh incus-ct-init.sh incus-ct-init-inner.sh incus-ct-info.sh \
         incus-ct-delete.sh incus-ct-flush-lease.sh probe-host.sh ; do
    [ -f "$HERE/$s" ] || continue
    install -m 0755 "$HERE/$s" "$OUT/bin/$s"
    echo "copied   -> $OUT/bin/$s"
done

cp -f "$CONF" "$OUT/site.conf.used"

# --- leftover token check ----------------------------------------------------
leftovers=$(grep -Rho '@@[A-Za-z0-9_]*@@' "$OUT" 2>/dev/null | sort -u || true)
if [ -n "$leftovers" ]; then
    echo "error: unresolved tokens in rendered output:" >&2
    echo "$leftovers" >&2
    exit 1
fi

echo
echo "OK. deploy set: $OUT"
echo "  configuration.nix -> target /etc/nixos/configuration.nix"
echo "  bin/*             -> target /usr/local/bin/ (chmod 0755)"
echo "  bin/rebuild-detached.sh bin/fix-first-switch.sh bin/rollback-net.sh -> target /root/"
