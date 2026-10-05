#!/run/current-system/sw/bin/bash
# rebuild-detached.sh — non-interactive OS upgrade + rebuild for the Incus host.
#
#   1. refresh the flake (latest nixpkgs -> latest kernel + Incus)
#   2. BUILD first (no activation) so eval/build errors leave SSH alive
#   3. switch (the network is rebuilt around incusbr0; SSH drops briefly)
#   4. watchdog: if the bridge never gets the host address, fall back to flat
#      <IFACE> networking so the machine stays reachable (and undo the fallback
#      if the bridge comes up late)
#
# Run detached (survives SSH drops):
#    systemd-run --unit=incus-stack-upgrade --collect \
#        /run/current-system/sw/bin/bash /root/rebuild-detached.sh
#
# NixOS notes: there is no /bin/bash and a systemd-run service starts with a
# minimal PATH, hence the absolute shebang + explicit PATH. The pre-switch
# system may have flakes disabled, hence NIX_CONFIG.
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin
export NIX_CONFIG="experimental-features = nix-command flakes"

HOST_IPV4="@@HOST_IPV4@@"
LAN_GATEWAY="@@LAN_GATEWAY@@"
IFACE="@@IFACE@@"
FLAKE_REF="@@FLAKE_REF@@"

LOG=/root/rebuild-$(date +%F_%H%M%S).log
exec >>"$LOG" 2>&1
set -x
date

cd /etc/nixos || exit 1

nix flake update
echo "FLAKE_UPDATE_EXIT=$?"

nixos-rebuild build --flake "$FLAKE_REF"
BUILD_EXIT=$?
echo "BUILD_EXIT=$BUILD_EXIT"
if [ "$BUILD_EXIT" != 0 ]; then
  echo "BUILD_FAILED_ABORT"
  exit 1
fi

nixos-rebuild switch --flake "$FLAKE_REF"
echo "REBUILD_EXIT=$?"
date

have_bridge_addr() {
  ip -4 -o addr show incusbr0 2>/dev/null | awk '{print $4}' | grep -qF "$HOST_IPV4/"
}

ok=0
for i in $(seq 1 60); do
  if have_bridge_addr; then ok=1; echo "BRIDGE_ADDR_OK after $((i * 10))s"; break; fi
  sleep 10
done

if [ "$ok" = 0 ]; then
  echo "WATCHDOG: incusbr0 has no $HOST_IPV4 after 600s -> restoring $IFACE networking"
  ip link set "$IFACE" nomaster 2>/dev/null
  ip addr add "$HOST_IPV4/24" dev "$IFACE" 2>/dev/null
  ip route replace default via "$LAN_GATEWAY" dev "$IFACE" 2>/dev/null
  echo "WATCHDOG_REPAIR_DONE"
fi

for i in $(seq 1 30); do
  if have_bridge_addr; then
    if ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | grep -qF "$HOST_IPV4/"; then
      echo "BRIDGE_UP_LATE: removing $IFACE fallback address/route"
      ip route del default via "$LAN_GATEWAY" dev "$IFACE" 2>/dev/null
      ip addr del "$HOST_IPV4/24" dev "$IFACE" 2>/dev/null
    fi
    break
  fi
  sleep 10
done

echo "SCRIPT_DONE=$(date)"
