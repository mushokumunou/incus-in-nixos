# NixOS configuration: Incus host bridged onto the physical LAN.
#
# RENDERED FILE - do not edit on the host. Edit site.conf, re-run
# scripts/render-site.sh and copy the result to /etc/nixos/configuration.nix.
#
# Address model (see references/parameters.md):
#   * @@IFACE@@ is bridged into incusbr0 (it must stay ADDRESS-LESS).
#   * The host keeps exactly ONE fixed IPv6 /128 (its native one) plus the pool
#     gateway; everything else in the routed /@@V6_PREFIX_LEN@@ is handed to
#     containers at random and reclaimed on delete.
#   * Container IPv4 comes from the LAN segment; containers route out through the
#     upstream gateway (no NAT on this host).
#
# SECURITY NOTE: containers receive public IPv6 addresses and the host firewall
# is disabled (bridged forwarding needs it). Any port a container listens on is
# reachable from the internet over IPv6 - keep container services firewalled or
# bound to the LAN interface.

{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # --- Boot ---------------------------------------------------------------
  services.qemuGuest.enable = true;
  systemd.services.qemu-guest-agent.wantedBy = [ "multi-user.target" ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.kernelModules = [ "tcp_bbr" ]
    ++ lib.optional (builtins.stringLength "@@CPU_MODULE@@" > 1) "@@CPU_MODULE@@";

  # --- Identity -----------------------------------------------------------
  networking.hostName = "@@HOSTNAME@@";

  # --- Networking ---------------------------------------------------------
  # Static config below -> NetworkManager must be off (it would ignore them).
  networking.networkmanager.enable = false;

  # @@IFACE@@ becomes a bridge port: no addresses, no DHCP. Incus refuses to
  # bridge a configured interface ("Only unconfigured network interfaces can be
  # bridged").
  networking.interfaces.@@IFACE@@ = {
    useDHCP = false;
  };

  # No DHCP client at all: everything is static/Incus-managed. Also stops dhcpcd
  # from attaching to Incus veths and adding stray link-local default routes.
  networking.dhcpcd.enable = false;

  # Default gateways are applied by incus-bridge-tune AFTER the bridge exists
  # (setting them here would race the bridge bring-up and be undone each rebuild).

  networking.nameservers = [ @@DNS_NIX_LIST@@ ];
  networking.search = [ "@@SEARCH_DOMAIN@@" ];

  networking.hosts = {
    "127.0.0.1" = [ "localhost" ];
    "::1" = [ "localhost" "ip6-localhost" "ip6-loopback" ];
    "127.0.0.2" = [ "@@HOSTNAME@@" ];
    "@@HOST_IPV4@@" = [ "@@HOSTNAME@@" ];
    "@@HOST_IPV6@@" = [ "@@HOSTNAME@@" ];
  };

  # --- Time ---------------------------------------------------------------
  time.timeZone = "@@TIMEZONE@@";

  services.timesyncd.enable = true;
  services.timesyncd.servers = [
    "time.cloudflare.com"
    "time.google.com"
    "0.nixos.pool.ntp.org"
    "1.nixos.pool.ntp.org"
  ];

  # --- SSH ----------------------------------------------------------------
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  services.openssh.startWhenNeeded = false;

  # --- Kernel tuning (BBR + VM + container forwarding) --------------------
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";

    "vm.swappiness" = 10;
    "vm.dirty_ratio" = 30;
    "vm.dirty_background_ratio" = 5;
    "fs.file-max" = 1000000;

    # Containers' IPv6 default route is the host (dnsmasq RA), so IPv6
    # forwarding on the bridge is required. IPv4 containers use the upstream
    # gateway directly (dhcp-option=3), so IPv4 forwarding stays off.
    "net.ipv4.ip_forward" = 0;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv6.conf.@@IFACE@@.forwarding" = 0;

    # NDP proxy entries (belt & braces; containers answer ND on the L2 bridge)
    "net.ipv6.conf.all.proxy_ndp" = 1;
    "net.ipv6.conf.@@IFACE@@.proxy_ndp" = 1;
  };

  # --- ulimit -------------------------------------------------------------
  security.pam.loginLimits = [
    { domain = "*";    type = "soft"; item = "nofile";  value = "65535"; }
    { domain = "*";    type = "hard"; item = "nofile";  value = "65535"; }
    { domain = "root"; type = "soft"; item = "nofile";  value = "65535"; }
    { domain = "root"; type = "hard"; item = "nofile";  value = "65535"; }
    { domain = "*";    type = "soft"; item = "memlock"; value = "unlimited"; }
    { domain = "*";    type = "hard"; item = "memlock"; value = "unlimited"; }
  ];

  # --- Firewall -----------------------------------------------------------
  # Bridged containers and their IPv6 forwarding need it off; the machine sits
  # behind the upstream gateway (see the security note at the top).
  networking.firewall.enable = false;
  networking.firewall.allowPing = true;

  # --- Incus (declarative) ------------------------------------------------
  # preseed is replayed on every boot: network / storage pool / profile are
  # created or updated, never removed. Entities live in the Incus DB, so they
  # survive rebuilds.
  virtualisation.incus = {
    enable = true;
    # latest mainline (module default would be incus-lts)
    package = pkgs.incus;
    preseed = {
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            # Bridge the physical uplink: containers share the LAN L2 with the
            # host and every other VM/CT - no routing changes upstream.
            "bridge.external_interfaces" = "@@IFACE@@";
            # Host primary address lives on the bridge (the port stays bare).
            "ipv4.address" = "@@HOST_IPV4@@/24";
            "ipv4.nat" = "false"; # containers egress via the upstream gateway
            # Safe range only: keep clear of upstream statically-assigned ranges.
            "ipv4.dhcp.ranges" = "@@DHCP_V4_RANGE@@";
            # Containers' default route = upstream gateway (like other VMs)
            "raw.dnsmasq" = "dhcp-option=3,@@LAN_GATEWAY@@";
            # Container IPv6 pool: the /112 routed to this host. The host's own
            # /128 and the pool gateway are reserved (never allocated).
            "ipv6.address" = "@@V6_BRIDGE_ADDRESS@@/@@V6_PREFIX_LEN@@";
            "ipv6.nat" = "false";
            "ipv6.dhcp" = "true";
            "ipv6.dhcp.stateful" = "true"; # makes per-instance pins effective
          };
        }
      ];
      storage_pools = [
        {
          name = "default";
          driver = "@@STORAGE_DRIVER@@"; # loop file pool: quota-capable, snapshots
          # NOTE: no `size` here on purpose. incus-pool-autogrow owns the size;
          # a fixed size would be "shrunk back" after growth and fail
          # (btrfs cannot shrink: "Pool cannot be shrunk").
          config = { };
        }
      ];
      profiles = [
        {
          name = "default";
          devices = {
            eth0 = { name = "eth0"; network = "incusbr0"; type = "nic"; };
            root = { path = "/"; pool = "default"; type = "disk"; };
          };
        }
      ];
    };
  };

  # Grow the storage pool on demand (>80% used). Script: /usr/local/bin/incus-pool-autogrow
  systemd.services.incus-pool-autogrow = {
    description = "Auto-grow Incus storage pool";
    path = [ pkgs.python3 pkgs.incus ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/usr/local/bin/incus-pool-autogrow";
    };
  };
  systemd.timers.incus-pool-autogrow = {
    description = "Periodic storage pool auto-grow check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "10m";
    };
  };

  # Reclaim IPv4+IPv6 allocations of deleted instances (every 10 min).
  # Scripts: /usr/local/bin/incus-ipv4-alloc and /usr/local/bin/incus-ipv6-alloc
  systemd.services.incus-reconcile = let
    wrapper = pkgs.writeShellScript "incus-reconcile" ''
      /usr/local/bin/incus-ipv6-alloc reconcile
      /usr/local/bin/incus-ipv4-alloc reconcile
    '';
  in {
    description = "Reclaim IPv4/IPv6 allocations of deleted Incus instances";
    path = [ pkgs.python3 pkgs.incus ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = wrapper;
    };
  };
  systemd.timers.incus-reconcile = {
    description = "Periodic IPv4/IPv6 allocation reclaim timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "10m";
    };
  };

  # Post-bridge tuning. The host IPv6 /128 must live on incusbr0 ITSELF, never on
  # the @@IFACE@@ port: the upstream gateway's neighbour advertisements are
  # addressed to the bridge MAC and enter the stack through incusbr0, so an
  # address bound to the port would never get its neighbour entry resolved
  # (INCOMPLETE loop -> all IPv6 dead). Default routes must use `dev incusbr0`
  # for the same reason.
  systemd.services.incus-bridge-tune = let
    tuneScript = pkgs.writeShellScript "incus-bridge-tune" ''
      set -e
      # host's fixed IPv6 /128 (native address) - add more suffixes here if needed
      for a in @@V6_HOST_SUFFIX_HEX@@; do
        ip -6 addr add @@V6_POOL_PREFIX@@:$a/128 dev incusbr0 2>/dev/null || true
      done
      # gateway on-link route + default routes (nexthop must be on incusbr0)
      ip -6 route replace @@V6_GATEWAY@@/128 dev incusbr0 2>/dev/null || true
      ip route replace default via @@LAN_GATEWAY@@ dev incusbr0 2>/dev/null || true
      ip -6 route replace default via @@V6_GATEWAY@@ dev incusbr0 2>/dev/null || true
      # bridge: MLD snooping off (otherwise the host's own /128 neighbour
      # solicitations get filtered), proxy NDP on
      echo 0 > /sys/class/net/incusbr0/bridge/multicast_snooping
      echo 1 > /proc/sys/net/ipv6/conf/incusbr0/proxy_ndp
      # the port must never forward (the kernel resets it when Incus enslaves it)
      echo 0 > /proc/sys/net/ipv6/conf/@@IFACE@@/forwarding
      for a in @@V6_HOST_SUFFIX_HEX@@; do
        ip -6 neigh replace proxy @@V6_POOL_PREFIX@@:$a dev incusbr0
      done
    '';
  in {
    description = "Tune incusbr0 (host IPv6 on the bridge, MLD snooping off, proxy NDP)";
    after = [ "incus-preseed.service" ];
    requires = [ "incus-preseed.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = tuneScript;
    };
  };

  # --- Packages -----------------------------------------------------------
  environment.systemPackages = with pkgs; [
    vim wget curl htop iptables iproute2 bridge-utils dnsutils
    lsof pciutils usbutils tmux git incus python3
  ];

  # --- Locale / Nix -------------------------------------------------------
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  nix.optimise.automatic = true;

  # Keep the machine's original state version (do NOT change it).
  system.stateVersion = "@@STATE_VERSION@@";
}
