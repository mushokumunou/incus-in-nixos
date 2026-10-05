#!/run/current-system/sw/bin/bash
# incus-ct-init.sh — initialise an existing container (packages, sshd, root
# password, identity, timezone, NTP). Idempotent.
#
#   usage: incus-ct-init.sh <name> [password]
#
# stdout: the root password actually in use (one line, nothing else)
# stderr: progress
# Without a password argument one is generated: 8 chars, mixed case + digits,
# at least one of each class.
set -euo pipefail
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME=${1:?usage: incus-ct-init.sh <name> [password]}
PW=${2:-}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INNER="$HERE/incus-ct-init-inner.sh"
[ -r "$INNER" ] || INNER=/usr/local/bin/incus-ct-init-inner.sh
[ -r "$INNER" ] || { echo "error: incus-ct-init-inner.sh not found" >&2; exit 1; }
TZ=${CT_TIMEZONE:-Etc/UTC}

if [ -z "$PW" ]; then
    PW=$(python3 - <<'PY'
import secrets, string
abc = string.ascii_uppercase + string.ascii_lowercase + string.digits
while True:
    pw = ''.join(secrets.choice(abc) for _ in range(8))
    if (any(c.isupper() for c in pw) and any(c.islower() for c in pw)
            and any(c.isdigit() for c in pw)):
        print(pw)
        break
PY
)
fi

incus info "$NAME" >/dev/null 2>&1 || { echo "error: no such instance: $NAME" >&2; exit 1; }

# password travels in a 0600 file inside the container, not on a command line
tmp=$(mktemp /tmp/ct-init.XXXXXX)
chmod 600 "$tmp"
printf 'CT_NAME=%s\nCT_PASSWORD=%s\nCT_TIMEZONE=%s\n' "$NAME" "$PW" "$TZ" > "$tmp"
trap 'rm -f "$tmp"' EXIT

incus file push --mode 0600 "$tmp" "$NAME/root/.ct-init.conf"
incus file push --mode 0755 "$INNER" "$NAME/root/ct-init.sh"

echo "== in-container init output ($NAME) ==" >&2
incus exec "$NAME" -- bash /root/ct-init.sh >&2

incus exec "$NAME" -- rm -f /root/.ct-init.conf /root/ct-init.sh
echo "== init done: $NAME ==" >&2

printf '%s\n' "$PW"
