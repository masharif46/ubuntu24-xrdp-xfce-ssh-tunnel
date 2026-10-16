# Ubuntu 24.04 XRDP + XFCE over an SSH tunnel

An installer for a lightweight XFCE remote desktop on **Ubuntu Server 24.04**. XRDP accepts RDP connections only on the server's IPv4 loopback address. Connect from a client by forwarding a local port through SSH; the script does not open RDP in firewalld or change SSH settings.

Repository: <https://github.com/masharif46/ubuntu24-xrdp-xfce-ssh-tunnel>

## What is included

```text
setup-xrdp-xfce-ubuntu24.sh     Installer
validation/check_xrdp_installer.py  Isolated, non-root checks for the installer
README.md                       Setup, security, and troubleshooting guide
```

## What the installer configures

- Installs XFCE, XRDP, the `xorgxrdp` Xorg backend, and supporting packages from the configured Ubuntu APT sources.
- Binds XRDP to `127.0.0.1:3389`. The port is reachable through an SSH tunnel, not directly from the LAN or Internet.
- Uses TLS 1.2 or 1.3 with a dedicated self-signed certificate. A matching certificate that is valid for more than 30 days is reused on reruns.
- Starts XFCE with a separate D-Bus session for each XRDP session.
- Retains disconnected Xorg sessions, uses TCP keepalive, and matches a user's
  session without creating another one merely because the RDP window size changed.
- Installs a conservative recovery timer which restarts only the XRDP frontend
  after the exact `Error connecting to user session` reconnect failure. It does
  not restart `xrdp-sesman` or intentionally terminate the user's Xorg/XFCE session.
- Installs a scoped `needrestart` rule so unrelated `apt install` or package
  upgrades do not automatically restart `xrdp` or `xrdp-sesman` and terminate
  the desktop session. XRDP package updates remain pending in the running
  daemons until the next reboot or a deliberate maintenance-window restart.
- Allows accounts with a UID at or above the system's `UID_MIN` to try Linux password authentication. Existing PAM account rules still apply; root login is disabled. SSH keys alone do not replace the Linux account password at the XRDP login screen.
- Keeps the XRDP session manager (`sesman`) on loopback. Its listener can appear as `127.0.0.1:3350` or `[::1]:3350`, depending on the Ubuntu XRDP build. Both are local-only; the installer rejects non-loopback addresses. It requires the RDP listener on IPv4 loopback so the tunnel target works.
- Checks that the RDP listener negotiates TLS before declaring success.
- Backs up XRDP and session configuration before changes. Backups go to `/var/backups/xrdp-xfce/`.
- Purges configuration files only for matching XFCE packages that are already removed (`rc` status in dpkg). Their configuration files are backed up first.

The installer does **not** change SSH configuration, firewalld rules, UFW rules, display managers, the boot target, or users' home directories. It does not run a distribution upgrade or `apt autoremove`. Each successful rerun creates another backup and restarts XRDP; log out of remote desktop sessions before rerunning.

The recovery timer and package-restart guard are best-effort: no script can prevent an ISP outage, an SSH tunnel failure, an XRDP/Xorg software bug, an explicit administrator restart, or a reboot. They are designed to keep the desktop session alive when the RDP window or SSH tunnel disconnects, make the observed reconnect failure recover automatically, and prevent unrelated APT work from restarting XRDP. A timer-triggered frontend restart can briefly disconnect other RDP clients, but it does not normally close their applications.

## Requirements

- Ubuntu Server 24.04 (the script checks `/etc/os-release`).
- A working `systemd` system, `sudo`, network access to the configured Ubuntu APT sources, and enough disk space for packages and backups.
- An SSH server that you can reach from your client. SSH must permit local port forwarding for the tunnel to work. The script reports `AllowTcpForwarding no` when it detects it, but does not alter SSH policy.
- A Linux account with a password that is permitted by the server's PAM rules. The account must meet the system `UID_MIN` threshold.

## Install on the server

Copy `setup-xrdp-xfce-ubuntu24.sh` to the Ubuntu server, then run it from SSH or a server console:

```bash
chmod +x setup-xrdp-xfce-ubuntu24.sh
sudo ./setup-xrdp-xfce-ubuntu24.sh
```

Or run it without changing the executable bit:

```bash
sudo bash ./setup-xrdp-xfce-ubuntu24.sh
```

The success output includes the observed XRDP and sesman listener addresses, an RDP TLS handshake result, a suggested SSH command, and the SHA-256 certificate fingerprint. The first run may show a new certificate prompt in your RDP client because the certificate is self-signed. Verify the fingerprint printed by the installer before trusting the certificate. The fingerprint can be displayed again on the server with:

