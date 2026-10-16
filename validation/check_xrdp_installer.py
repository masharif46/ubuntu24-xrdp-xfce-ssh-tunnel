"""Isolated checks: never install packages or write the host's /etc files."""
import ast
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
source = (root / 'setup-xrdp-xfce-ubuntu24.sh').read_text()
blocks = {
    name: re.search(r"<<'" + name + r"'\n(.*?)\n" + name + r"\n", source, re.S).group(1)
    for name in ('CONFIG', 'VERIFY', 'SESSION', 'RECOVERY')
}
for name in ('CONFIG', 'VERIFY'):
    compile(blocks[name], f'<{name}>', 'exec')
subprocess.run(['bash', '-n', str(root / 'setup-xrdp-xfce-ubuntu24.sh')], check=True)
subprocess.run(['sh', '-n'], input=blocks['SESSION'], text=True, check=True)
subprocess.run(['sh', '-n'], input=blocks['RECOVERY'], text=True, check=True)

tree = ast.parse(blocks['CONFIG'])
definitions = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef))]
definitions += [node for node in tree.body if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id in ('begin', 'end')
                        for target in node.targets)]
namespace = {}
exec(compile(ast.Module(body=definitions, type_ignores=[]), '<config functions>', 'exec'), namespace)
rewrite = namespace['rewrite_ini']
pam_rewrite = namespace['rewrite_pam']
atomic_write = namespace['atomic_write']

fixture = '''; preserved comment
[Globals]
port=3389
PORT=9999
security_layer=negotiate
; port=4444
unmanaged=true
[Xorg]
port=-1
param=first
param=second
[Xvnc]
port=-1
param=other-one
param=other-two
'''
updates = {'globals': {'port': ['tcp://127.0.0.1:3389'], 'security_layer': ['tls'],
                       'ssl_protocols': ['TLSv1.2, TLSv1.3'],
                       'tcp_keepalive': ['true'], 'max_bpp': ['32']},
           'xorg': {'param': ['/usr/lib/xorg/Xorg', '-config', 'xrdp/xorg.conf']}}
configured = rewrite(fixture, updates)
assert configured.count('port=tcp://127.0.0.1:3389') == 1
assert 'PORT=9999' not in configured and '; port=4444' in configured
assert 'unmanaged=true' in configured
assert '[Xvnc]\nport=-1\nparam=other-one\nparam=other-two' in configured
assert '[Xorg]\nport=-1\nparam=/usr/lib/xorg/Xorg\nparam=-config\nparam=xrdp/xorg.conf' in configured
sessions = '''[Sessions]\nKillDisconnected=true\nPolicy=UBD\n'''
session_updates = {'sessions': {'KillDisconnected': ['false'], 'Policy': ['UB']}}
session_configured = rewrite(sessions, session_updates)
assert 'KillDisconnected=false' in session_configured and 'Policy=UB' in session_configured
assert 'xrdp-session-recovery.sh' in source
assert 'xrdp-session-recovery.timer' in source
assert 'zz-xrdp-keep-session.conf' in source
assert 'override_rc' in source
assert "xrdp\\.service" in source and "xrdp-sesman\\.service" in source
assert "reconnected session:" in source
assert '--doctor' in source and '--help' in source
assert 'needrestart_protection_ok' in source
assert 'sharif' not in source
for _ in range(20):
    assert rewrite(configured, updates) == configured
assert rewrite(fixture.replace('\n', '\r\n').rstrip(), updates) == rewrite(fixture, updates)
for bad in ('[Globals]\nport=3389\n[globals]\nport=22\n[Xorg]\n', '[Globals]\nport=3389\n'):
    try:
        rewrite(bad, updates)
    except ValueError:
        pass
    else:
        raise AssertionError('Malformed INI configuration accepted')
for pam in ('#%PAM-1.0\n@include common-account\n', '\n\n#%PAM-1.0\n@include common-account\n'):
    result = pam_rewrite(pam, '1000')
    for _ in range(20):
        assert pam_rewrite(result, '1000') == result
    assert result.count('pam_succeed_if.so') == 1 and result.endswith(pam)
    changed = pam_rewrite(result, '2000')
    assert changed.count('pam_succeed_if.so') == 1 and 'uid >= 2000' in changed
