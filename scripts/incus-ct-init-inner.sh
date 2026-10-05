#!/usr/bin/env bash
# incus-ct-init-inner.sh — runs INSIDE a freshly created container.
# Pushed and executed by incus-ct-init.sh; reads /root/.ct-init.conf:
#
#   CT_NAME=<instance name>
#   CT_PASSWORD=<root password>
#   CT_TIMEZONE=<tz, e.g. Etc/UTC>
#
# Idempotent: safe to re-run. Does NOT touch /bin/sh (keep the image's dash).
set -euo pipefail

[ -r /root/.ct-init.conf ] || { echo "error: /root/.ct-init.conf missing" >&2; exit 1; }
# shellcheck disable=SC1091
. /root/.ct-init.conf
export DEBIAN_FRONTEND=noninteractive

step() { echo "[ct-init] $*"; }

step "identity: hostname=$CT_NAME"
if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$CT_NAME"
else
    printf '%s\n' "$CT_NAME" > /etc/hostname
fi
if ! grep -qE "[[:space:]]$CT_NAME([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "$CT_NAME" >> /etc/hosts
fi

step "timezone=$CT_TIMEZONE + locale"
if [ -e "/usr/share/zoneinfo/$CT_TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$CT_TIMEZONE" /etc/localtime
    printf '%s\n' "$CT_TIMEZONE" > /etc/timezone
fi
command -v localedef >/dev/null 2>&1 && localedef -i en_US -f UTF-8 en_US.UTF-8 >/dev/null 2>&1 || true

step "packages: update + upgrade + base tools"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get -y -qq upgrade
    apt-get -y -qq install --no-install-recommends \
        openssh-server ca-certificates curl sudo locales tzdata procps less
elif command -v dnf >/dev/null 2>&1; then
    dnf -y -q upgrade
    dnf -y -q install openssh-server ca-certificates curl sudo tzdata procps
elif command -v apk >/dev/null 2>&1; then
    apk update && apk upgrade && apk add openssh ca-certificates curl sudo tzdata procps
else
    echo "[ct-init] warn: unknown package manager, skipping package step" >&2
fi

step "root password"
printf 'root:%s\n' "$CT_PASSWORD" | chpasswd

step "sshd: permit root + password login"
mkdir -p /etc/ssh/sshd_config.d
SSHD_CONF=/etc/ssh/sshd_config.d/99-ct-init.conf
printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nUseDNS no\n' \
    > "$SSHD_CONF"
restart_sshd() {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    sleep 2
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
}
restart_sshd
if command -v sshd >/dev/null 2>&1; then
    sshd -t || echo "[ct-init] warn: sshd -t failed, check $SSHD_CONF" >&2
fi

# Self-test the password login over loopback. In unprivileged containers the PAM
# path can fail: sshd's pre-auth child runs as the unprivileged sshd user, so
# pam_unix falls back to the setgid helper /usr/sbin/unix_chkpwd, which may be
# unable to verify /etc/shadow (observed on some image/kernel combos). If that
# happens, switch sshd to its own crypt() check (UsePAM no) and re-test.
PW_OK=0
if command -v sshpass >/dev/null 2>&1 || \
   { command -v apt-get >/dev/null 2>&1 && apt-get -y -qq install sshpass >/dev/null 2>&1; }; then
    if sshpass -p "$CT_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
         -o LogLevel=ERROR root@127.0.0.1 true 2>/dev/null; then
        PW_OK=1
    fi
fi
if [ "$PW_OK" = 0 ]; then
    echo "[ct-init] password login self-test failed with PAM -> retrying with UsePAM no" >&2
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nUsePAM no\nUseDNS no\n' \
        > "$SSHD_CONF"
    restart_sshd
    if sshpass -p "$CT_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 \
         -o LogLevel=ERROR root@127.0.0.1 true 2>/dev/null; then
        PW_OK=2
        echo "[ct-init] password login works with UsePAM no (PAM helper unusable here)" >&2
    fi
fi
case "$PW_OK" in
    1) echo "[ct-init] password login self-test: OK (PAM)" ;;
    2) echo "[ct-init] password login self-test: OK (UsePAM no fallback)" ;;
    *) echo "[ct-init] WARN: password login self-test FAILED - check sshd/auth logs" >&2 ;;
esac

step "ntp"
systemctl enable --now systemd-timesyncd 2>/dev/null || true

step "self-check"
echo "hostname : $(hostname)"
echo "kernel   : $(uname -r)"
echo "addrs    :"; ip -br a | grep -v '^lo' || true
echo "sshd     : $(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo unknown)"
echo "sh       : $(readlink -f /bin/sh)"
echo "sshd conf: $(tr '\n' ';' < /etc/ssh/sshd_config.d/99-ct-init.conf 2>/dev/null)"
echo "[ct-init] init OK"
