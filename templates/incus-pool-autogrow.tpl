#!/usr/bin/env python3
"""incus-pool-autogrow — grow the Incus btrfs loop storage pool on demand.

Trigger : pool usage > GROW_THRESHOLD (80%)
Step    : at least MIN_STEP_GIB (50 GiB), or up to 2x current usage,
          whichever is larger
Cap     : never allocate more than HOST_FREE_CAP (85%) of the host's free
          disk space in one shot
Never shrinks: btrfs loop pools cannot be shrunk, and preseed owns nothing
          about size (see the "no size in preseed" rule), so growth is
          one-way and idempotent.

Grow is done online:  incus storage set <pool> size=<N>GiB  (no container
downtime; verified on btrfs loop pools).

Usage:
  incus-pool-autogrow            # grow if needed (no-op otherwise)
  incus-pool-autogrow --check    # print pool size/usage, never grow
  incus-pool-autogrow --force    # grow even below the threshold

Install: cp to /usr/local/bin/incus-pool-autogrow && chmod +x
Requires: python3 + incus CLI; on NixOS run via a systemd timer with
          path = [ pkgs.python3 pkgs.incus ].
"""

import json
import re
import shutil
import subprocess
import sys

# ============ EDIT THESE FOR YOUR POOL ============
POOL = "default"
GROW_THRESHOLD = 0.80   # usage fraction that triggers a grow
MIN_STEP_GIB = 50       # minimum growth per run
TARGET_FACTOR = 2.0     # ...or enough to hold 2x current usage
HOST_FREE_CAP = 0.85    # at most this share of the host's free space
STATE_DIR = "/var/lib/incus"
# ===================================================


def run(*args, check=False):
    p = subprocess.run(args, capture_output=True, text=True, timeout=300)
    if check and p.returncode != 0:
        sys.exit(f"error: {' '.join(args)} failed: {p.stderr.strip()}")
    return p


def parse_size(text):
    """'200 GiB' / '1.2TiB' / '107374182400' -> bytes (int) or None."""
    if text is None:
        return None
    t = str(text).strip()
    if t.isdigit():
        return int(t)
    m = re.match(r"^([\d.]+)\s*([KMGT]?i?B?)$", t, re.I)
    if not m:
        return None
    val = float(m.group(1))
    unit = m.group(2).upper().replace("I", "") or "B"
    mult = {"B": 1, "KB": 1000, "K": 1024, "MB": 1000**2, "M": 1024**2,
            "GB": 1000**3, "G": 1024**3, "TB": 1000**4, "T": 1024**4}
    return int(val * mult.get(unit, 1))


def pool_exists():
    """True if the pool is known to Incus (it may not exist yet: the service
    can fire during activation, before incus-preseed has created it)."""
    p = run("incus", "storage", "list", "--format", "json")
    if p.returncode == 0 and p.stdout.strip():
        try:
            return any(s.get("name") == POOL for s in json.loads(p.stdout))
        except json.JSONDecodeError:
            pass
    p = run("incus", "storage", "list")
    return POOL in p.stdout.split()


def pool_usage():
    """Return (total_bytes, used_bytes) or (None, None) if unavailable."""
    p = run("incus", "storage", "info", POOL, "--format", "json")
    if p.returncode == 0 and p.stdout.strip():
        try:
            d = json.loads(p.stdout)
        except json.JSONDecodeError:
            d = {}
        total = d.get("total_space") or d.get("space_total")
        used = d.get("used_space")
        if used is None:
            used = d.get("space_used")
        if total and used is not None:
            return int(total), int(used)

    # Fallback: human-readable `incus storage info` output
    p = run("incus", "storage", "info", POOL)
    total = used = None
    for line in p.stdout.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip().lower()
        if key in ("total space", "space total", "total_space"):
            total = parse_size(value)
        elif key in ("space used", "used space", "used_space"):
            used = parse_size(value)
    return total, used


def gib(nbytes):
    return nbytes / (1024 ** 3)


def main():
    args = sys.argv[1:]
    check_only = "--check" in args
    force = "--force" in args

    if not pool_exists():
        print(f"pool '{POOL}' does not exist yet -> nothing to do")
        return

    total, used = pool_usage()
    if total is None or used is None:
        sys.exit(f"error: cannot determine size/usage of pool '{POOL}'")

    free_host = shutil.disk_usage(STATE_DIR).free
    usage = used / total if total else 0.0
    print(f"pool {POOL}: {gib(total):.1f} GiB total, {gib(used):.1f} GiB used "
          f"({usage * 100:.1f}%), host free {gib(free_host):.1f} GiB")

    if usage <= GROW_THRESHOLD and not force:
        print(f"usage <= {GROW_THRESHOLD * 100:.0f}% -> no growth needed")
        return

    # target: hold 2x current usage, at least MIN_STEP_GIB more than now
    target = max(used * TARGET_FACTOR, total + MIN_STEP_GIB * 1024 ** 3)
    # cap: do not consume more than HOST_FREE_CAP of the host's free space
    cap = total + int(free_host * HOST_FREE_CAP)
    target = int(min(target, cap))

    if target <= total:
        print("no growth possible: host free space cap reached "
              f"({gib(total):.1f} GiB >= {gib(cap):.1f} GiB)")
        return

    new_gib = int(target / 1024 ** 3) + 1
    print(f"growing pool {POOL}: {gib(total):.1f} GiB -> {new_gib} GiB "
          f"(cap {gib(cap):.1f} GiB)")
    if check_only:
        return
    p = run("incus", "storage", "set", POOL, f"size={new_gib}GiB")
    if p.returncode != 0:
        sys.exit(f"error: resize failed: {p.stderr.strip()}")
    total2, used2 = pool_usage()
    if total2:
        print(f"pool {POOL} now {gib(total2):.1f} GiB total "
              f"({gib(used2):.1f} GiB used)")


if __name__ == "__main__":
    main()
