#!/usr/bin/env bash
# rollback-net.sh — emergency recovery, run from the hypervisor console if the
# bridged architecture leaves the host unreachable. Detaches IFACE from the
# bridge and restores flat networking.
set -x
HOST_IPV4="@@HOST_IPV4@@"
LAN_GATEWAY="@@LAN_GATEWAY@@"
IFACE="@@IFACE@@"
ip link set "$IFACE" nomaster 2>/dev/null
ip addr flush dev "$IFACE" 2>/dev/null
ip addr add "$HOST_IPV4/24" dev "$IFACE"
ip link set "$IFACE" up
ip route replace default via "$LAN_GATEWAY" dev "$IFACE"
ip -br addr show "$IFACE"
ip route
