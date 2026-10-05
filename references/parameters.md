# site.conf parameters and how to discover them

The renderer only understands `KEY=VALUE` (shell syntax; do not use `|` inside a value).
A missing required key is an error, and rendering asserts that no `@@KEY@@` placeholder
is left behind.

## Required

| Key | Meaning | Example (illustrative values only) |
|-----|---------|------------------------------------|
| `IFACE` | physical NIC to enslave into the Incus bridge | `ens18` |
| `HOSTNAME` | host hostname (**keep it as it is, do not rename**) | `nixos` |
| `HOST_IPV4` | the host's own IPv4 (ends up on the bridge) | `10.10.10.50` |
| `LAN_GATEWAY` | upstream gateway (also the containers' IPv4 default route) | `10.10.10.1` |
| `LAN_PREFIX` | first three octets of the LAN | `10.10.10` |
| `POOL_V4_START` / `POOL_V4_END` | container IPv4 pool range (avoid the upstream static range) | `2` / `99` |
| `V6_POOL_PREFIX` | IPv6 pool prefix routed to this host (7 hextets) | `2001:db8:1234:5678:9abc:0:50` |
| `V6_PREFIX_LEN` | pool length (usually 112) | `112` |
| `V6_HOST_SUFFIX_HEX` | suffix of the host's native /128 inside the pool (**hexadecimal**) | `50` |
| `V6_BRIDGE_SUFFIX_HEX` | pool gateway (bridge address) suffix, usually `1` | `1` |
| `V6_GATEWAY` | upstream IPv6 gateway | `2001:db8:1234:5678:9abc::1` |

## Optional (defaults shown)

| Key | Default | Notes |
|-----|---------|-------|
| `DNS` | `1.1.1.1 8.8.8.8` | rendered into `networking.nameservers` |
| `SEARCH_DOMAIN` | `local` | `networking.search` |
| `TIMEZONE` | `Etc/UTC` | host timezone |
| `STORAGE_DRIVER` | `btrfs` | Incus storage pool driver (loop file pool, quota capable) |
| `CPU_MODULE` | `kvm-amd` | virtualisation module in `boot.kernelModules` (`kvm-amd` / `kvm-intel`; leave an empty string if unsure) |
| `STATE_VERSION` | `26.05` | **copy the target machine's existing `system.stateVersion`**, do not change it |
| `IMAGE` / `DEFAULT_CPU` / `DEFAULT_MEMORY` / `DEFAULT_DISK` | `images:debian/13` / `4` / `4GiB` / `10GiB` | Path B container creation defaults |
| `FLAKE_REF` | `/etc/nixos#<HOSTNAME>` | reference used by `nixos-rebuild --flake` |

Derived (do not fill in): `HOST_IPV6 = V6_POOL_PREFIX:V6_HOST_SUFFIX_HEX`,
`V6_BRIDGE_ADDRESS = V6_POOL_PREFIX:V6_BRIDGE_SUFFIX_HEX`,
`DHCP_V4_RANGE = LAN_PREFIX.POOL_V4_START-LAN_PREFIX.POOL_V4_END`.

## How to discover the values

1. Run `scripts/probe-host.sh` (read-only): it prints identity / interfaces / routes / DNS /
   disk and suggests values for `IFACE`, `HOST_IPV4`, `LAN_GATEWAY`, `HOST_IPV6`,
   `V6_GATEWAY`.
2. `HOST_IPV6` -> `V6_POOL_PREFIX`: drop the last hextet of `HOST_IPV6`
   (example: `...:9abc:0:50:50` -> `...:9abc:0:50`), and `V6_HOST_SUFFIX_HEX` is that
   dropped hextet (`50`).
3. If the host has no IPv6 at all (common on a freshly rolled-back system):
   - look at the hypervisor side: `/etc/network/interfaces` or the VM config, for example
     `post-up ip -6 route add default via ...`,
   - or simply ask the operator for: **the IPv6 prefix/length routed to this machine, the
     upstream IPv6 gateway, and the host's native /128**.
   Never guess the prefix — a wrong prefix leaves container IPv6 completely broken.
4. `STATE_VERSION`: read the existing value from the target machine's
   `/etc/nixos/configuration.nix` and copy it.

## Example site.conf (rename and use as-is)

```sh
IFACE=ens18
HOSTNAME=nixos
HOST_IPV4=10.10.10.50
LAN_GATEWAY=10.10.10.1
LAN_PREFIX=10.10.10
POOL_V4_START=2
POOL_V4_END=99
V6_POOL_PREFIX=2001:db8:1234:5678:9abc:0:50
V6_PREFIX_LEN=112
V6_HOST_SUFFIX_HEX=50
V6_BRIDGE_SUFFIX_HEX=1
V6_GATEWAY=2001:db8:1234:5678:9abc::1
DNS="1.1.1.1 8.8.8.8"
SEARCH_DOMAIN=local
TIMEZONE=Etc/UTC
STORAGE_DRIVER=btrfs
CPU_MODULE=kvm-amd
STATE_VERSION=26.05
```

**Note**: this design fixes exactly one IPv6 `/128` for the host (its native one). If you
really need extra fixed `/128`s for the host, edit the bridge-tune address list in
`templates/configuration.nix.tpl` **and** `HOST_RESERVED` in
`templates/incus-ipv6-alloc.tpl` (both must match, otherwise the pool can hand out an
address the host is also using).
