# Pitfall list (symptom / root cause / fix)

## 1. NixOS has no `/bin/bash`
- Symptom: a script produces no output and no log; `journalctl` only shows
  `Failed to execute ...: No such file or directory` or
  `bad interpreter: No such file or directory`.
- Root cause: `/bin` on NixOS only contains `sh`; bash lives in
  `/run/current-system/sw/bin/bash`.
- Fix: use the shebang `#!/run/current-system/sw/bin/bash`.

## 2. The PATH of a systemd service is minimal
- Symptom: `#!/usr/bin/env bash` fails inside a `systemd-run` environment with
  `env: 'bash': No such file or directory`; even when bash is found, `date`/`seq`/`ip`/`grep`
  may not be.
- Fix: start the script with
  `export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin`.

### 2b. The same pitfall in the Path B scripts (fixed in this package)
- Symptom: running the create script via
  `systemd-run ... /usr/local/bin/incus-ct-create.sh` logs only
  `env: 'bash': No such file or directory` and no container is created.
- Root cause: the script shebang was `#!/usr/bin/env bash`, but a `systemd-run` service
  starts with a minimal PATH, so `env` cannot find `bash` (NixOS keeps bash in
  `/run/current-system/sw/bin/`).
- Rule: every script that **runs on the host** uses
  `#!/run/current-system/sw/bin/bash` and exports the PATH shown above immediately after
  `set`; scripts that run inside a container (Debian) keep `#!/usr/bin/env bash`.

## 3. A background rebuild fails silently / nothing ran once ssh dropped
- Symptom: after `setsid nohup ... &` there is no log file at all, as if the script never ran.
- Root cause: a bad shebang, PATH or stdio kills the process immediately, and `&` hides the
  error.
- Fix: `systemd-run --unit=<name> --collect /run/current-system/sw/bin/bash /root/x.sh`,
  and let the script write its own log with `exec >>"$LOG" 2>&1`; inspect it with
  `journalctl -u <name>`.

## 4. Flake experimental features are disabled in a stock configuration
- Symptom: `nix flake update` / `nixos-rebuild --flake` report
  `experimental Nix feature 'nix-command' is disabled`.
- Fix: `export NIX_CONFIG="experimental-features = nix-command flakes"` (the nix invoked by
  `nixos-rebuild` inherits it). The rendered configuration enables both features as well, so
  the environment variable is only a bridge for the first switch.

## 5. First-switch preseed failure: `Only unconfigured network interfaces can be bridged`
- Symptom: `incus-preseed.service` failed; `REBUILD_EXIT=4`; no host address on the bridge.
- Root cause: the stock configuration manages `IFACE` with NetworkManager, so when the
  switch happens the old address/routes are still on the interface (stopping NM does not
  remove them), and Incus only accepts an interface with no configuration as a bridge port.
- Fix: `fix-first-switch.sh`:
  `ip -4 addr flush dev $IFACE`, `ip -6 addr flush dev $IFACE scope global`,
  `ip route flush dev $IFACE`, `ip -6 route flush dev $IFACE`
  → `systemctl reset-failed incus-preseed incus-bridge-tune` → `restart incus-preseed` →
  `restart incus-bridge-tune` → no-lockout check (if the bridge has no address, detach
  `IFACE` from the bridge and restore the flat address).
- **The fallback is mandatory**: at the moment of the flush the host's only IP is no longer
  on any usable interface while the bridge does not exist yet, so a mistake there means total
  loss of access.

## 6. `network-local-commands.service` failed: `resolvconf: signature mismatch`
- Root cause: `/etc/resolv.conf` was edited by hand to install packages.
- Fix: `resolvconf -u`, then
  `systemctl reset-failed network-local-commands && systemctl restart network-local-commands`.
  Afterwards `networking.nameservers` takes over normally.

## 7. Host IPv6 address on the wrong interface -> all IPv6 (host and containers) dies
- Symptom: the peer is INCOMPLETE in `ip -6 neigh`; pings fail; containers get no IPv6.
- Root cause: the upstream gateway's NA frames are addressed to the **bridge MAC** and enter
  the stack through `incusbr0`; when the address is bound to the bridge port (`IFACE`) the
  kernel ignores an NA arriving on `incusbr0` for a bridge-port address.
- Fix: bind every host IPv6 `/128` with `ip -6 addr add ... dev incusbr0`; default route
  `ip -6 route replace default via <V6_GATEWAY> dev incusbr0` (IPv4 likewise: a nexthop must
  be on the same interface as the connected route).

## 8. A NIC from a profile cannot be changed with `device set`
- Symptom: `Device from profile(s) cannot be modified for individual instance`.
- Fix: `incus config device override <i> eth0 ipv4.address=... ipv6.address=...` (override
  first), then `incus restart <i>` for the pin to actually take effect.

## 9. A storage `size` in the preseed breaks preseed after auto-growth
- Symptom: `Pool cannot be shrunk`.
- Root cause: a btrfs loop pool can only grow; the preseed is replayed on every boot, so a
  fixed size tries to shrink the pool back.
