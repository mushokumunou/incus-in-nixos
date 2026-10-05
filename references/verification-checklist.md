# Verification checklists

## A. Host (after Path A, and after every reboot)

```bash
systemctl --failed                       # expected: 0 loaded units listed
nixos-version; uname -r; incus version   # record all three versions
systemctl is-active incus.service incus-preseed.service incus-bridge-tune.service \
  incus-reconcile.timer incus-pool-autogrow.timer
ip -br a show incusbr0    # expected: host IPv4/24 + host native IPv6 /128 (+ pool gateway /112)
ip -br a show <IFACE>     # expected: only fe80::/64, no global address
ip r | head -3            # expected: default via <LAN_GATEWAY> dev incusbr0
ip -6 r | head -3         # expected: default via <V6_GATEWAY> dev incusbr0
cat /sys/class/net/incusbr0/bridge/multicast_snooping     # expected: 0
cat /proc/sys/net/ipv6/conf/<IFACE>/forwarding            # expected: 0
cat /proc/sys/net/ipv6/conf/all/forwarding                # expected: 1
ip -6 neigh show proxy dev incusbr0 | wc -l               # expected: number of fixed /128s (1 in this design)
ls /sys/class/net/incusbr0/brif/                          # expected: <IFACE> (+ every running container's veth)
incus-ipv4-alloc status; incus-ipv6-alloc status          # expected: matches the existing containers one-to-one
curl -s -o /dev/null -w "v4:%{http_code} " -4 https://www.google.com
curl -s -o /dev/null -w "v6:%{http_code}\n" -6 https://www.google.com   # expected: 200 200
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control vm.swappiness fs.file-max
```

## B. Container (after every creation)

```bash
incus list                                  # RUNNING; the IPV4/IPV6 columns show the container's real addresses
incus-ct-info.sh <name>                     # complete report: hostname / v4 / v6 / ssh / resources / snapshots / allocator
incus config show <name> | grep -A4 'eth0:'  # the pinned v4/v6 must match the "real addresses" above
incus exec <name> -- hostname                # = instance name
incus exec <name> -- ip -br a                # both pinned addresses present, plus fe80::
incus exec <name> -- ip -6 r | head -3       # a default via fe80::... (the host, handed out by RA)
incus exec <name> -- ping -c2 <LAN_GATEWAY>
incus exec <name> -- curl -s -o /dev/null -w 'v4:%{http_code} ' -4 https://www.google.com
incus exec <name> -- curl -s -o /dev/null -w 'v6:%{http_code}\n' -6 https://www.google.com
incus exec <name> -- systemctl is-active ssh                   # active
incus exec <name> -- readlink -f /bin/sh                       # dash (must not have been changed to bash)
incus exec <name> -- bash -c 'grep -c "" /etc/ssh/sshd_config.d/99-ct-init.conf'
incus snapshot list <name>
```

**External reachability** (from another machine that has IPv6): `ping6 <container v6>`,
`ping <container v4>`, `ssh -4 root@<container v4>`, `ssh -6 root@<container v6>` (the
password is the one printed at creation time / stored in the `.info` file).

## C. Address reclaim (after every delete)

```bash
incus list                                       # the instance is gone
incus-ipv4-alloc status; incus-ipv6-alloc status  # allocated back to the base count; note "held by dnsmasq leases"
cat /var/lib/incus/ipv4-allocations.json /var/lib/incus/ipv6-allocations.json   # no leftovers for that instance
grep -E "<v4>|<v6>" /var/lib/incus/networks/*/dnsmasq.leases
```

Criteria:
- IPv4: the lease disappears together with the instance -> immediately reusable.
- IPv6: the lease may still be present (up to ~1h), but the allocator will not hand it out
  during that window (lease guard) and it returns to the pool when the lease expires; use
  `incus-ct-flush-lease.sh <addr>` to reclaim it right away.
- **Final check (mandatory)**: pin the released address to a throwaway instance and confirm
  it really receives that address with working networking, then delete the throwaway
  instance, clean up with `incus-ct-flush-lease.sh`, and confirm `incus list` is empty again.
