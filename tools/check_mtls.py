#!/usr/bin/env python3
"""Native Odin/OpenSSL mTLS positive and negative integration checks, without SQL."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import ssl
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(argv):
    environment = os.environ.copy()
    environment["OPENSSL_CONF"] = os.devnull
    result = subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=60, env=environment)
    if result.returncode:
        raise RuntimeError(f'Command failed: {argv[0]}\n{result.stderr}')
    return result


def certificates(directory, openssl):
    def ca(name):
        run([openssl, 'req', '-x509', '-newkey', 'ed25519', '-noenc', '-days', '2',
             '-subj', '/CN=' + name, '-keyout', directory / (name + '.key'),
             '-out', directory / (name + '.pem'),
             '-addext', 'basicConstraints=critical,CA:TRUE',
             '-addext', 'keyUsage=critical,keyCertSign,cRLSign'])
    ca('ca')
    ca('rogue-ca')
    def leaf(name, dns, issuer='ca', purpose='serverAuth,clientAuth', san=True, days=2):
        run([openssl, 'req', '-new', '-newkey', 'ed25519', '-noenc', '-subj', '/CN=' + dns,
             '-keyout', directory / (name + '.key'), '-out', directory / (name + '.csr')])
        extensions = ('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
                      'extendedKeyUsage=' + purpose + '\n')
        if san:
            extensions += 'subjectAltName=DNS:' + dns + '\n'
        (directory / (name + '.ext')).write_text(extensions)
        run([openssl, 'x509', '-req', '-in', directory / (name + '.csr'),
             '-CA', directory / (issuer + '.pem'), '-CAkey', directory / (issuer + '.key'),
             '-set_serial', str(len(list(directory.glob('*.pem'))) + 1), '-days', str(days),
             '-extfile', directory / (name + '.ext'), '-out', directory / (name + '.pem')])
    leaf('server', 'node-1.test.sqlodin')
    leaf('client', 'node-2.test.sqlodin')
    leaf('rogue', 'node-2.test.sqlodin', issuer='rogue-ca')
    leaf('wildcard', '*.test.sqlodin')
    leaf('cn-only', 'node-2.test.sqlodin', san=False)
    leaf('wrong-purpose', 'node-2.test.sqlodin', purpose='serverAuth')
    leaf('expired', 'node-2.test.sqlodin', days=0)


def native_pair(binary, directory, client='client', server_peer='node-2.test.sqlodin',
                client_peer='node-1.test.sqlodin', client_key=None, nonblocking=True):
    left, right = socket.socketpair()
    left.setblocking(not nonblocking)
    right.setblocking(False)
    processes = []
    try:
        for role, sock, identity, expected, key in (
                ('server', left, 'server', server_peer, 'server'),
                ('client', right, client, client_peer, client_key or client)):
            processes.append(subprocess.Popen(
                [str(binary), role, str(sock.fileno()), str(directory / (identity + '.pem')),
                 str(directory / (key + '.key')), str(directory / 'ca.pem'), expected],
                pass_fds=(sock.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE))
        left.close()
        right.close()
        result = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=8)
            result.append({'returncode': process.returncode, 'stdout': stdout.decode(), 'stderr': stderr.decode()})
        return result
    finally:
        left.close()
        right.close()
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def python_peer(binary, directory, mode):
    left, right = socket.socketpair()
    left.setblocking(False)
    right.settimeout(7)
    process = subprocess.Popen(
        [str(binary), 'server', str(left.fileno()), str(directory / 'server.pem'),
         str(directory / 'server.key'), str(directory / 'ca.pem'), 'node-2.test.sqlodin'],
        pass_fds=(left.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    left.close()
    reply, peer_error = b'', None
    started = time.monotonic()
    try:
        if mode == 'plaintext':
            right.sendall(b'not tls at all')
            right.shutdown(socket.SHUT_WR)
        elif mode == 'idle':
            pass
        else:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.load_verify_locations(directory / 'ca.pem')
            context.minimum_version = ssl.TLSVersion.TLSv1_3
            if mode != 'missing-certificate':
                context.load_cert_chain(directory / 'client.pem', directory / 'client.key')
            if mode == 'tls12':
                context.minimum_version = ssl.TLSVersion.TLSv1_2
                context.maximum_version = ssl.TLSVersion.TLSv1_2
            try:
                right = context.wrap_socket(right, server_hostname='node-1.test.sqlodin')
                for byte in b'ping':
                    right.sendall(bytes([byte]))
                while len(reply) < 4:
                    chunk = right.recv(4-len(reply))
                    if not chunk:
                        break
                    reply += chunk
            except (ssl.SSLError, OSError) as exc:
                peer_error = str(exc)
        stdout, stderr = process.communicate(timeout=8)
        return {'returncode': process.returncode, 'reply': reply.decode(errors='replace'),
                'stdout': stdout.decode(), 'stderr': stderr.decode(), 'peer_error': peer_error,
                'seconds': time.monotonic()-started}
    finally:
        right.close()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openssl', default=os.environ.get('OPENSSL', str(ROOT / 'build/native/openssl')))
    parser.add_argument('--library-dir', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output exists; retain earlier evidence')
    with tempfile.TemporaryDirectory(prefix='sqlodin-mtls-') as scratch:
        directory = Path(scratch)
        binary = directory / 'probe'
        build = ['odin', 'build', ROOT / 'internal/mtls_probe', '-vet', '-strict-style',
                 '-o:speed' if platform.system() == 'Linux' else '-debug', '-out:' + str(binary)]
        if args.library_dir:
            build.append('-extra-linker-flags:-L' + str(args.library_dir.resolve()))
        run(build)
        certificates(directory, args.openssl)
        # The deliberately zero-day certificate must be strictly beyond notAfter.
        time.sleep(1.1)
        cases = []
        for name, options, accepted in (
                ('native_mutual_tls13', {}, True),
                ('reject_wrong_client_identity', {'server_peer': 'node-3.test.sqlodin'}, False),
                ('reject_wrong_server_identity', {'client_peer': 'node-3.test.sqlodin'}, False),
                ('reject_untrusted_ca', {'client': 'rogue'}, False),
                ('reject_wildcard_identity', {'client': 'wildcard'}, False),
                ('reject_common_name_fallback', {'client': 'cn-only'}, False),
                ('reject_wrong_certificate_purpose', {'client': 'wrong-purpose'}, False),
                ('reject_expired_certificate', {'client': 'expired'}, False),
                ('reject_key_certificate_mismatch', {'client_key': 'server'}, False),
                ('reject_blocking_socket', {'nonblocking': False}, False)):
            result = native_pair(binary, directory, **options)
            passed = all(r['returncode'] == (0 if accepted else 1) for r in result)
            cases.append({'name': name, 'passed': passed, 'processes': result})
        for mode in ['fragmented', 'missing-certificate', 'tls12', 'plaintext', 'idle']:
            result = python_peer(binary, directory, mode)
            passed = (result['returncode'] == 0 and result['reply'] == 'pong') if mode == 'fragmented' else (
                result['returncode'] == 1 and result['reply'] != 'pong' and result['seconds'] < 7)
            cases.append({'name': mode, 'passed': passed, 'result': result})
        sources = [*ROOT.glob('transport/mtls/*.odin'), *ROOT.glob('internal/mtls_probe/*.odin'), Path(__file__)]
        report = {'complete': all(c['passed'] for c in cases), 'checks': cases,
                  'run_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'platform': platform.platform(), 'openssl': run([args.openssl, 'version']).stdout.strip(),
                  'python_openssl': ssl.OPENSSL_VERSION,
                  'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in sources},
                  'scope': 'optional native TLS primitive over inherited socket pairs; '
                           'no SQL service, enrollment, dynamic membership, certificate rotation or production qualification'}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')
        for case in cases:
            print(('PASS ' if case['passed'] else 'FAIL ') + case['name'])
        if not report['complete']:
            raise SystemExit('mTLS checks failed; inspect preserved report')


if __name__ == '__main__':
    main()