- Fix: leave `storage_pools[].config` empty in the preseed and let
  `incus-pool-autogrow` own the size.

## 10. `incus storage info <pool> --format json` can be empty
- Fix: the scripts fall back to parsing the two human-readable lines `space used:` /
  `total space:` (already implemented in this package).
- Growth measured live: on a btrfs loop pool `incus storage set <pool> size=78GiB` reported
  `total space` 78GiB while only a few hundred MiB were actually used (sparse file) and no
  container was interrupted.

## 11. `/etc/systemd/system/` is not writable on NixOS
- Symptom: scp to `/etc/systemd/system/x.service` reports `dest open ... Failure`.
- Fix: use `systemd-run` for temporary services and put persistent services into
  `configuration.nix`.

## 12. Containers cannot `swapon` and cannot change kernel sysctls
- An unprivileged LXC container lacks `CAP_SYS_ADMIN`, so `swapon` fails; BBR and
  `fs.file-max` are host-level parameters.
- Fix: `incus config set <i> limits.memory.swap=true` (swap out to the host), and do all
  performance tuning in the host's `configuration.nix`.

## 13. A freed IPv6 /128 keeps a 1h lease tail (easily mistaken for "the IP is unusable")
- Symptom: after deleting an instance `incus-ipv4-alloc status` is clean, but pinning the
  **same v6 /128** to a new instance makes the new instance silently receive **another**
  address; `incus list` shows an address that disagrees with the pin in
  `incus config show`.
- Root cause: DHCPv6 is stateful, and the deleted instance's lease is still in dnsmasq's
  memory and in `dnsmasq.leases` (1h by default); dnsmasq does not hand an address already
  leased to a different DUID to anyone else, so the pin falls through.
- Fix (built in): before allocating, the allocator reads
  `/var/lib/incus/networks/*/dnsmasq.leases` and skips addresses that are still leased;
  `status` prints `held by dnsmasq leases (not handed out): N`.
- Immediate reclaim: `incus-ct-flush-lease.sh <addr>` = delete that line from the lease file
  **and then** `systemctl restart incus`. **The order matters**: dnsmasq rewrites the file
  from memory, so restarting without cleaning first achieves nothing (observed: the removed
  line reappears immediately).
- Evidence (from this package's validation): IPv4 was reusable seconds after deletion; IPv6
  reused while the lease was still alive was replaced by a different address, and after
  cleaning the file plus restarting incusd the same address could be pinned again.

## 14. `dnsmasq.hosts` is a directory, not a file
- One file per instance: `dnsmasq.hosts/<inst>.eth0`, containing
  `<mac>,<v4>,[<v6>],<name>`.
- `grep <addr> dnsmasq.hosts` never matches anything, so do not use it to conclude that
  "there is no static lease".

## 15. Container root password login fails: the PAM helper cannot verify passwords in an unprivileged container
- Symptom: inside the container `passwd -S root` shows a password and
  `pamtester sshd root authenticate` succeeds as root, yet `ssh -4 root@<ct>` always answers
  `Permission denied, please try again.`; `journalctl -u ssh` inside the container shows
  `unix_chkpwd: password check failed for user (root)` followed by
  `pam_unix(sshd:auth): authentication failure`.
- Root cause: sshd's pre-auth child process runs as the **unprivileged sshd user**, so
  pam_unix cannot read `/etc/shadow` directly and falls back to the helper
  `/usr/sbin/unix_chkpwd` (setgid shadow on Debian); on some image/kernel combinations that
  helper fails to verify the password, regardless of the password itself.
- Fix (built in, not guesswork): after writing the sshd configuration the container init
  **performs a real password login against 127.0.0.1 with sshpass**; if that fails it writes
  `UsePAM no` (letting sshd verify `/etc/shadow` itself) into
  `/etc/ssh/sshd_config.d/99-ct-init.conf`, restarts ssh and self-tests again, then prints the
  mode in use: `password login self-test: OK (PAM)` or `OK (UsePAM no fallback)`.
- Manual diagnosis order: `sshd -T | grep -Ei "usepam|passwordauthentication|permitrootlogin"`,
  then
  `printf '<pw>\n' | setpriv --reuid=sshd --regid=sshd --clear-groups /usr/sbin/unix_chkpwd root nonull; echo $?`
  (0 = verified, 7 = shadow was read but the password does not match, 1 = shadow could not be
  read at all).
- Note: `UsePAM no` is a trade-off — pam_limits and pam_systemd no longer apply (usually
  irrelevant inside a container). To keep PAM, make `unix_chkpwd` work in your environment.

## 16. Two Incus CLI details that are easy to trip over
- `incus snapshot list <i> --format csv` has **no header row**: do not use `tail -n +2` to
  "skip the header", or the only snapshot is dropped from the parse (the report then shows
  `snapshots : none` although the snapshot exists).
- `incus config set <i> <key> <value>` is deprecated and warns on every call; use
  `incus config set <i> <key>=<value>` (including `limits.cpu=4`, `limits.memory=4GiB`).
