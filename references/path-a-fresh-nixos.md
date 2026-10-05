# Path A runbook: bare NixOS to a complete Incus host

Replace `<HOST>` / `<PORT>` / `<IFACE>` with the real values; every `/root/*.sh` below runs
on the **target host**.

## 0. Probe first if you can reach it

```bash
scripts/probe-host.sh                                  # run locally (if you are on the target)
ssh -p <PORT> root@<HOST> 'bash -s' < scripts/probe-host.sh   # run from the control machine
```

Typical state of a stock NixOS: `networkmanager` installed, one DHCP or static address,
**no nameserver** in `/etc/resolv.conf`, a healthy `systemctl`, and
`/etc/nixos/{configuration.nix,flake.nix,flake.lock,hardware-configuration.nix}` present.

## 1. Give it DNS (otherwise nix cannot fetch anything)

```bash
ssh -p <PORT> root@<HOST> 'printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf; getent hosts cache.nixos.org'
```

## 2. Render

```bash
cp scripts/site.conf.example /root/incus-site.conf && $EDITOR /root/incus-site.conf
scripts/render-site.sh /root/incus-site.conf /root/incus-rendered
```

Rendered output:
```
/root/incus-rendered/configuration.nix
/root/incus-rendered/bin/{incus-ipv4-alloc,incus-ipv6-alloc,incus-pool-autogrow,rebuild-detached.sh,
                          fix-first-switch.sh,rollback-net.sh,incus-ct-*.sh}
/root/incus-rendered/site.conf.used
```

## 3. Push it (back up the stock configuration first)

```bash
H=root@<HOST>; P=<PORT>
ssh -p $P $H 'mkdir -p /root/backup-$(date +%F) /usr/local/bin
  cp -n /etc/nixos/configuration.nix /root/backup-$(date +%F)/configuration.nix.orig
  cp -f /etc/nixos/flake.lock       /root/backup-$(date +%F)/flake.lock.orig'
scp -P $P /root/incus-rendered/configuration.nix $H:/etc/nixos/configuration.nix
scp -P $P /root/incus-rendered/bin/incus-ipv4-alloc /root/incus-rendered/bin/incus-ipv6-alloc \
          /root/incus-rendered/bin/incus-pool-autogrow \
          /root/incus-rendered/bin/incus-ct-*.sh $H:/usr/local/bin/
scp -P $P /root/incus-rendered/bin/rebuild-detached.sh /root/incus-rendered/bin/fix-first-switch.sh \
          /root/incus-rendered/bin/rollback-net.sh $H:/root/
scp -P $P /root/incus-rendered/site.conf.used  $H:/root/
ssh -p $P $H 'chmod 0755 /usr/local/bin/* /root/*.sh'
```

**Why the allocators must land first**: the `ExecStart` of the `incus-reconcile` and
`incus-pool-autogrow` units in `configuration.nix` points at `/usr/local/bin/*`, so a
missing file leaves a failed unit behind on every boot.

## 4. Upgrade the OS and rebuild (disconnect-safe)

```bash
ssh -p $P $H 'systemd-run --unit=incus-stack-upgrade --collect \
                  /run/current-system/sw/bin/bash /root/rebuild-detached.sh'
```

The key lines of `/root/rebuild-<timestamp>.log`, in order, mean success:
`FLAKE_UPDATE_EXIT=0` → `BUILD_EXIT=0` → `REBUILD_EXIT=0` → `BRIDGE_ADDR_OK after Ns` → `SCRIPT_DONE=...`.

- During the switch `IFACE` becomes a bridge port and the host address moves onto the
  bridge, so ssh drops for a few seconds up to tens of seconds. That is normal.
- If the bridge has no host address within 600s the script detaches `IFACE` from the bridge
  and restores the flat address (no-lockout fallback).
- `BUILD_FAILED_ABORT` means evaluation/build failed and there was **no** switch: the
  system is untouched, fix the configuration and run it again.

## 5. First-switch specific failures (almost guaranteed on the first switch from a stock config)

```bash
ssh -p $P $H 'systemd-run --unit=fix-first-switch --collect \
                  /run/current-system/sw/bin/bash /root/fix-first-switch.sh'
ssh -p $P $H 'tail -20 /root/fixnet-*.log'      # expect BRIDGE_HOST_ADDR_OK
```

It does four things: `resolvconf -u` (fixes the signature mismatch), flush `IFACE`'s
v4/v6/routes (leftovers from the old NetworkManager setup), `reset-failed` +
`restart incus-preseed` + `incus-bridge-tune`, and finally the no-lockout check. It is
idempotent and can be re-run.

## 6. Verify and test reboot self-healing

Run the host checklist from `references/verification-checklist.md`. Then:

```bash
ssh -p $P $H 'systemctl reboot'
# wait 60-90s
ssh -p $P $H 'systemctl --failed; ip -br a show incusbr0; ip -br a show <IFACE>; ip r | head -1'
```

After the reboot everything should have healed by itself: the bridge is rebuilt, the host
address is back on the bridge, `IFACE` only has link-local, zero failed units.

## 7. Fallback

If the host becomes completely unreachable, run `/root/rollback-net.sh` from the hypervisor
console (it detaches `IFACE` from the bridge and restores the flat address/default route),
then repeat steps 4-5 once the configuration is fixed.

## 8. What to report

When you are done, report to the user: OS version and kernel (before and after), Incus
version, bridge and addresses (pins / pool / exclusions), allocators and timers, IPv4 and
IPv6 egress, and that reboot self-healing has been verified.
