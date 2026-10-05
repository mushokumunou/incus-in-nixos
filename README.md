# incus-in-nixos

**A Hermes Agent skill that turns a bare NixOS host into an Incus host — and then manages its containers for you.**

Two paths ship in one skill:

- **Path A** — from a freshly installed NixOS to a working Incus host: server init, OS upgrade, declarative Incus, bridged LAN IPv4 plus a routed IPv6 pool with random, unique, reclaimable addresses.
- **Path B** — container CRUD. Every container is created **already initialised** (root user, random 8-character password, sshd) and a server-info block is printed for you.

All scripts and the NixOS configuration are **rendered from a single `site.conf`**. The package ships no site-specific data: no real IPs, no passwords, no hostnames.

---

## Architecture

```
upstream gateway (LAN router / hypervisor host)
   └── vmbr / physical L2
        └── IFACE (physical NIC enslaved into the bridge; pure L2, no address, link-local only)
             └── incusbr0 (Incus managed bridge)
                  addresses: host IPv4/24 + host native IPv6 /128 + pool gateway /112
                  dnsmasq: DHCPv4 (bounded range, gateway = upstream) + stateful DHCPv6 + RA
                  veth x N (= container eth0, same L2 as host and upstream VMs)
```

- Container IPv4 comes from the LAN segment at random (the pool avoids the upstream's statically assigned ranges) and the container's default route points straight at the upstream gateway — **no NAT on this host**.
- Container IPv6 comes from the `/112` routed to this host, at random, and is reachable from the outside.
- Addresses are managed by two allocators: **random, unique, stable, reclaimable**. The `incus-reconcile` timer reclaims addresses of deleted instances, and `incus-pool-autogrow` grows the storage pool on demand.
- Exactly three things are fixed: the host's own IPv4, the host's native IPv6 `/128`, and the upstream static range (the pool never covers it).

## Requirements

- NixOS with flakes enabled and systemd (validated on 26.11 / unstable)
- Host networking: an IPv4 LAN gateway, an IPv6 prefix routed to this host (usually a `/112`), and a physical NIC that can be enslaved into a bridge
- `python3` on the host (used by the allocators and the container self-test; Path A installs it via `environment.systemPackages`)

## Install into Hermes

```bash
git clone https://github.com/mushokumunou/incus-in-nixos.git \
  ~/.hermes/skills/infrastructure/incus-in-nixos
```

- If a skill with the same name already exists there, move it aside first — this package replaces it.
- No registration step: Hermes loads `SKILL.md` automatically when a matching task comes up.
- Humans can read the repository directly: `SKILL.md` is the entry point, `references/` holds the step-by-step runbooks and the pitfall list.

## Quick start

### Path A — bare NixOS to a complete Incus host

```bash
# 0) read-only probe (prints suggested site.conf values)
ssh root@<host> 'bash -s' < scripts/probe-host.sh

# 1) fill in the parameters and render (run on the control machine; missing values
#    or leftover placeholders are hard errors)
cp scripts/site.conf.example /root/incus-site.conf && $EDITOR /root/incus-site.conf
scripts/render-site.sh /root/incus-site.conf /root/incus-rendered

# 2) push to the host (back up the stock configuration first)
H=root@<host>; P=<ssh-port>
ssh -p $P $H 'mkdir -p /root/backup-$(date +%F) /usr/local/bin; cp -n /etc/nixos/configuration.nix /root/backup-$(date +%F)/configuration.nix.orig'
scp -P $P /root/incus-rendered/configuration.nix $H:/etc/nixos/configuration.nix
scp -P $P /root/incus-rendered/bin/* $H:/usr/local/bin/
scp -P $P /root/incus-rendered/bin/{rebuild-detached.sh,fix-first-switch.sh,rollback-net.sh} $H:/root/
ssh -p $P $H 'chmod 0755 /usr/local/bin/* /root/*.sh'

# 3) upgrade the OS and rebuild (detached: build first, switch only if the build is clean)
ssh -p $P $H 'systemd-run --unit=incus-stack-upgrade --collect /run/current-system/sw/bin/bash /root/rebuild-detached.sh'
ssh -p $P $H 'tail -f /root/rebuild-*.log'   # FLAKE_UPDATE_EXIT=0 -> BUILD_EXIT=0 -> REBUILD_EXIT=0 -> BRIDGE_ADDR_OK

# 4) if the very first switch hits the preseed/resolvconf failures (common when coming
#    from a stock NetworkManager config), run the idempotent repair
ssh -p $P $H 'systemd-run --unit=fix-first-switch --collect /run/current-system/sw/bin/bash /root/fix-first-switch.sh'
```

Then work through the host checklist in `references/verification-checklist.md` and reboot once to confirm self-healing (the bridge, host addresses and routes are rebuilt automatically).

### Path B — container CRUD (created already initialised)

```bash
incus-ct-create.sh web1                        # Debian 13, 4 vCPU, 4GiB, 10GiB, snapshot
incus-ct-create.sh db1 --cpu 8 --mem 8GiB --disk 40GiB
incus-ct-create.sh probe1 --no-init --no-snapshot

incus-ct-info.sh web1 [password]               # print the server-info block
incus snapshot create web1 <snap>              # snapshot; rollback: incus stop web1 && incus snapshot restore web1 <snap>
incus-ct-delete.sh web1                        # delete + release + verify the pools
incus-ct-flush-lease.sh <addr>                 # reclaim a leftover DHCP lease immediately (instead of waiting ~1h)
```

Creation order: create, then limits (`limits.cpu`, `limits.memory`, `limits.memory.swap=true`, `security.nesting=true`), root volume quota, allocator picks v4/v6 and pins them to eth0 with `incus config device override`, start, wait until the pinned addresses really appear, **in-container init**, snapshot, then print the server info and save it to `/root/incus-ct-<name>.info` (mode 0600).

**What the in-container init does** (idempotent):

1. hostname = instance name, `/etc/hosts` gets a `127.0.1.1` entry
2. timezone UTC and `localedef en_US.UTF-8`
3. `apt-get update && apt-get upgrade` plus base packages (openssh-server, curl, ca-certificates, sudo, locales, tzdata, procps, less; dnf/apk branches included)
4. **root password: random 8 characters** (mixed case letters and digits, at least one of each; a password may also be passed in)
5. sshd configured via `/etc/ssh/sshd_config.d/99-ct-init.conf` to allow root and password logins, followed by a **real loopback password-login self-test**; if that fails the script falls back to `UsePAM no` automatically (which works around the PAM helper `unix_chkpwd` being unable to verify passwords in some unprivileged containers) and prints which mode is in use
6. NTP (`systemd-timesyncd`) and a self-check block (hostname, kernel, addresses, sshd state, `readlink -f /bin/sh`)
7. `/bin/sh` is left untouched (the image keeps its own dash; scripts always carry a shebang)

Example server info:

```
============================================================
 container : web1  (RUNNING)
 hostname  : web1
 IPv4 (LAN): 10.10.10.50/24
 IPv6 (WAN): 2001:db8:1234:5678:9abc:0:50:2a/128
 pinned    : v4=10.10.10.50  v6=2001:db8:1234:5678:9abc:0:50:2a
 login     : root@10.10.10.50   password: Xy7Qm2Kd
   ssh -4 root@10.10.10.50
   ssh -6 root@2001:db8:1234:5678:9abc:0:50:2a
 resources : cpu=4 mem=4GiB swap=true nesting=true disk=10GiB
 snapshots : initial-20261005
 allocator : v4=10.10.10.50 v6=2001:db8:1234:5678:9abc:0:50:2a
============================================================
```

## Address pools and reclaim: three hard rules

1. **IPv4 is freed immediately.** Deleting an instance releases its lease right away, so the same address can be pinned to a new instance at once.
2. **A freed IPv6 `/128` has a ~1h lease tail.** The deleted instance's DHCPv6 lease stays in dnsmasq for the lease time; pinning that exact `/128` to a new instance during that window would be **silently replaced by another address**. The allocator therefore implements a **lease guard**: `alloc` skips any address that is still in the lease table, `status` prints `held by dnsmasq leases (not handed out): N`, and the address returns to the pool once the lease expires.
3. **To reclaim immediately:** `incus-ct-flush-lease.sh <addr>` — remove that line from `dnsmasq.leases` **first**, then restart incusd. The order matters: dnsmasq rewrites the file from memory, so restarting without cleaning first achieves nothing. Running containers are not interrupted by the restart.

After every delete: confirm `incus list` no longer shows the instance, both `*-alloc status` are back to the base count with clean state files, `dnsmasq.leases` has no entry for the address (or it is knowingly held by a lease), and **pin the address to a throwaway instance to prove it is truly usable**.

## Security notes

- Containers receive **public IPv6 addresses** and the host firewall is disabled (bridged forwarding requires it), so any port a container listens on is reachable from the internet over IPv6.
- The host's own IPv6 `/128` is publicly reachable too. `PermitRootLogin yes` is a delivery convenience: switch to key-based logins for production.
- Container MAC addresses never appear on the physical wire (the bridge lives inside the host), which keeps platforms that limit MACs per port (Hetzner and similar) happy.

## Troubleshooting

`references/pitfalls.md` collects every failure encountered while building this, with symptom, root cause and fix. Highlights:

- NixOS has **no `/bin/bash`** and systemd services run with a minimal PATH, so scripts need an absolute shebang plus an explicit `PATH` export
- Detached rebuilds and container creation must run under `systemd-run` (not `setsid nohup`), otherwise they fail silently
- First switch: `incus-preseed` fails with `Only unconfigured network interfaces can be bridged` when the stock NetworkManager address is still on the interface
- `resolvconf: signature mismatch` after a manual `/etc/resolv.conf` edit
- Flakes are disabled in a stock configuration, so `NIX_CONFIG` bridges the first rebuild
- Host IPv6 addresses must live on `incusbr0` (on the bridge port the neighbour entry never resolves)
- NICs that come from a profile cannot be changed with `device set`; use `device override`
- preseed must not declare a storage `size` (btrfs cannot shrink)
- Unprivileged containers cannot `swapon` and cannot change most kernel sysctls
- The ~1h DHCPv6 lease tail after deleting an instance (lease guard plus flush)
- `/etc/systemd/system/` is not writable on NixOS

## Validated on

- NixOS 26.11 (unstable), kernel 6.18.x, Incus 7.5.1 (mainline, not LTS)
- Path A: stock configuration replaced by a rendered one, `nix flake update` + build + switch, then a **reboot**: zero failed units, host IPv4 plus native IPv6 `/128` plus pool gateway all on `incusbr0`, the physical NIC link-local only, IPv4 and IPv6 egress both HTTP 200, allocator counts matching the instances
- Path B: create, random v4/v6 pin, in-container init (self-test reported `password login self-test: OK`), snapshot; password SSH into the container from a **different** machine over both IPv4 and IPv6 succeeded, and the container reached the internet over IPv6; after deleting it, IPv4 was reclaimed instantly and IPv6 was protected by the lease guard and reclaimable with the flush helper
- Storage pool online growth (`incus storage set <pool> size=<N>GiB`) with no container downtime (the loop file is sparse)

## Repository layout

```
incus-in-nixos/
├── SKILL.md                          # Hermes skill entry point: both paths
├── README.md                         # this file (English, default)
├── README.ja.md                      # Japanese version
├── references/
│   ├── parameters.md                 # every site.conf key and how to discover it
│   ├── path-a-fresh-nixos.md         # Path A runbook
│   ├── path-b-containers.md          # Path B runbook
│   ├── pitfalls.md                   # failure modes: symptom / root cause / fix
│   └── verification-checklist.md     # host / container / reclaim checklists
├── scripts/
│   ├── probe-host.sh                 # read-only environment probe
│   ├── render-site.sh                # site.conf + templates -> deployable file set
│   ├── site.conf.example             # parameter template (placeholders only)
│   ├── incus-ct-create.sh            # create + pin + init + snapshot + report
│   ├── incus-ct-init.sh              # init driver (generates or accepts the password)
│   ├── incus-ct-init-inner.sh        # in-container init (incl. password self-test/fallback)
│   ├── incus-ct-info.sh              # server info
│   ├── incus-ct-delete.sh            # delete + reclaim + verify
│   └── incus-ct-flush-lease.sh       # reclaim a leftover lease immediately
└── templates/
    ├── configuration.nix.tpl         # declarative: network / pool / profile / systemd units
    ├── incus-ipv4-alloc.tpl          # random, unique, reclaimable IPv4 allocator (lease guard)
    ├── incus-ipv6-alloc.tpl          # random, unique, reclaimable IPv6 allocator (lease guard)
    ├── incus-pool-autogrow.tpl       # storage pool auto-grow (triggers above 80%)
    ├── rebuild-detached.sh.tpl       # flake update + build + switch + network fallback
    ├── fix-first-switch.sh.tpl       # idempotent post-first-switch network repair
    └── rollback-net.sh.tpl           # console fallback: restore flat networking
```

## License

MIT — see `LICENSE`.
