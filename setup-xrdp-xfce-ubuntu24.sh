#!/usr/bin/env bash
# Ubuntu 24.04 Server: XFCE + XRDP, localhost only, through an SSH tunnel.
# Run from SSH or the server console: sudo bash setup-xrdp-xfce-ubuntu24.sh
# Re-running converges to the same managed configuration and reuses valid TLS.
# Each run backs up configuration and restarts XRDP; log out of RDP first.
# A small recovery timer restarts only the XRDP frontend after a failed
# reconnect, preserving the underlying Xorg/XFCE session where possible.
# No changes to SSH, firewalld, display managers, or users' home directories.
# No distribution upgrade, apt autoremove, or removal of installed packages.
# Reference: https://manpages.ubuntu.com/manpages/noble/man5/xrdp.ini.5.html
# Reference: https://manpages.ubuntu.com/manpages/noble/man5/sesman.ini.5.html

set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly RDP_PORT=3389
readonly LOCAL_PORT=13389
readonly SESMAN_PORT=3350
readonly TLS_DIR=/etc/xrdp/tls
readonly TLS_CERT="$TLS_DIR/xrdp.crt"
readonly TLS_KEY="$TLS_DIR/xrdp.key"
readonly SESSION_SCRIPT=/usr/local/libexec/xrdp-start-xfce.sh
readonly RECOVERY_SCRIPT=/usr/local/libexec/xrdp-session-recovery.sh
readonly RECOVERY_SERVICE=/etc/systemd/system/xrdp-session-recovery.service
readonly RECOVERY_TIMER=/etc/systemd/system/xrdp-session-recovery.timer
readonly RECOVERY_TIMER_UNIT=xrdp-session-recovery.timer
WORK_DIR=''
BACKUP_DIR=''
SERVICE_WORK_STARTED=0
TEMP_MASKS=()

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
    local status="$1" line="$2"
    trap - ERR
    if (( BASH_SUBSHELL == 0 )); then
        printf '\nERROR: command failed on line %s (exit %s).\n' "$line" "$status" >&2
    fi
    exit "$status"
}