```bash
sudo openssl x509 -in /etc/xrdp/tls/xrdp.crt -noout -fingerprint -sha256
```

## Connect from the client

On the client computer, start this SSH tunnel and leave it running. Replace `SERVER_LAN_IP` with the server's LAN address:

```bash
ssh -N -L 127.0.0.1:13389:127.0.0.1:3389 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  SSH_USER@SERVER_LAN_IP
```

Replace `SSH_USER` with the normal Ubuntu account that you use for the tunnel. If SSH uses a custom port, add `-p PORT` after `ssh`.

Open your RDP client and connect to:

```text
127.0.0.1:13389
```

Enter the account's Linux username and password. If prompted for a session type, choose **Xorg**. The client-side port `13389` avoids conflicting with a local RDP service; the XRDP service on the server still uses `3389`.

## Health check and tunnel reconnect

Run the read-only health audit from SSH or the server console:

```bash
sudo bash setup-xrdp-xfce-ubuntu24.sh --doctor
```

It does not install packages or restart XRDP. It checks service state, listeners, TLS/session-retention settings, the `needrestart` protection, disk space, memory, and swap. The default installer mode is disruptive because it restarts XRDP; use it only from SSH or a server console.

If Windows loses the tunnel, the server-side desktop session remains retained, but the SSH client itself must reconnect. For an automatic reconnect loop, run this in a Windows PowerShell window and stop it with `Ctrl+C`:

```powershell
while ($true) {
    & ssh -N -L 127.0.0.1:13389:127.0.0.1:3389 `
        -o ExitOnForwardFailure=yes `
        -o ServerAliveInterval=30 `
        -o ServerAliveCountMax=3 `
        SSH_USER@SERVER_LAN_IP
    Start-Sleep -Seconds 5
}
```

Use the same SSH key, port, and username that you normally use. This reconnects the tunnel; it does not log out the Ubuntu desktop session.

## Re-running and recovery

The installer is designed to be safe to rerun after a completed run or an ordinary interrupted run. It avoids duplicate managed settings, reuses a valid certificate, and writes a fresh backup. Package manager errors, interrupted system upgrades, disk errors, and hand-edited configuration can still require troubleshooting.

If the installer stops after a change, its error handler stops XRDP rather than leaving a partially configured RDP service running. It does not automatically restore the previous configuration. Check the printed backup path, fix the reported cause, and rerun the installer. If a previous run left XRDP stopped after configuration is complete, a successful rerun starts and verifies it.

Do not change sesman's listener to `0.0.0.0` to work around an IPv6 loopback address. Port `3350` is for XRDP's internal session manager and should remain local-only.

## Troubleshooting

Check service status and listening addresses:

```bash
sudo systemctl status xrdp xrdp-sesman --no-pager
sudo ss -ltnp | grep -E ':(3389|3350)\b'
```

Expected listeners are XRDP on `127.0.0.1:3389` and sesman on a loopback address (`127.0.0.1:3350` or `[::1]:3350`). XRDP must not listen on `0.0.0.0:3389`, a LAN address, or `[::]:3389`.

Read recent service logs if startup or login fails:

```bash
sudo journalctl -u xrdp -u xrdp-sesman -n 80 --no-pager
sudo tail -n 80 /var/log/xrdp.log /var/log/xrdp-sesman.log
```

Also check that the tunnel is still open, the RDP client is pointed at `127.0.0.1:13389`, the correct Linux password is being used, and SSH permits local port forwarding. Do not open TCP `3389` or `3350` to the network for this setup.

Check the recovery timer with:

```bash
sudo systemctl status xrdp-session-recovery.timer --no-pager
sudo journalctl -u xrdp-session-recovery.service -n 30 --no-pager
```

The client tunnel should use keepalives and remain running:

```bash
ssh -N -L 127.0.0.1:13389:127.0.0.1:3389 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  SSH_USER@SERVER_LAN_IP
```

## Run the isolated checks

The checks do not install packages or change `/etc` files. They need Python 3, Bash, and OpenSSL:

```bash
python3 validation/check_xrdp_installer.py
```

They check script syntax, repeated configuration edits, TLS certificate reuse and key matching, the SSH-port detection error path, RDP/TLS negotiation, and loopback versus external listener handling. A restricted container may block local sockets; in that case the RDP/TLS socket test is reported as skipped. The checks do not replace a real login test on Ubuntu 24.04.

