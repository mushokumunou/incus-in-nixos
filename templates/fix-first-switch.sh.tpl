#!/run/current-system/sw/bin/bash
# fix-first-switch.sh — repair the very first switch from a stock NixOS config to
# the bridged Incus config. Idempotent. Run detached:
#
#   systemd-run --unit=fix-first-switch --collect \
#       /run/current-system/sw/bin/bash /root/fix-first-switch.sh
#
# Why: the stock config usually has NetworkManager managing IFACE; its leftovers
# (addresses/routes) make incus-preseed fail with
#   "Only unconfigured network interfaces can be bridged"
# and a hand-edited /etc/resolv.conf makes network-local-commands fail with
#   "resolvconf: signature mismatch".
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin

HOST_IPV4="@@HOST_IPV4@@"
LAN_GATEWAY="@@LAN_GATEWAY@@"
IFACE="@@IFACE@@"

LOG=/root/fixnet-$(date +%F_%H%M%S).log
exec >>"$LOG" 2>&1
set -x
date

# 1) let resolvconf own /etc/resolv.conf again
resolvconf -u || true

# 2) IFACE must be UNCONFIGURED for Incus to accept it as a bridge port
systemctl stop NetworkManager 2>/dev/null || true
ip -4 addr flush dev "$IFACE"
ip -6 addr flush dev "$IFACE" scope global 2>/dev/null || true
ip route flush dev "$IFACE" 2>/dev/null || true
ip -6 route flush dev "$IFACE" 2>/dev/null || true
sleep 2
ip -br a

# 3) create / re-apply the managed bridge network and its host addresses
systemctl reset-failed incus-preseed.service incus-bridge-tune.service 2>/dev/null
systemctl restart incus-preseed.service
PRESEED_EXIT=$?
sleep 5
systemctl restart incus-bridge-tune.service
TUNE_EXIT=$?
sleep 5
echo "PRESEED_EXIT=$PRESEED_EXIT TUNE_EXIT=$TUNE_EXIT"
ip -br a
ip r
ip -6 r

# 4) no-lockout guarantee: restore flat IFACE networking if the bridge is not up
if ! ip -4 -o addr show incusbr0 2>/dev/null | awk '{print $4}' | grep -qF "$HOST_IPV4/"; then
  echo "PRESEED_FAILED_FALLBACK"
  ip link set "$IFACE" nomaster 2>/dev/null || true
  ip addr add "$HOST_IPV4/24" dev "$IFACE"
  ip route replace default via "$LAN_GATEWAY" dev "$IFACE"
else
  echo "BRIDGE_HOST_ADDR_OK"
fi

echo "FIXNET_DONE=$(date)"
