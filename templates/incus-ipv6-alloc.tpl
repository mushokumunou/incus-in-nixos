#!/usr/bin/env python3
"""incus-ipv6-alloc — random unique IPv6 allocator for Incus instances.

Pool:      <POOL_PREFIX>:0/112   (last 16 bits vary)
Excluded:  host primary, N reserved host /128s, bridge gateway, edge values.

Bridged architecture note: containers answer ND directly on the L2 bridge,
so no NDP proxy entries are needed on the uplink (unlike the old routed
setup). This script is pure allocation + state management.

Guarantees:
  - random pick from the free pool (cryptographically uniform)
  - unique: two instances can never share an address (flock-protected state)
  - stable: an instance keeps its address across restarts
  - reclaimable: release on delete, or reconcile auto-frees orphans
  - assigned via Incus static DHCPv6 lease (device ipv6.address) — the
    instance must be on a managed bridge network with stateful DHCPv6

State:     /var/lib/incus/ipv6-allocations.json  (atomic writes, flock)

Usage:
  incus-ipv6-alloc alloc <instance>     # print (or re-print) the instance's address
  incus-ipv6-alloc show <instance>      # print current allocation
  incus-ipv6-alloc release <instance>   # free the allocation back to the pool
  incus-ipv6-alloc list                 # dump all allocations
  incus-ipv6-alloc status               # pool usage summary
  incus-ipv6-alloc reconcile            # free entries whose instance no longer exists

Install:  cp to /usr/local/bin/incus-ipv6-alloc && chmod +x
Requires: python3. On NixOS run via systemd timer with path = [ pkgs.python3 pkgs.incus ].
"""

import fcntl
import glob
import ipaddress
import json
import os
import secrets
import sys

# ============ EDIT THESE FOR YOUR NETWORK ============
POOL_PREFIX = "@@V6_POOL_PREFIX@@"  # first 7 hextets (last varies)
HOST_RESERVED = [ ]  # extra fixed host /128 suffixes (hex), e.g. [0x212, 0x2a8]
HOST_PRIMARY = 0x@@V6_HOST_SUFFIX_HEX@@   # host's own native /128 inside the pool
GATEWAY = 0x@@V6_BRIDGE_SUFFIX_HEX@@          # bridge address (pool gateway)
# =====================================================

STATE_FILE = "/var/lib/incus/ipv6-allocations.json"
LOCK_FILE = STATE_FILE + ".lock"

# suffix 0x0000 = subnet-router anycast, 0xffff avoided for cleanliness
EXCLUDED = set(HOST_RESERVED) | {HOST_PRIMARY, GATEWAY, 0x0000, 0xffff}

LEASES_GLOB = "/var/lib/incus/networks/*/dnsmasq.leases"


def leased_addrs():
    """Addresses the DHCP server still holds in its lease DB.

    A deleted instance's DHCPv6 lease survives in dnsmasq's memory (and in the
    on-disk lease file) for the whole lease time (1h here), and dnsmasq then
    refuses to hand that exact address to a different client — a fresh pin on a
    just-released /128 would silently be replaced by a random one and the
    allocator's bookkeeping would diverge from what the instance actually uses.
    So never allocate a suffix whose address is still leased; it returns to the
    pool by itself once the lease expires (or immediately after
    `systemctl restart incus` / a reboot, which reloads the lease file).
    """
    held = set()
    for path in glob.glob(LEASES_GLOB):
        try:
            with open(path) as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) >= 3:
                        try:
                            held.add(ipaddress.ip_address(parts[2]))
                        except ValueError:
                            continue
        except OSError:
            continue
    return held


def addr(suffix: int) -> str:
    return f"{POOL_PREFIX}:{suffix:x}"


def load() -> dict:
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save(state: dict) -> None:
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, STATE_FILE)


def lock():
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    lf = open(LOCK_FILE, "a+")
    fcntl.flock(lf, fcntl.LOCK_EX)
    return lf


def alloc(name: str) -> str:
    with lock():
        state = load()
        if name in state:
            return addr(state[name])
        used = set(state.values())
        leased = leased_addrs()
        free = [
            i for i in range(0x0001, 0xffff)
            if i not in EXCLUDED
            and i not in used
            and ipaddress.ip_address(addr(i)) not in leased
        ]
        if not free:
            sys.exit(f"error: IPv6 pool exhausted ({len(state)} allocated)")
        suffix = secrets.choice(free)  # random pick, uniform
        state[name] = suffix
        save(state)
        return addr(suffix)


def release(name: str) -> bool:
    with lock():
        state = load()
        if name not in state:
            return False
        del state[name]
        save(state)
        return True


def reconcile() -> int:
    """Free allocations whose Incus instance no longer exists."""
    import subprocess
    try:
        out = subprocess.run(
            ["incus", "list", "--format", "json"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout
        instances = {i["name"] for i in json.loads(out)}
    except Exception as e:
        sys.exit(f"error: cannot list incus instances: {e}")
    with lock():
        state = load()
        stale = [k for k in state if k not in instances]
        for k in stale:
            del state[k]
        if stale:
            save(state)
        return len(stale)


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "alloc":
        if len(sys.argv) < 3:
            sys.exit("usage: incus-ipv6-alloc alloc <instance>")
        print(alloc(sys.argv[2]))
    elif cmd == "show":
        if len(sys.argv) < 3:
            sys.exit("usage: incus-ipv6-alloc show <instance>")
        state = load()
        if sys.argv[2] in state:
            print(addr(state[sys.argv[2]]))
        else:
            sys.exit(f"no allocation for {sys.argv[2]}")
    elif cmd == "release":
        if len(sys.argv) < 3:
            sys.exit("usage: incus-ipv6-alloc release <instance>")
        if release(sys.argv[2]):
            print(f"released {sys.argv[2]}")
        else:
            sys.exit(f"no allocation for {sys.argv[2]}")
    elif cmd == "list":
        state = load()
        for name, suffix in sorted(state.items()):
            print(f"{name}\t{addr(suffix)}")
    elif cmd == "status":
        state = load()
        total = 0xffff - 0x0001 - 1 - len(EXCLUDED)
        held = leased_addrs()
        blocked = sum(
            1 for i in range(0x0001, 0xffff)
            if i not in EXCLUDED and ipaddress.ip_address(addr(i)) in held
        )
        print(f"pool: {POOL_PREFIX}:0/112  (suffixes 0x1..0xfffe)")
        print(f"excluded: {len(EXCLUDED)} ({len(HOST_RESERVED)} host-reserved + host primary + gateway + edges)")
        print(f"allocated: {len(state)}/{total}")
        print(f"held by dnsmasq leases (not handed out): {blocked}")
        for name, suffix in sorted(state.items()):
            print(f"  {name}\t{addr(suffix)}")
    elif cmd == "reconcile":
        n = reconcile()
        print(f"reclaimed {n} stale allocation(s)")
    else:
        sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
