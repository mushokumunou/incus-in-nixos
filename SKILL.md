---
name: incus-in-nixos
description: Use when standing up a NixOS host for Incus or managing its containers. Path A - bare NixOS to init+OS upgrade+declarative Incus with bridged LAN IPv4 and routed IPv6 random/reclaimable pools; Path B - create/list/snapshot/delete containers that are auto-inited (root + random password) with a server report.
---

# NixOS + Incus complete stack (two paths)

A single `site.conf` renders every script and the NixOS configuration. The package
contains no site-specific data (no IPs, passwords or hostnames).
Delivery: install this directory as `~/.hermes/skills/infrastructure/incus-in-nixos/`,
then scp the rendered output to the target host and run it.

## The two paths

| Path | When to use it | Entry |
|------|----------------|-------|
| **A: from zero to complete** | A freshly delivered NixOS host (possibly no DNS, no IPv6) -> server init + OS upgrade + Incus + bridged network + address pools | §Path A |
| **B: container CRUD** | The host is ready; day-to-day create/inspect/snapshot/delete of containers (created already initialised, root with a random 8-character password, server info printed) | §Path B |

## Architecture (one paragraph)

The physical NIC (`IFACE`, e.g. `ens18`) is enslaved into the Incus managed bridge
`incusbr0`; **all host addresses live on the bridge**; containers share the L2 segment
with the host and with every upstream VM/CT; container IPv4 is allocated at random from
the LAN segment (the pool avoids the upstream's static range) and container IPv6 is
allocated at random from the `/112` routed to this host and is externally reachable.
Both are managed by allocators (random / unique / stable / reclaimable); the
`incus-reconcile` timer reclaims addresses of deleted instances and the
`incus-pool-autogrow` timer grows the storage pool on demand.

```
upstream gateway (LAN router / hypervisor host)
   └── vmbr / physical L2
        └── IFACE (bridge port, pure L2, no address, link-local only)
             └── incusbr0 (Incus managed bridge)
                  addresses: host IPv4/24 + host native IPv6 /128 + pool gateway /112
                  dnsmasq: DHCPv4 (bounded range, gateway = upstream) + stateful DHCPv6 + RA
                  veth x N (= container eth0, same L2)
```

**Exactly three things are fixed**: the host's own IPv4, the host's single native IPv6
`/128`, and the upstream static range (the pool never covers it). This skill does **not**
reserve an extra batch of IPv6 `/128`s for the host any more; the container pool only
excludes "host native /128 + pool gateway + edges".

No NAT, no changes to the upstream gateway or firewall, and container MAC addresses never
appear on the physical wire (friendly to Hetzner-style terms of service).

---

# Path A — bare NixOS to a complete Incus host

## A0. Discover the parameters (read-only)

Run `scripts/probe-host.sh` on the target host (or over ssh from the control machine) to
obtain: `IFACE`, `HOST_IPV4`, `LAN_GATEWAY`, `LAN_PREFIX`, the host's native `HOST_IPV6`,
`V6_GATEWAY`, and the **IPv6 pool prefix routed to this machine** (`V6_POOL_PREFIX`,
7 hextets).

- If the host already has the static address from the hypervisor template, dropping the
  last hextet of `HOST_IPV6` yields the pool prefix
  (example: `...:9abc:0:50:50` -> pool prefix `...:9abc:0:50`, `/112`).
- If the host has no IPv6 at all (common on a freshly rolled-back system), ask the
  upstream (the hypervisor's `/etc/network/interfaces` or VM config) or the operator for
  three things: pool prefix/length, upstream IPv6 gateway, host native /128.
  Details and examples: `references/parameters.md`.

## A1. Fill in `site.conf` and render

```bash
cp scripts/site.conf.example /root/incus-site.conf && $EDITOR /root/incus-site.conf
scripts/render-site.sh /root/incus-site.conf /root/incus-rendered
```

The renderer substitutes every `@@KEY@@` (a missing value is a hard error), derives
`HOST_IPV6` / `DHCP_V4_RANGE`, produces `configuration.nix` plus every script under `bin/`,
and finally asserts that no placeholder is left.

## A2. Deploy to the host

```bash
H=root@<host>; P=<ssh port>
scp -P $P /root/incus-rendered/configuration.nix      $H:/etc/nixos/configuration.nix
ssh -p $P $H 'mkdir -p /root/backup-$(date +%F) /usr/local/bin
              cp -n /etc/nixos/configuration.nix /root/backup-$(date +%F)/configuration.nix.orig'
scp -P $P /root/incus-rendered/bin/*                 $H:/usr/local/bin/
scp -P $P /root/incus-rendered/bin/rebuild-detached.sh /root/incus-rendered/bin/rollback-net.sh \
      /root/incus-rendered/bin/fix-first-switch.sh   $H:/root/
scp -P $P /root/incus-rendered/site.conf.used        $H:/root/
ssh -p $P $H 'chmod 0755 /usr/local/bin/* /root/*.sh'
```

## A3. Upgrade the OS and rebuild (build first, then switch; survives disconnects)

```bash
ssh -p $P $H 'systemd-run --unit=incus-stack-upgrade --collect \
  /run/current-system/sw/bin/bash /root/rebuild-detached.sh'
# poll the log: FLAKE_UPDATE_EXIT=0 → BUILD_EXIT=0 → REBUILD_EXIT=0 → BRIDGE_ADDR_OK
ssh -p $P $H 'tail -f /root/rebuild-*.log'
```

Inside the script: `nix flake update` → `nixos-rebuild build` (aborts on failure, so ssh
stays alive) → `switch` → wait for the bridge to obtain the host address (up to 600s); if
it does not, the script detaches `IFACE` from the bridge and restores the flat address so
the machine never becomes unreachable. Read the NixOS trio in `references/pitfalls.md`:
no `/bin/bash`, the minimal PATH of systemd services, and flakes being disabled in the
stock configuration (`NIX_CONFIG`).

## A4. First-switch specific failures

If `incus-preseed` reports `Only unconfigured network interfaces can be bridged`, or
`network-local-commands` reports `resolvconf: signature mismatch`:

```bash
ssh -p $P $H 'systemd-run --unit=fix-first-switch --collect \
  /run/current-system/sw/bin/bash /root/fix-first-switch.sh'
```

Cause and ordering: `references/pitfalls.md` (the leftover address that NetworkManager had
placed on `IFACE`, and a hand-edited `/etc/resolv.conf`). The script is idempotent; when it
finishes, `ip -br a` should show the host address on `incusbr0`.

## A5. Verify (mandatory)

```bash
ssh -p $P $H 'systemctl --failed; incus version; systemctl is-active incus incus-preseed incus-bridge-tune
  ip -br a show incusbr0; ip -br a show <IFACE>; ip r | head -3; ip -6 r | head -3
  /usr/local/bin/incus-ipv4-alloc status; /usr/local/bin/incus-ipv6-alloc status
  curl -s -o /dev/null -w "v4:%{http_code} " -4 https://www.google.com
  curl -s -o /dev/null -w "v6:%{http_code}\n" -6 https://www.google.com'
```

Pass criteria: zero failed units; host IPv4 and native IPv6 `/128` on `incusbr0` with no
global address on `IFACE`; both default routes (v4 and v6) pointing at `incusbr0`; both
allocators at `allocated: 0/N`; v4 and v6 both HTTP 200.
The full checklist is in `references/verification-checklist.md`.

## A6. Reboot self-healing and the fallback

Reboot once, wait 60-90s, then repeat A5 — preseed and bridge-tune rebuild the entire
network automatically (verified). If the host becomes completely unreachable, run
`/root/rollback-net.sh` from the hypervisor console: it detaches `IFACE` from the bridge
and restores flat networking.

---

# Path B — container CRUD (created already initialised)

## Create a container (one command)

```bash
/usr/local/bin/incus-ct-create.sh <name> [--image images:debian/13] [--cpu 4] [--mem 4GiB] \
    [--disk 10GiB] [--snapshot initial-$(date +%Y%m%d)|--no-snapshot] [--no-init]
```

Order of operations: create → limits (cpu/mem/nesting, `limits.memory.swap=true`) → root
volume quota → the allocators pick v4/v6 and `incus config device override` pins them to
eth0 → start → wait until the pinned addresses really appear → in-container init →
snapshot → print the server info and archive it to `/root/incus-ct-<name>.info` (0600).

**What the in-container init does** (idempotent; `incus-ct-init.sh` +
`incus-ct-init-inner.sh`): hostname = instance name, `/etc/hosts` gets a 127.0.1.1 entry,
timezone UTC, locale en_US.UTF-8, `apt update && upgrade` plus base packages
(curl/ca-certificates/sudo/locales/tzdata/procps/less), the `root` password (random 8
characters by default: mixed case letters and digits, at least one of each), sshd (root
login + password login via `/etc/ssh/sshd_config.d/99-ct-init.conf`), NTP, and a final
self-check printing hostname/kernel/addrs/sshd/`readlink -f /bin/sh`.
**`/bin/sh` is left alone** (the image keeps its own dash; scripts always carry a shebang).

## Inspect / snapshot / delete

```bash
/usr/local/bin/incus-ct-info.sh <name> [password]      # print the server info (incl. ssh commands)
incus snapshot create <name> <snap>                    # snapshot
incus stop <name> && incus snapshot restore <name> <snap>   # rollback (Incus 7.x: snapshot restore)
/usr/local/bin/incus-ct-delete.sh <name>               # delete + release allocations + verify the pools
```

## Server info (the format handed to the user)

What `incus-ct-create.sh` / `incus-ct-info.sh` print:

```
============================================================
 container : <name>  (RUNNING)
 hostname  : <name>
 IPv4 (LAN): 10.10.10.32/24
 IPv6 (WAN): 2001:db8:...:2a/128
 pinned    : v4=10.10.10.32  v6=2001:db8:...:2a
 login     : root@10.10.10.32  password: Xy7Qm2Kd
   ssh -4 root@10.10.10.32            # LAN
   ssh -6 root@2001:db8:...:2a/128    # WAN
 resources : cpu=4 mem=4GiB disk=10GiB nesting=true swap=true
 snapshots : initial-20261005
 allocator : v4=10.10.10.32 v6=2001:db8:...:2a
============================================================
```

## Three hard rules for address reclaim

1. **IPv4 is reclaimed on delete**: as soon as the instance is gone dnsmasq drops the
   lease and the same address can immediately be pinned to a new instance.
2. **A freed IPv6 `/128` has a 1h lease tail**: the deleted instance's DHCPv6 lease is
   still inside dnsmasq, and pinning that same `/128` to a new instance during that window
   is silently replaced by a different address -> the allocator carries a **lease guard**:
   `alloc` skips addresses that are still in the lease table, the address returns to the
   pool automatically once the lease expires, and `status` prints an extra
   `held by dnsmasq leases (not handed out): N` line for auditing.
3. **To reclaim immediately** (instead of waiting 1h): `incus-ct-flush-lease.sh <addr>` —
   delete the line from the lease file **first**, then restart incusd (dnsmasq rewrites the
   file from memory, so doing it in the other order achieves nothing). Running containers
   are not interrupted.

After every delete, verify: `incus list` no longer shows the instance → both
`*-alloc status` are back to the base count with clean state json → `dnsmasq.leases` has no
entry for the address (or it is knowingly held by a lease) → **pin that address to a
throwaway instance to prove it is really usable**.

---

# Hard pitfalls (NixOS + Incus)

Reasoning, reproduction and fixes for each item are in `references/pitfalls.md`; only the
conclusions are listed here:

1. NixOS has **no `/bin/bash`**, and a transient systemd service starts with a minimal
   PATH. Scripts must use `#!/run/current-system/sw/bin/bash` and export PATH up front.
2. Use `systemd-run --unit=... /run/current-system/sw/bin/bash /root/x.sh` for
   disconnect-safe background rebuilds; `setsid nohup` fails silently on a bad
   shebang/PATH (no log at all, as if the script never ran).
3. Flakes are disabled in the stock configuration:
   `export NIX_CONFIG="experimental-features = nix-command flakes"`.
4. The stock configuration manages `IFACE` with NetworkManager, so its old address is
   still present after the switch and preseed reports
   `Only unconfigured network interfaces can be bridged`. Fix: `fix-first-switch.sh`
   (flush `IFACE` → `systemctl reset-failed/restart incus-preseed` → `incus-bridge-tune`,
   with a no-lockout fallback at the end).
5. A hand-edited `/etc/resolv.conf` makes `network-local-commands` fail with
   `resolvconf: signature mismatch` → run `resolvconf -u`, then restart that unit.
6. Host IPv6 addresses must live on **`incusbr0`** (on the bridge port the gateway's NA
   frames are addressed to the bridge MAC, so the neighbour entry stays INCOMPLETE
   forever); default-route nexthops must use `dev incusbr0`.
7. `incus config device set <i> eth0 ipv4.address=...` fails for a NIC inherited from a
   profile; use `incus config device override <i> eth0 ipv4.address=... ipv6.address=...`
   and then `incus restart`.
8. Never declare a storage `size` in the preseed (after auto-growth it would be shrunk
   back and btrfs cannot shrink: `Pool cannot be shrunk`).
9. `incus storage info <pool> --format json` is empty on some versions, so scripts fall
   back to parsing `space used:` / `total space:`.
10. `/etc/systemd/system/` is not writable on NixOS (scp reports
    `dest open ... Failure`): use `systemd-run` for temporary services and
    `configuration.nix` for persistent ones.
11. Containers **cannot `swapon`** (unprivileged LXC): use the instance-level
    `limits.memory.swap=true` to swap out to the host.
12. Most sysctls (BBR, `fs.file-max`, ...) are not writable inside an unprivileged
    container; those are **host-level** optimisations that containers simply inherit.

---

# File listing

```
incus-in-nixos/
├── SKILL.md                        # this file: entry point for both paths
├── references/
│   ├── parameters.md               # every site.conf key and how to discover it (with examples)
│   ├── path-a-fresh-nixos.md       # Path A runbook (first-switch repair / self-heal / fallback)
│   ├── path-b-containers.md        # Path B runbook (init menu and report sample)
│   ├── pitfalls.md                 # all pitfalls: symptom / root cause / fix / evidence
│   └── verification-checklist.md   # host / container / reclaim checklists
├── scripts/
│   ├── probe-host.sh               # read-only environment probe, suggests site.conf values
│   ├── render-site.sh              # site.conf + templates -> deployable file set
│   ├── site.conf.example           # parameter template (placeholders only)
│   ├── incus-ct-create.sh          # Path B: create + pin + init + snapshot + report
│   ├── incus-ct-init.sh            # init driver (generates/accepts the password, pushes the inner script)
│   ├── incus-ct-init-inner.sh      # the init body executed inside the container
│   ├── incus-ct-info.sh            # print the server info
│   ├── incus-ct-delete.sh          # delete + reclaim + verify
│   └── incus-ct-flush-lease.sh     # reclaim a leftover lease for an address immediately
└── templates/
    ├── configuration.nix.tpl       # declarative: network / pool / profile / systemd units
    ├── incus-ipv4-alloc.tpl        # random, unique, reclaimable IPv4 allocator (lease guard)
    ├── incus-ipv6-alloc.tpl        # random, unique, reclaimable IPv6 allocator (lease guard)
    ├── incus-pool-autogrow.tpl     # storage pool auto-grow (triggers above 80%, capped at 85% of host free space)
    ├── rebuild-detached.sh.tpl     # flake update + build + switch + network fallback
    ├── fix-first-switch.sh.tpl     # idempotent post-first-switch network repair
    └── rollback-net.sh.tpl         # console fallback: restore flat networking
```

Install: drop the whole `incus-in-nixos/` directory into
`~/.hermes/skills/infrastructure/` (see `README.md` or `/root/output/INSTALL.md`).