cleanup() {
    local status=$? unit
    trap - ERR EXIT
    set +e
    if (( status != 0 && SERVICE_WORK_STARTED )); then
        # Do not restore an older configuration which might expose port 3389.
        systemctl stop "$RECOVERY_TIMER_UNIT" >/dev/null 2>&1
        systemctl stop xrdp.service xrdp-sesman.service
        printf '\nInstallation did not complete; XRDP has been stopped.\n' >&2
        printf 'Fix the reported error, then rerun this same script.\n' >&2
    fi
    for unit in "${TEMP_MASKS[@]}"; do
        systemctl unmask --runtime "$unit" >/dev/null 2>&1
    done
    if (( ${#TEMP_MASKS[@]} )); then
        systemctl daemon-reload
    fi
    if [[ -n "$WORK_DIR" && "$WORK_DIR" == /tmp/setup-xrdp-xfce.* ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    if (( status != 0 )); then
        [[ -z "$BACKUP_DIR" ]] || printf 'Configuration backup: %s\n' "$BACKUP_DIR" >&2
        printf 'Diagnostics: sudo journalctl -u xrdp -u xrdp-sesman -n 60 --no-pager\n' >&2
    fi
    exit "$status"
}

trap 'on_error "$?" "$LINENO"' ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

backup_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a --parents -- "$path" "$BACKUP_DIR/files/"
    fi
}

apt_run() {
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get \
        -o DPkg::Lock::Timeout=180 \
        -o Acquire::Retries=3 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        -o Dpkg::Options::=--force-confmiss "$@"
}

main() {
    local command unit state audit package_state stale_list conffiles path extra
    local uid_min installed_version cert_pub key_pub ssh_dump ssh_port ssh_user
    local firewall_state ssh_client_ip ssh_client_port ssh_server_ip ssh_server_port
    local -a stale_xfce=()

    (( EUID == 0 )) || die 'Run this script with sudo bash, from SSH or the server console.'
    [[ $# == 0 ]] || die 'This script takes no arguments.'
    [[ -r /etc/os-release ]] || die '/etc/os-release is unavailable.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || \
        die 'This script supports Ubuntu 24.04 only.'
    [[ -d /run/systemd/system ]] || die 'A running systemd system is required.'

    for command in apt-get dpkg dpkg-query systemctl flock ss awk getent \
                   install cp cmp mktemp runuser journalctl pgrep logger; do
        command -v "$command" >/dev/null || die "Required command is missing: $command"
    done
    mkdir -p /run/lock
    exec 9>/run/lock/setup-xrdp-xfce.lock
    flock -n 9 || die 'Another copy of this installer is already running.'

    for unit in xrdp.service xrdp-sesman.service; do
        state=$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)
        [[ "$state" != masked ]] || \
            die "$unit is already masked. Resolve the existing mask before rerunning."
    done
    audit=$(dpkg --audit)
    if [[ -n "$audit" ]]; then
        printf '%s\n' "$audit" >&2
        die 'DPKG needs repair. Run sudo dpkg --configure -a, resolve its errors, then rerun.'
    fi

    log 'Preparing a configuration backup; XRDP sessions will be interrupted'
    install -d -m 0700 /var/backups/xrdp-xfce
    BACKUP_DIR=$(mktemp -d "/var/backups/xrdp-xfce/$(date -u +%Y%m%d-%H%M%S).XXXXXX")
    install -d -m 0700 "$BACKUP_DIR/files"
    WORK_DIR=$(mktemp -d /tmp/setup-xrdp-xfce.XXXXXX)
    for path in /etc/xrdp /etc/X11/xrdp /etc/pam.d/xrdp-sesman \
                "$SESSION_SCRIPT" "$RECOVERY_SCRIPT" "$RECOVERY_SERVICE" "$RECOVERY_TIMER"; do
        backup_path "$path"
    done
    package_state=$(dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n')
    printf '%s\n' "$package_state" > "$BACKUP_DIR/package-state.txt"
    systemctl show -p Id -p LoadState -p ActiveState -p UnitFileState \
        xrdp.service xrdp-sesman.service > "$BACKUP_DIR/service-state.txt" || true
    printf 'Backup: %s\n' "$BACKUP_DIR"

    log 'Stopping XRDP and temporarily blocking package-triggered starts'
    SERVICE_WORK_STARTED=1
    systemctl stop "$RECOVERY_TIMER_UNIT" >/dev/null 2>&1 || true
    for unit in xrdp.service xrdp-sesman.service; do
        state=$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)
        if [[ "$state" == loaded ]]; then
            systemctl stop "$unit"
        fi
        TEMP_MASKS+=("$unit")
        systemctl mask --runtime "$unit"
    done

    log 'Updating package indexes'
    apt_run -o APT::Update::Error-Mode=any update
    if ! command -v python3 >/dev/null; then
        apt_run -y --no-remove --no-install-recommends install python3
    fi

    log 'Cleaning only removed XFCE packages with leftover system configuration'
    stale_list=$(awk '$1 == "rc" && $2 ~ /^(xfce4|xfdesktop4|xfwm4)([-:]|$)/ {print $2}' \
        <<< "$package_state")
    if [[ -n "$stale_list" ]]; then
        mapfile -t stale_xfce <<< "$stale_list"
        printf '%s\n' "${stale_xfce[@]}" > "$BACKUP_DIR/purged-rc-packages.txt"
        conffiles=$(dpkg-query -W -f='${Conffiles}\n' "${stale_xfce[@]}")
        while read -r path extra; do
            if [[ "$path" == /* ]]; then
                backup_path "$path"
            fi
        done <<< "$conffiles"
        # These packages are already removed. Purge only their conffiles.
        env DEBIAN_FRONTEND=noninteractive dpkg --purge "${stale_xfce[@]}"
    else
        printf 'No removed XFCE package configurations to purge.\n'
    fi

    log 'Installing the XFCE desktop and the XRDP/Xorg stack'
    apt_run -y --no-remove --no-install-recommends install \
        xrdp xorgxrdp xserver-xorg-core xauth x11-xserver-utils \
        xfce4 xfce4-terminal xfce4-notifyd mousepad adwaita-icon-theme \
        fonts-dejavu-core dbus-x11 dbus-daemon openssl python3 libpam-modules
    if [[ ! -f /etc/xrdp/xrdp.ini || ! -f /etc/xrdp/sesman.ini || \
          ! -f /etc/pam.d/xrdp-sesman || ! -f /etc/X11/xrdp/xorg.conf ]]; then
        log 'Restoring missing package-owned XRDP configuration files'
        apt_run -y --no-remove --no-install-recommends --reinstall install xrdp xorgxrdp
    fi
    installed_version=$(dpkg-query -W -f='${Version}' xrdp)
    [[ "${installed_version#*:}" == 0.9.* ]] || \
        die "Expected Ubuntu's XRDP 0.9.x package; found $installed_version."
    for path in /usr/lib/xorg/Xorg /usr/bin/xfce4-session /usr/bin/dbus-run-session; do
        [[ -x "$path" ]] || die "Required program is missing: $path"
    done
    [[ -s /etc/X11/xrdp/xorg.conf ]] || die 'XRDP Xorg configuration is missing.'
    getent passwd xrdp >/dev/null || die 'The xrdp service account is missing.'
    getent group xrdp >/dev/null || die 'The xrdp service group is missing.'

    log 'Preparing a dedicated TLS certificate and private key'
    [[ ! -L "$TLS_DIR" ]] || die "$TLS_DIR is a symlink; review it before proceeding."
    install -d -o root -g xrdp -m 0750 "$TLS_DIR"
    cert_pub="$WORK_DIR/cert-public.pem"
    key_pub="$WORK_DIR/key-public.pem"
    if [[ -s "$TLS_CERT" && -s "$TLS_KEY" && ! -L "$TLS_CERT" && ! -L "$TLS_KEY" ]] && \
       openssl x509 -in "$TLS_CERT" -noout -checkend 2592000 >/dev/null 2>&1 && \
       openssl verify -CAfile "$TLS_CERT" "$TLS_CERT" >/dev/null 2>&1 && \
       openssl x509 -in "$TLS_CERT" -noout -checkhost localhost >/dev/null 2>&1 && \
       openssl x509 -in "$TLS_CERT" -noout -checkip 127.0.0.1 >/dev/null 2>&1 && \
       openssl pkey -in "$TLS_KEY" -passin pass: -check -noout >/dev/null 2>&1 && \
       openssl x509 -in "$TLS_CERT" -pubkey -noout > "$cert_pub" 2>/dev/null && \
       openssl pkey -in "$TLS_KEY" -passin pass: -pubout > "$key_pub" 2>/dev/null && \
       cmp -s "$cert_pub" "$key_pub"; then
        printf 'Reusing the existing valid TLS certificate and matching key.\n'
    else
        printf 'Creating a certificate (new, invalid, mismatched, or expires within 30 days).\n'
        openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
            -subj '/CN=localhost' \
            -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
            -addext 'basicConstraints=critical,CA:FALSE' \
            -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
            -addext 'extendedKeyUsage=serverAuth' \
            -keyout "$WORK_DIR/xrdp.key" -out "$WORK_DIR/xrdp.crt" \
            2> "$WORK_DIR/certificate-generation.log"
        # Replace the paths, never follow pre-existing key/certificate symlinks.
        install -o root -g xrdp -m 0640 "$WORK_DIR/xrdp.key" "$TLS_DIR/.xrdp.key.new"
        install -o root -g xrdp -m 0644 "$WORK_DIR/xrdp.crt" "$TLS_DIR/.xrdp.crt.new"
        mv -fT "$TLS_DIR/.xrdp.key.new" "$TLS_KEY"
        mv -fT "$TLS_DIR/.xrdp.crt.new" "$TLS_CERT"
    fi
    chown root:xrdp "$TLS_CERT" "$TLS_KEY"
    chmod 0644 "$TLS_CERT"
    chmod 0640 "$TLS_KEY"
    runuser -u xrdp -- test -r "$TLS_KEY" || die 'The xrdp service cannot read its TLS key.'

    log 'Writing the system-wide XFCE startup script'
    [[ ! -L "$SESSION_SCRIPT" ]] || die "$SESSION_SCRIPT is a symlink; review it before proceeding."
    cat > "$WORK_DIR/start-xfce.sh" <<'SESSION'
#!/bin/sh
# Managed by setup-xrdp-xfce-ubuntu24.sh; runs as the authenticated user.
# XRDP has already started Xorg. Give this desktop its own D-Bus session.
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export DESKTOP_SESSION=xfce
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
if [ -r /etc/default/locale ]; then
    set -a
    . /etc/default/locale
    set +a
fi
cd "$HOME" || exit 1
exec /usr/bin/dbus-run-session -- /usr/bin/xfce4-session
SESSION
    sh -n "$WORK_DIR/start-xfce.sh"
    install -d -o root -g root -m 0755 /usr/local/libexec
    if ! cmp -s "$WORK_DIR/start-xfce.sh" "$SESSION_SCRIPT"; then
        install -o root -g root -m 0755 "$WORK_DIR/start-xfce.sh" \
            /usr/local/libexec/.xrdp-start-xfce.sh.new
        mv -fT /usr/local/libexec/.xrdp-start-xfce.sh.new "$SESSION_SCRIPT"
    fi
    chown root:root "$SESSION_SCRIPT"
    chmod 0755 "$SESSION_SCRIPT"

    log 'Writing the conservative XRDP reconnect recovery helper'
    cat > "$WORK_DIR/xrdp-session-recovery.sh" <<'RECOVERY'
#!/bin/sh
# Managed by setup-xrdp-xfce-ubuntu24.sh.
# Recover only the xrdp frontend when it cannot attach to an existing user
# session. xrdp-sesman and the user's Xorg/XFCE session are left running.
set -eu

lock=/run/lock/xrdp-session-recovery.lock
state=/run/xrdp/xrdp-session-recovery.last
now=$(/usr/bin/date +%s)

(
    /usr/bin/flock -n 9 || exit 0
    if [ -r "$state" ]; then
        last=$(/usr/bin/cat "$state" 2>/dev/null || printf '0')
        case "$last" in
            ''|*[!0-9]*) last=0 ;;
        esac
        [ "$last" -gt "$now" ] 2>/dev/null && last=0
        [ $((now - last)) -ge 300 ] || exit 0
    fi

    /usr/bin/systemctl is-active --quiet xrdp.service || exit 0
    /usr/bin/systemctl is-active --quiet xrdp-sesman.service || exit 0

    recent=$(/usr/bin/journalctl -u xrdp.service --since '90 seconds ago' \
        --no-pager -q 2>/dev/null || true)
    case "$recent" in
        *'Error connecting to user session'*) ;;
        *) exit 0 ;;
    esac

    # Only recover when an Xorg XRDP session still exists. This avoids
    # restarting xrdp for an ordinary failed first login.
    /usr/bin/pgrep -af '/usr/lib/xorg/Xorg .*xrdp/xorg.conf' >/dev/null 2>&1 || exit 0

    printf '%s\n' "$now" > "$state"
    /usr/bin/logger -t xrdp-session-recovery \
        'restarting xrdp frontend after a failed existing-session reconnect'
    /usr/bin/systemctl restart xrdp.service
) 9>"$lock"
RECOVERY
    sh -n "$WORK_DIR/xrdp-session-recovery.sh"
    install -o root -g root -m 0755 "$WORK_DIR/xrdp-session-recovery.sh" \
        "$RECOVERY_SCRIPT"

    cat > "$WORK_DIR/xrdp-session-recovery.service" <<'SERVICE'
[Unit]
Description=Recover XRDP frontend after a failed existing-session reconnect
After=xrdp.service xrdp-sesman.service
Wants=xrdp-sesman.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/xrdp-session-recovery.sh
SERVICE
    install -o root -g root -m 0644 "$WORK_DIR/xrdp-session-recovery.service" \
        "$RECOVERY_SERVICE"

    cat > "$WORK_DIR/xrdp-session-recovery.timer" <<'TIMER'
[Unit]
Description=Check for XRDP existing-session reconnect failures

[Timer]
OnBootSec=90s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=xrdp-session-recovery.service

[Install]
WantedBy=timers.target
TIMER
    install -o root -g root -m 0644 "$WORK_DIR/xrdp-session-recovery.timer" \
        "$RECOVERY_TIMER"

    uid_min=$(awk '$1 == "UID_MIN" && !seen {print $2; seen=1}' /etc/login.defs)
    uid_min=${uid_min:-1000}
    [[ "$uid_min" =~ ^[0-9]+$ ]] && (( uid_min >= 1000 )) || \
        die "Unexpected UID_MIN in /etc/login.defs: $uid_min"

    log 'Configuring localhost-only listeners, TLS, XFCE, and normal-user login'
    python3 - "$RDP_PORT" "$SESMAN_PORT" "$TLS_CERT" "$TLS_KEY" \
        "$SESSION_SCRIPT" "$uid_min" <<'CONFIG'
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

rdp_port, sesman_port, cert, key, startup, uid_min = sys.argv[1:]

def rewrite_ini(text, updates):
    """Preserve comments/unmanaged settings; remove duplicates of managed keys."""
    sections = re.compile(r'^\s*\[([^\]]+)\]\s*(?:[;#].*)?$')
    entries = re.compile(r'^\s*([^=;#\s]+)\s*=')
    names = [m.group(1).lower() for line in text.splitlines()
             if (m := sections.match(line))]
    if len(names) != len(set(names)):
        raise ValueError('Duplicate INI sections: review configuration before proceeding')
    missing = set(updates) - set(names)
    if missing:
        raise ValueError(f'Missing required INI sections: {sorted(missing)}')
    result, current, seen = [], None, set()

    def append_values(name, values):
        for value in values:
            result.append(f'{name}={value}\n')

    def finish_section():
        for name, values in updates.get(current, {}).items():
            if name.lower() not in seen:
                append_values(name, values)

    for line in text.splitlines(keepends=True):
        match = sections.match(line.rstrip('\r\n'))
        if match:
            finish_section()
            current, seen = match.group(1).lower(), set()
            result.append(line.rstrip('\r\n') + '\n')
            continue
        match = entries.match(line)
        managed = {k.lower(): k for k in updates.get(current, {})}
        name = match.group(1).lower() if match else None
        if name in managed:
            if name not in seen:
                canonical = managed[name]
                append_values(canonical, updates[current][canonical])
                seen.add(name)
        else:
            result.append(line.rstrip('\r\n') + '\n')
    finish_section()
    return ''.join(result)

def atomic_write(path, text):
    if path.is_symlink():
        raise ValueError(f'Refusing to replace a symlink: {path}')
    original = path.read_text()
    if text == original:
        print(f'Already configured: {path}')
        return
    metadata = path.stat()
    fd, temporary = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'Configured: {path}')

xrdp = {
    'globals': {
        'port': [f'tcp://127.0.0.1:{rdp_port}'],
        'tcp_nodelay': ['true'], 'tcp_keepalive': ['true'],
        'max_bpp': ['32'],
        'security_layer': ['tls'],
        'crypt_level': ['high'],
        'certificate': [cert], 'key_file': [key],
        'ssl_protocols': ['TLSv1.2, TLSv1.3'],
        'autorun': ['Xorg'],
    },
    'xorg': {
        'name': ['Xorg'], 'lib': ['libxup.so'],
        'username': ['ask'], 'password': ['ask'],
        'ip': ['127.0.0.1'], 'port': ['-1'], 'code': ['20'],
    },
}
sesman = {
    'globals': {
        'ListenAddress': ['127.0.0.1'], 'ListenPort': [sesman_port],
        'EnableUserWindowManager': ['false'],
        'DefaultWindowManager': [startup],
    },
    'security': {
        'AllowRootLogin': ['false'], 'MaxLoginRetry': ['3'],
        'TerminalServerUsers': [''], 'AlwaysGroupCheck': ['false'],
        'AllowAlternateShell': ['false'],
    },
    'sessions': {
        'KillDisconnected': ['false'],
        'DisconnectedTimeLimit': ['0'],
        'IdleTimeLimit': ['0'],
        'Policy': ['UB'],
        'StartupWaitTime': ['3000'],
    },
    'xorg': {
        'param': ['/usr/lib/xorg/Xorg', '-config', 'xrdp/xorg.conf',
                  '-noreset', '-nolisten', 'tcp', '-logfile', '.xorgxrdp.%s.log'],
    },
}
begin = '# BEGIN setup-xrdp-xfce normal-user policy'
end = '# END setup-xrdp-xfce normal-user policy'

def rewrite_pam(pam, minimum_uid):
    if pam.count(begin) != pam.count(end) or pam.count(begin) > 1:
        raise ValueError('Malformed managed PAM block; review it before proceeding')
    if begin in pam:
        first, end_start = pam.index(begin), pam.index(end)
        if end_start <= first:
            raise ValueError('Malformed managed PAM block order')
        last = end_start + len(end)
        if pam[last:last + 2] == '\r\n':
            last += 2
        elif pam[last:last + 1] == '\n':
            last += 1
        pam = pam[:first] + pam[last:]
    block = (f'{begin}\naccount requisite pam_succeed_if.so quiet '
             f'uid >= {minimum_uid}\n{end}\n')
    return block + pam

pam_path = Path('/etc/pam.d/xrdp-sesman')
pam = rewrite_pam(pam_path.read_text(), uid_min)

# Prepare every result first so malformed input never causes partial edits.
pending = [
    (Path('/etc/xrdp/xrdp.ini'), xrdp),
    (Path('/etc/xrdp/sesman.ini'), sesman),
]
outputs = [(p, rewrite_ini(p.read_text(), settings)) for p, settings in pending]
outputs.append((pam_path, pam))
for path, text in outputs:
    if path.is_symlink():
        raise ValueError(f'Refusing to replace a symlink: {path}')
for path, text in outputs:
    atomic_write(path, text)
CONFIG

    log 'Enabling and starting XRDP'
    for unit in "${TEMP_MASKS[@]}"; do
        systemctl unmask --runtime "$unit"
    done
    TEMP_MASKS=()
    systemctl daemon-reload
    # Ubuntu starts sesman through xrdp.service's dependency; sesman may be static.
    systemctl enable xrdp.service
    systemctl restart xrdp-sesman.service
    systemctl restart xrdp.service
    systemctl enable --now "$RECOVERY_TIMER_UNIT"
    systemctl is-active --quiet xrdp-sesman.service || die 'xrdp-sesman did not start.'
    systemctl is-active --quiet xrdp.service || die 'xrdp did not start.'
    systemctl is-active --quiet "$RECOVERY_TIMER_UNIT" || \
        die 'XRDP reconnect recovery timer did not start.'

    log 'Checking actual listener addresses and negotiating an RDP TLS connection'
    python3 - "$RDP_PORT" "$SESMAN_PORT" "$TLS_CERT" <<'VERIFY'
import socket
import ssl
import subprocess
import sys
import time
import ipaddress

rdp_port, sesman_port = map(int, sys.argv[1:3])
cert = sys.argv[3]

def check_listener(port, process):
    result = subprocess.run(['ss', '-H', '-ltnp', f'sport = :{port}'],
                            capture_output=True, text=True, check=True)
    records = result.stdout.splitlines()
    if not records:
        return []
    addresses = []
    for record in records:
        fields = record.split()
        if len(fields) < 5:
            raise RuntimeError(f'Cannot parse listener on {port}: {record}')
        address_port = fields[3]
        try:
            if address_port.startswith('['):
                address, separator, socket_port = address_port[1:].partition(']:')
            else:
                address, separator, socket_port = address_port.rpartition(':')
            bind_address = ipaddress.ip_address(address)
        except ValueError as error:
            raise RuntimeError(f'Cannot parse listener on {port}: {record}') from error
        expected_address = (str(bind_address) == '127.0.0.1'
                            if process == 'xrdp' else bind_address.is_loopback)
        if not separator or socket_port != str(port) or not expected_address:
            raise RuntimeError(f'Unexpected/exposed listener on {port}: {record}')
        if f'("{process}",' not in record:
            raise RuntimeError(f'Port {port} is owned by another process: {record}')
        addresses.append(address)
    return addresses

for attempt in range(30):
    rdp_addresses = check_listener(rdp_port, 'xrdp')
    sesman_addresses = check_listener(sesman_port, 'xrdp-sesman')
    if rdp_addresses and sesman_addresses:
        break
    time.sleep(0.3)
else:
    raise RuntimeError('Expected localhost-only XRDP/sesman listeners were not found')

def receive_exact(connection, size):
    data = b''
    while len(data) < size:
        part = connection.recv(size - len(data))
        if not part:
            raise RuntimeError('XRDP closed the connection during RDP negotiation')
        data += part
    return data

context = ssl.create_default_context(cafile=cert)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.maximum_version = ssl.TLSVersion.TLSv1_3
with socket.create_connection(('127.0.0.1', rdp_port), timeout=5) as connection:
    # TPKT + X.224 connection request + RDP_NEG_REQ, requesting PROTOCOL_SSL.
    connection.sendall(bytes.fromhex('030000130ee000000000000100080001000000'))
    header = receive_exact(connection, 4)
    length = int.from_bytes(header[2:4], 'big')
    if header[:2] != b'\x03\x00' or not 19 <= length <= 4096:
        raise RuntimeError('Invalid RDP negotiation header')
    response = header + receive_exact(connection, length - 4)
    negotiation = response[-8:]
    if (response[5] != 0xd0 or negotiation[0] != 2 or
            negotiation[2:4] != b'\x08\x00' or
            int.from_bytes(negotiation[4:], 'little') != 1):
        raise RuntimeError(f'XRDP did not select TLS: {response.hex()}')
    with context.wrap_socket(connection, server_hostname='localhost') as secured:
        print(f'RDP TLS handshake passed: {secured.version()}, {secured.cipher()[0]}')
print(f"XRDP: {', '.join(f'{address}:{rdp_port}' for address in rdp_addresses)}")
print(f"sesman: {', '.join(f'[{address}]:{sesman_port}' if ':' in address else f'{address}:{sesman_port}' for address in sesman_addresses)}")
VERIFY

    log 'Checking existing SSH and firewalld status'
    if systemctl is-active --quiet firewalld.service; then
        firewall_state=running
    else
        firewall_state='not running'
        warn 'firewalld is not running. XRDP still listens only on localhost.'
    fi
    printf 'firewalld: %s; its rules were not changed.\n' "$firewall_state"
    if ! systemctl is-active --quiet ssh.service && \
       ! systemctl is-active --quiet ssh.socket; then
        warn 'The standard SSH service/socket is not active; check your existing SSH server.'
    fi

    # This check is informational. Capture sshd output before parsing it.
    # No early-exiting awk pipeline: avoids the earlier SIGPIPE/pipefail bug.
    ssh_port=22
    if [[ -x /usr/sbin/sshd ]] && \
       ssh_dump=$(/usr/sbin/sshd -T 2> "$WORK_DIR/sshd-check.err"); then
        ssh_port=$(awk '$1 == "port" && !seen {print $2; seen=1}' <<< "$ssh_dump")
        if [[ ! "$ssh_port" =~ ^[0-9]+$ ]]; then
            ssh_port=22
            warn 'Could not determine an SSH port; the example below uses 22.'
        fi
        if [[ "$ssh_dump" == *'allowtcpforwarding no'* ]]; then
            warn 'SSH reports AllowTcpForwarding=no. Your SSH policy must permit local forwarding.'
        fi
    else
        warn 'sshd -T was unavailable or failed; the example below uses port 22.'
    fi
    # Socket activation/Match rules may differ from sshd -T. Prefer this SSH
    # connection's actual server port when the environment provides it.
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r ssh_client_ip ssh_client_port ssh_server_ip ssh_server_port \
            <<< "$SSH_CONNECTION"
        if [[ "${ssh_server_port:-}" =~ ^[0-9]+$ ]]; then
            ssh_port=$ssh_server_port
        fi
    fi
    ssh_user=${SUDO_USER:-sharif}
    [[ "$ssh_user" != root ]] || ssh_user=sharif

    log 'Installation complete'
    printf 'XRDP package: %s\nConfiguration backup: %s\n' "$installed_version" "$BACKUP_DIR"
    printf 'Normal users (UID >= %s) can authenticate with their Linux passwords.\n' "$uid_min"
    printf 'Existing PAM account restrictions still apply. Root RDP login is disabled.\n'
    printf '\nFrom your CLIENT computer, keep this tunnel running:\n\n'
    printf 'ssh -p %s -N -L 127.0.0.1:%s:127.0.0.1:%s -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 %s@SERVER_LAN_IP\n' \
        "$ssh_port" "$LOCAL_PORT" "$RDP_PORT" "$ssh_user"
    printf '\nUse the SSH port you normally use if it differs from this example.\n'
    printf 'Use the LAN server address; existing SSH/firewalld rules govern tunnel access.\n'
    printf 'Connect your RDP client to 127.0.0.1:%s; select Xorg if asked.\n' "$LOCAL_PORT"
    printf '\nThe TLS certificate is self-signed. Verify its fingerprint on first use or renewal:\n'
    openssl x509 -in "$TLS_CERT" -noout -fingerprint -sha256
    printf '\nReruns reuse a valid certificate, replace managed settings without duplicates,\n'
    printf 'create a new backup, and restart XRDP. Log out of RDP before rerunning.\n'
    printf 'Disconnected sessions are retained; session matching ignores window-size changes.\n'
    printf 'A recovery timer restarts only xrdp.service after a failed existing-session reconnect.\n'
}

main "$@"
