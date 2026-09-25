#!/usr/bin/env python3
"""Build pinned static SQLite/FTS5, sqlite-vec and OpenSSL on macOS or Linux.

Only project-local files are written. Sources are verified before compilation;
validated archives are reused. No system package manager or shared-library fallback.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/native'
CACHE = ROOT / 'build/downloads'
PINS = json.loads(Path(__file__).with_name('native_sources.json').read_text())
SQLITE_FLAGS = ['-O3', '-DNDEBUG', '-fPIC', '-DSQLITE_THREADSAFE=1',
                '-DSQLITE_OMIT_LOAD_EXTENSION', '-DSQLITE_OMIT_DEPRECATED',
                '-DSQLITE_DQS=0', '-DSQLITE_ENABLE_FTS5', '-DHAVE_USLEEP=1']
VEC_FLAGS = ['-O3', '-DNDEBUG', '-fPIC', '-DSQLITE_CORE', '-DSQLITE_VEC_STATIC', '-DSQLITE_VEC_OMIT_FS']
TLS_FLAGS = ['no-shared', 'no-dso', 'no-module', 'no-engine', 'no-zlib',
             '--libdir=lib', '--openssldir=/sqlodin/no-system-openssl']


def vec_identity():
    contract = dict(domain='SQLodin/sqlite-vec-build/v1', pin=PINS['vec'], flags=VEC_FLAGS)
    return hashlib.sha256(json.dumps(contract, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def download(pin, offline):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / pin['url'].rsplit('/', 1)[1]
    if not path.is_file():
        if offline: raise SystemExit(f'Offline source missing: {path}')
        print('Downloading', path.name, flush=True)
        with urllib.request.urlopen(pin['url'], timeout=120) as response:
            with tempfile.NamedTemporaryFile(dir=CACHE, delete=False) as target:
                temporary = Path(target.name)
                try:
                    shutil.copyfileobj(response, target)
                    target.flush()
                except BaseException:
                    temporary.unlink(missing_ok=True)
                    raise
        temporary.replace(path)
    if 'sha256' in pin and sha(path) != pin['sha256']:
        raise SystemExit(f'Pinned archive hash mismatch: {path}; remove it before retrying')
    return path


def sources(kind, directory, offline):
    pin = PINS[kind]
    archive = zipfile.ZipFile(download(pin, offline)) if directory is None else None
    try:
        for name, expected in pin['files'].items():
            if directory:
                data = (directory / name).read_bytes()
            else:
                matches = [p for p in archive.namelist() if Path(p).name == name]
                if len(matches) != 1: raise SystemExit(f'Ambiguous/missing source: {name}')
                data = archive.read(matches[0])
            if hashlib.sha256(data).hexdigest() != expected:
                raise SystemExit(f'Pinned source hash mismatch: {name}')
            (OUT / name).write_bytes(data)
    finally:
        if archive: archive.close()


def cached(path, inputs, files):
    try:
        old = json.loads(path.read_text())
        return (old['inputs'] == inputs and
                old['artifacts'] == {name: sha(OUT / name) for name in files})
    except (OSError, KeyError, ValueError):
        return False


def record(path, inputs, files):
    path.write_text(json.dumps(dict(inputs=inputs, artifacts={name: sha(OUT / name) for name in files}),
                               indent=2) + '\n')


def run(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def build(args):
    system, machine = platform.system(), platform.machine()
    target = {('Darwin', 'arm64'): 'darwin64-arm64-cc',
              ('Darwin', 'x86_64'): 'darwin64-x86_64-cc',
              ('Linux', 'x86_64'): 'linux-x86_64',
              ('Linux', 'aarch64'): 'linux-aarch64'}.get((system, machine))
    if target is None: raise SystemExit(f'Unsupported native target: {system}/{machine}')
    cc = shutil.which(os.environ.get('CC', 'cc'))
    ar = shutil.which(os.environ.get('AR', 'ar'))
    if not cc or not ar: raise SystemExit('C compiler and ar are required')
    common = dict(system=system, machine=machine, compiler=cc, archiver=ar,
                  compiler_version=subprocess.check_output([cc, '--version'], text=True).splitlines()[0],
                  builder_sha256=sha(__file__))
    sql_inputs = dict(**common, pins={k: PINS[k] for k in ('sqlite', 'vec')},
                      sqlite_flags=SQLITE_FLAGS, vec_flags=VEC_FLAGS)
    sql_files = ['libsqlite3.a', 'libsqlite_vec.a']
    if args.force or not cached(OUT / 'sqlite-build.json', sql_inputs, sql_files):
        sources('sqlite', args.sqlite_source, args.offline)
        sources('vec', args.vec_source, args.offline)
        for name, flags, library in [('sqlite3', SQLITE_FLAGS, 'sqlite3'), ('sqlite-vec', VEC_FLAGS, 'sqlite_vec')]:
            print('Compiling', library, flush=True)
            source = OUT / f'{name}.c'
            if library == 'sqlite_vec':
                # Compile the stamp in the same translation unit as the verified
                # source. Runtime policy checks cannot accidentally stamp a different archive.
                source = OUT / 'sqlite-vec-build.c'
                source.write_text('#include "sqlite-vec.c"\n'
                                  'const char *sqlodin_vec_identity(void) { return "' +
                                  vec_identity() + '"; }\n')
            run([cc, *flags, '-I', OUT, '-c', source, '-o', OUT / f'{name}.o'])
            temporary = OUT / f'lib{library}.new.a'
            temporary.unlink(missing_ok=True)
            run([ar, 'rcs', temporary, OUT / f'{name}.o'])
            temporary.replace(OUT / f'lib{library}.a')
        record(OUT / 'sqlite-build.json', sql_inputs, sql_files)
    else:
        print('Verified cached SQLite/FTS5 and sqlite-vec archives', flush=True)
    if not args.sqlite_only:
        tls_inputs = dict(**common, pin=PINS['openssl'], target=target, flags=TLS_FLAGS)
        tls_files = ['libssl.a', 'libcrypto.a', 'openssl', 'OPENSSL-LICENSE.txt']
        if args.force or not cached(OUT / 'openssl-build.json', tls_inputs, tls_files):
            archive = download(PINS['openssl'], args.offline)
            # A fresh extraction prevents partial/configuration-stale object reuse.
            with tempfile.TemporaryDirectory(prefix='openssl-build-', dir=OUT) as scratch:
                with tarfile.open(archive) as bundle:
                    for member in bundle.getmembers():
                        parts = Path(member.name).parts
                        if Path(member.name).is_absolute() or '..' in parts or not (member.isfile() or member.isdir()):
                            raise SystemExit(f'Unsafe source archive member: {member.name}')
                    bundle.extractall(scratch, filter='data')
                source = Path(scratch) / ('openssl-' + PINS['openssl']['version'])
                environment = os.environ.copy()
                environment.update(CC=cc, AR=ar)
                # Ignore injected build flags; supported inputs are explicit above.
                for name in ('CFLAGS', 'CPPFLAGS', 'LDFLAGS', 'LDLIBS', 'CROSS_COMPILE'):
                    environment.pop(name, None)
                logpath = OUT / 'openssl-build.log'
                print(f'Building OpenSSL {PINS["openssl"]["version"]}; log: {logpath}', flush=True)
                try:
                    with logpath.open('w') as log:
                        run(['perl', 'Configure', target, *TLS_FLAGS, '-fPIC'], cwd=source,
                            env=environment, stdout=log, stderr=subprocess.STDOUT)
                        run(['make', f'-j{args.jobs}', 'build_sw'], cwd=source,
                            env=environment, stdout=log, stderr=subprocess.STDOUT)
                except subprocess.CalledProcessError:
                    print(logpath.read_text()[-6000:])
                    raise
                for name, origin in [('libssl.a', 'libssl.a'), ('libcrypto.a', 'libcrypto.a'),
                                     ('openssl', 'apps/openssl'), ('OPENSSL-LICENSE.txt', 'LICENSE.txt')]:
                    shutil.copy2(source / origin, OUT / name)
            record(OUT / 'openssl-build.json', tls_inputs, tls_files)
        else:
            print('Verified cached OpenSSL static archives', flush=True)
    metadata = dict(sqlite=PINS['sqlite']['version'], sqlite_vec=PINS['vec']['version'],
                    openssl=None if args.sqlite_only else PINS['openssl']['version'],
                    platform=common, sources=PINS, sqlite_flags=SQLITE_FLAGS, vec_flags=VEC_FLAGS,
                    openssl_flags=TLS_FLAGS, archives_sha256={name: sha(OUT / name) for name in
                    sql_files + ([] if args.sqlite_only else ['libssl.a', 'libcrypto.a'])})
    (OUT / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Pinned native dependencies ready in', OUT, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sqlite-source', type=Path, help='Existing hash-checked amalgamation directory')
    parser.add_argument('--vec-source', type=Path)
    parser.add_argument('--sqlite-only', action='store_true', help='Embedded engine does not need OpenSSL')
    parser.add_argument('--offline', action='store_true', help='Require cached source archives; never download')
    parser.add_argument('--force', action='store_true', help='Rebuild despite validated cached archives')
    parser.add_argument('--jobs', type=int, default=min(4, os.cpu_count() or 1))
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64: parser.error('jobs must be in 1..64')
    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / '.build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        build(args)


if __name__ == '__main__': main()
