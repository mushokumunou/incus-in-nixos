#!/run/current-system/sw/bin/bash
# incus-ct-delete.sh — delete an instance, release its allocations, verify the pools.
#
#   usage: incus-ct-delete.sh <name>
set -euo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME=${1:?usage: incus-ct-delete.sh <name>}
incus info "$NAME" >/dev/null 2>&1 || { echo "error: no such instance: $NAME" >&2; exit 1; }

echo "== deleting $NAME =="
incus delete "$NAME" --force

/usr/local/bin/incus-ipv4-alloc release "$NAME" 2>/dev/null || echo "(no IPv4 allocation registered)"
/usr/local/bin/incus-ipv6-alloc release "$NAME" 2>/dev/null || echo "(no IPv6 allocation registered)"
systemctl start incus-reconcile.service 2>/dev/null || true

echo; echo "== pool state after delete =="
/usr/local/bin/incus-ipv4-alloc status
/usr/local/bin/incus-ipv6-alloc status
echo; echo "== instances =="
incus list
echo
echo "note: IPv4 is freed immediately. A deleted instance's IPv6 /128 lease stays in"
echo "      dnsmasq for up to ~1h (shown as 'held by dnsmasq leases'); the allocator will"
echo "      not hand that address out until then. To reclaim it right away:"
echo "          incus-ct-flush-lease.sh <that-address>"
echo "      (the .info file /root/incus-ct-${NAME}.info is kept - delete it by hand if unwanted)"