for malformed in (namespace['begin'], namespace['end'] + '\n' + namespace['begin']):
    try:
        pam_rewrite(malformed, '1000')
    except ValueError:
        pass
    else:
        raise AssertionError('Malformed PAM block accepted')

with tempfile.TemporaryDirectory(prefix='xrdp-validation-', dir=root / 'validation') as temporary:
    work = Path(temporary)
    config = work / 'example.ini'
    config.write_text(fixture)
    config.chmod(0o640)
    atomic_write(config, configured)
    before = config.stat()
    atomic_write(config, configured)
    assert config.stat().st_ino == before.st_ino
    assert config.stat().st_mtime_ns == before.st_mtime_ns
    assert config.stat().st_mode & 0o777 == 0o640
    symlink = work / 'link.ini'
    symlink.symlink_to(config)
    try:
        atomic_write(symlink, configured)
    except ValueError:
        pass
    else:
        raise AssertionError('Symlink configuration accepted')

    cert, key = work / 'xrdp.crt', work / 'xrdp.key'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes',
                    '-days', '825', '-subj', '/CN=localhost',
                    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
                    '-addext', 'basicConstraints=critical,CA:FALSE',
                    '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment',
                    '-addext', 'extendedKeyUsage=serverAuth',
                    '-keyout', str(key), '-out', str(cert)],
                   check=True, capture_output=True)
    key.chmod(0o640)
    # Execute the installer's exact reuse predicate, with isolated file paths.
    predicate = source.split('    if [[ -s "$TLS_CERT"', 1)[1].split('; then\n', 1)[0]
    predicate = '[[ -s "$TLS_CERT"' + predicate
    test_reuse = '\n'.join([
        'set -Eeuo pipefail',
        'TLS_CERT=$1; TLS_KEY=$2; cert_pub=$3; key_pub=$4',
        f'if {predicate}; then printf REUSE; else printf RENEW; fi',
    ])
    before = (cert.read_bytes(), key.read_bytes(), cert.stat().st_mtime_ns, key.stat().st_mtime_ns)
    for _ in range(3):
        answer = subprocess.check_output(['bash', '-c', test_reuse, 'test', str(cert), str(key),
                                          str(work / 'cert.pub'), str(work / 'key.pub')], text=True)
        assert answer == 'REUSE', answer
    assert before == (cert.read_bytes(), key.read_bytes(), cert.stat().st_mtime_ns, key.stat().st_mtime_ns)
    wrong_key = work / 'other.key'
    subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048',
                    '-out', str(wrong_key)], check=True, capture_output=True)
    answer = subprocess.check_output(['bash', '-c', test_reuse, 'test', str(cert), str(wrong_key),
                                     str(work / 'cert.pub'), str(work / 'key.pub')], text=True)
    assert answer == 'RENEW', answer

    # Large sshd output used to trigger SIGPIPE in the old early-exit pipeline.
    fake_sshd = work / 'fake-sshd'
    fake_sshd.write_text('#!/usr/bin/env python3\nimport sys\n'
                         'print("port 2222")\nprint("setting value\\n" * 40000)\n'
                         'sys.exit(int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0)\n')
    fake_sshd.chmod(0o755)
    detection = source.split('    ssh_port=22\n', 1)[1].split('    # Socket activation/', 1)[0]
    detection = 'ssh_port=22\n' + detection.replace('/usr/sbin/sshd', str(fake_sshd))
    detection = detection.replace('sshd -T', 'sshd -T')
    preamble = 'set -Eeuo pipefail\nWORK_DIR=$1\nwarn(){ printf "%s\\n" "$*" >&2; }\n'
    for status, expected in ((0, '2222'), (1, '22')):
        tested = detection.replace(f'{fake_sshd} -T', f'{fake_sshd} {status}')
        run = subprocess.run(['bash', '-c', preamble + tested + '\nprintf "%s" "$ssh_port"',
                              'test', str(work)], text=True, capture_output=True)
        assert run.returncode == 0, run.stderr
        assert run.stdout == expected, (run.stdout, run.stderr)

    # Exercise the actual RDP/TLS verifier against a local mock RDP server.
    # This checks protocol parsing, certificate validation, and listener rejection;
    # it does not pretend to be an Ubuntu XRDP desktop-login test.
    fake_bin = work / 'bin'
    fake_bin.mkdir()
    fake_ss = fake_bin / 'ss'
    fake_ss.write_text('#!/usr/bin/env python3\nimport os,sys\n'
                       'p=sys.argv[-1].split(":")[-1]\n'
                       'name="xrdp" if p==os.environ["RDP_TEST_PORT"] else "xrdp-sesman"\n'
                       'host=os.environ.get("RDP_TEST_HOST" if name=="xrdp" else "SESMAN_TEST_HOST", "127.0.0.1")\n'
                       'print(f\'LISTEN 0 2 {host}:{p} 0.0.0.0:* users:(("{name}",pid=1,fd=3))\')\n')
    fake_ss.chmod(0o755)
    try:
        server_socket = socket.socket()
        server_socket.bind(('127.0.0.1', 0))
    except PermissionError as error:
        print(f'SKIP: RDP/TLS socket test; this environment blocks loopback sockets ({error}).')
    else:
        rdp_port = server_socket.getsockname()[1]
        server_socket.listen(1)
        server_socket.settimeout(15)
        server_errors = []

        def mock_rdp():
            try:
                with server_socket:
                    connection, _ = server_socket.accept()
                    with connection:
                        request = b''
                        while len(request) < 19:
                            request += connection.recv(19 - len(request))
                        assert request.hex() == '030000130ee000000000000100080001000000'
                        # Valid nonzero RDP_NEG_RSP flags must also be accepted.
                        connection.sendall(bytes.fromhex('030000130ed000000000000201080001000000'))
                        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                        server_context.load_cert_chain(cert, key)
                        with server_context.wrap_socket(connection, server_side=True) as secured:
                            assert secured.version() in ('TLSv1.2', 'TLSv1.3')
            except BaseException as error:
                server_errors.append(error)

        worker = threading.Thread(target=mock_rdp)
        worker.start()
        verify_file = work / 'verify.py'
        verify_file.write_text(blocks['VERIFY'])
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'],
                   RDP_TEST_PORT=str(rdp_port), SESMAN_TEST_HOST='::1')
        run = subprocess.run(['python3', str(verify_file), str(rdp_port), str(rdp_port + 1), str(cert)],
                             env=env, text=True, capture_output=True, timeout=15)
        worker.join(timeout=15)
        assert not worker.is_alive()
        assert not server_errors, server_errors
        assert run.returncode == 0, (run.stdout, run.stderr)
        assert 'RDP TLS handshake passed' in run.stdout and 'sesman: [::1]:' in run.stdout
        for exposed in ('0.0.0.0', '[::]', '192.168.1.10'):
            bad_env = dict(env, SESMAN_TEST_HOST=exposed)
            rejected = subprocess.run(['python3', str(verify_file), str(rdp_port), str(rdp_port + 1), str(cert)],
                                      env=bad_env, text=True, capture_output=True, timeout=5)
            assert rejected.returncode != 0 and 'Unexpected/exposed listener' in rejected.stderr
        bad_rdp_loopback = dict(env, RDP_TEST_HOST='::1')
        rejected = subprocess.run(['python3', str(verify_file), str(rdp_port), str(rdp_port + 1), str(cert)],
                                  env=bad_rdp_loopback, text=True, capture_output=True, timeout=5)
        assert rejected.returncode != 0 and 'Unexpected/exposed listener' in rejected.stderr
        print('PASS: RDP TLS negotiation; loopback IPv4/IPv6 and external-listener rejection.')

print('PASS: Bash/sh syntax; embedded Python compilation; 20-pass INI/PAM idempotency;')
print('      config metadata/no-op writes; TLS reuse and key-mismatch renewal; large/failing sshd checks.')
