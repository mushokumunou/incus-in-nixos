# Path B runbook: container CRUD (created already initialised)

All commands run on the **host** (the scripts under `/usr/local/bin/`).

## Create

```bash
incus-ct-create.sh web1
incus-ct-create.sh db1 --cpu 8 --mem 8GiB --disk 40GiB --snapshot initial-20261005
incus-ct-create.sh probe1 --no-init --no-snapshot        # create only, no init
```

Internal order (stop on the first failure, never leave a half-built container):
1. `incus create <image> <name>`
2. `limits.cpu` / `limits.memory` / `limits.memory.swap=true` / `security.nesting=true`
3. `incus config device override <name> root size=<disk>`
4. `V4=$(incus-ipv4-alloc alloc <name>)`, `V6=$(incus-ipv6-alloc alloc <name>)`
   → `incus config device override <name> eth0 ipv4.address=$V4 ipv6.address=$V6`
   (a NIC coming from a profile must be overridden first; a plain `device set` reports
   `Device from profile(s) cannot be modified for individual instance`)
5. `incus start` → poll `ip -br a` inside the container until **both pinned addresses
   appear** (up to ~120s); a failure prints a WARNING (see the lease tail in `pitfalls.md`)
6. in-container init (below) → snapshot → `incus-ct-info.sh` prints the report and saves it
   to `/root/incus-ct-<name>.info`

## In-container init (idempotent)

- Driver: `incus-ct-init.sh <name> [password]`
  - without a password argument it generates a **random 8-character** one (mixed case
    letters and digits, at least one of each);
  - the password and container name are written to `/root/.ct-init.conf` (0600) inside the
    container and pushed over, so the password never shows up in `ps`;
  - both temporary files are deleted afterwards; **the password is printed on stdout only**
    (progress goes to stderr).
- Body: `incus-ct-init-inner.sh` (executed inside the container)
  1. identity: hostname = instance name, `/etc/hosts` gets `127.0.1.1 <name>`
  2. timezone UTC + `localedef en_US.UTF-8`
  3. packages: `apt-get update && apt-get upgrade` plus `openssh-server ca-certificates curl
     sudo locales tzdata procps less` (dnf/apk branches included)
  4. the `root` password
  5. sshd: `/etc/ssh/sshd_config.d/99-ct-init.conf` enables root login, password login and
     `KbdInteractiveAuthentication`, then `sshd -t` and `systemctl enable --now ssh`
  6. NTP (`systemd-timesyncd`)
  7. self-check: hostname / kernel / addresses / sshd state / `readlink -f /bin/sh`
- **`/bin/sh` is not modified** (the Debian image keeps dash; scripts always carry a shebang).
- Containers **cannot `swapon`** and must not change host-level sysctls such as BBR or
  `fs.file-max` (those are host-side; containers inherit them).

## Inspect / snapshot / roll back / delete

```bash
incus-ct-info.sh <name> [password]                       # server info
incus list                                               # everything
incus snapshot create <name> <snap>
incus stop <name> && incus snapshot restore <name> <snap>  # Incus 7.x syntax
incus-ct-delete.sh <name>                                # delete + release + verify
```

## Address reclaim (must be verified)

Check right after deleting:

```bash
incus-ct-delete.sh <name>          # already runs reconcile plus both status commands
incus-ipv4-alloc list; incus-ipv6-alloc list
grep -E "<v4>|<v6>" /var/lib/incus/networks/*/dnsmasq.leases
```

- IPv4: the lease is released as soon as the instance is deleted, so
  `held by dnsmasq leases` should drop back to 0 immediately.
- IPv6: the deleted instance's /128 lease stays in dnsmasq for roughly 1h; during that
  window `held by dnsmasq leases: 1` and the allocator will **not** hand it out (lease
  guard); it returns to the pool when the lease expires.
- To reclaim immediately: `incus-ct-flush-lease.sh <v6addr>` (clean the lease file line
  first, then restart incusd).
- Final check: pin that address to a throwaway instance and confirm it **really receives
  the same address** (proof that it is usable and not merely freed on paper), then delete
  the throwaway instance.

## What to hand over

The report for the user contains: container name / hostname, LAN IPv4, WAN IPv6, the
`ssh -4`/`ssh -6` commands, the root password, resource limits, the snapshot name, and a
one-line explanation of how the address is reclaimed after deletion.
