#!/run/current-system/sw/bin/bash
# probe-host.sh — read-only environment probe; prints suggested site.conf values.
# Run on the target host, or: ssh root@host 'bash -s' < probe-host.sh
set -u
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "== identity =="
hostname; (nixos-version 2>/dev/null || echo "nixos-version: n/a"); uname -r
systemd-detect-virt 2>/dev/null; uptime

echo; echo "== interfaces =="; ip -br a
echo; echo "== routes =="; ip r; ip -6 r 2>/dev/null
echo; echo "== dns =="; cat /etc/resolv.conf 2>/dev/null
echo; echo "== resources =="; df -h / | tail -1; nproc; free -h | head -2; swapon --show 2>/dev/null

echo; echo "== existing nixos config (keep stateVersion!) =="
grep -nE "stateVersion|hostName|useDHCP|networkmanager|system.stateVersion" /etc/nixos/configuration.nix 2>/dev/null | head -20
echo "-- hardware-configuration.nix device hints --"
grep -nE "device|fsType" /etc/nixos/hardware-configuration.nix 2>/dev/null | head -8

echo; echo "== pve/debian template hints (if present) =="
grep -nE "^iface|address|gateway|post-up ip route" /etc/network/interfaces 2>/dev/null | head -20

echo; echo "== incus present? =="
command -v incus >/dev/null 2>&1 && incus version || echo "incus: not installed"
ls -d /var/lib/incus 2>/dev/null || true
command -v python3 >/dev/null 2>&1 && echo "python3: $(python3 -V)" || echo "python3: MISSING (allocators need it)"
ls -d /usr/local/bin 2>/dev/null || echo "/usr/local/bin: does not exist yet"

echo; echo "== suggested site.conf values (verify by hand!) =="
IF=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2; exit}')
V4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1)
GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
V6=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1)
V6GW=$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}')
echo "IFACE=$IF   HOST_IPV4=$V4   LAN_GATEWAY=$GW"
echo "LAN_PREFIX=$(printf '%s' "$V4" | cut -d. -f1-3)   POOL_V4_START=2   POOL_V4_END=99"
if [ -n "${V6:-}" ]; then
    echo "HOST_IPV6=$V6   -> V6_POOL_PREFIX=$(printf '%s' "$V6" | cut -d: -f1-7)   V6_HOST_SUFFIX_HEX=$(printf '%s' "$V6" | awk -F: '{print $NF}')"
else
    echo "HOST_IPV6: none configured -> ask the hypervisor/operator for the routed IPv6 prefix + gateway"
fi
echo "V6_GATEWAY=${V6GW:-<unknown>}"
echo
echo "STATE_VERSION: copy the value from the grep above (do NOT invent it)"
