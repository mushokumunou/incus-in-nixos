#!/run/current-system/sw/bin/bash
# incus-ct-flush-lease.sh — immediately drop leftover DHCP leases for addresses
# whose instance no longer exists (default DHCP lease time is 1h).
#
#   usage: incus-ct-flush-lease.sh <addr> [<addr> ...]
#
# ORDER MATTERS: edit the lease file FIRST, then restart incusd. dnsmasq rewrites
# the file from its own memory, so restarting first achieves nothing. Running
# containers are not interrupted by the restart.
set -euo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ $# -ge 1 ] || { echo "usage: incus-ct-flush-lease.sh <addr> [<addr> ...]" >&2; exit 2; }

changed=0
for L in /var/lib/incus/networks/*/dnsmasq.leases; do
    [ -r "$L" ] || continue
    for a in "$@"; do
        if grep -qE "(^|[[:space:]])${a}([[:space:]]|$)" "$L"; then
            cp -f "$L" "${L}.bak.$(date +%s)"
            grep -vE "(^|[[:space:]])${a}([[:space:]]|$)" "$L" > "${L}.tmp"
            cp -f "${L}.tmp" "$L"
            rm -f "${L}.tmp"
            echo "removed $a from $L"
            changed=1
        fi
    done
done

if [ "$changed" = 0 ]; then
    echo "nothing to do: none of the given addresses is in a lease file"
    exit 0
fi

echo "== restarting incusd so dnsmasq reloads the cleaned lease file =="
systemctl restart incus
sleep 10
systemctl is-active incus

echo; echo "== remaining lease entries =="
for L in /var/lib/incus/networks/*/dnsmasq.leases; do
    [ -r "$L" ] || continue
    echo "-- $L"; cat "$L" || true
done

echo; echo "== allocator view =="
/usr/local/bin/incus-ipv4-alloc status
/usr/local/bin/incus-ipv6-alloc status
