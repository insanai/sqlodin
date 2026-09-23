#!/usr/bin/env python3
"""Linux-only, user-local tool setup for the product benchmark. No sudo or system installs.

Debian 13 supplies extracted build prerequisites; cowsql and its stock demo are built from pinned
sources. Go/rqlite archives are checked against official release SHA-256 values.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/comparison-tools'
PREFIX = WORK / 'prefix'
DOWNLOADS = WORK / 'downloads'
PINS = {
    'raft': ('https://github.com/cowsql/raft.git', 'v0.22.1',
             '9edb176a7924ce2b943cb56552366dc4b5a1a6b7'),
    'cowsql': ('https://github.com/cowsql/cowsql.git', 'v1.15.9',
               '783815b901470e27b7dfbcce3a67c888dad19e78'),
    'go-cowsql': ('https://github.com/cowsql/go-cowsql.git', 'v1.22.0',
                  'b0e46059265dcc795d35a15e86f44ee848e25252'),
}
ARCHIVES = {
    'go1.24.4.linux-amd64.tar.gz': ('https://go.dev/dl/',
        '77e5da33bb72aeaef1ba4418b6fe511bc4d041873cbf82e5aa6318740df98717'),
    'rqlite-v10.2.7-linux-amd64.tar.gz':
        ('https://github.com/rqlite/rqlite/releases/download/v10.2.7/',
         '0b4e8ffbbacc84e421c49915bbd82cc67ac6488e22d4ce58b678fc1219c6a38a'),
}
PACKAGES = ['libuv1-dev', 'libuv1t64', 'libsqlite3-0', 'libsqlite3-dev', 'pkgconf', 'pkgconf-bin', 'libpkgconf3',
            'm4', 'autoconf', 'automake', 'autotools-dev', 'libtool', 'libltdl-dev',
            'autoconf-archive']


def run(args, cwd=WORK, env=None):
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True, timeout=600)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare():
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise SystemExit('This pinned setup is for Linux x86_64 only.')
    for path in (WORK, PREFIX, DOWNLOADS, WORK / 'src'):
        path.mkdir(parents=True, exist_ok=True)
    for name, (base, expected) in ARCHIVES.items():
        path = DOWNLOADS / name
        if not path.exists():
            print('Downloading', name, flush=True)
            with urllib.request.urlopen(base + name, timeout=120) as response:
                path.write_bytes(response.read())
        if digest(path) != expected:
            raise SystemExit(f'Archive checksum mismatch: {path}')
        with tarfile.open(path) as archive:
            archive.extractall(WORK, filter='data')
    for name, (url, tag, pin) in PINS.items():
        source = WORK / 'src' / name
        if not source.exists():
            run(['git', 'clone', '--depth', '1', '--branch', tag, url, source])
        actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != pin:
            raise SystemExit(f'Unexpected {name} revision: {actual}')
    run(['apt-get', 'download', *PACKAGES], cwd=DOWNLOADS)
    for package in DOWNLOADS.glob('*.deb'):
        run(['dpkg-deb', '-x', package, PREFIX])
    # Debian's extracted scripts retain absolute data-directory paths. Relocate only our copies.
    for directory in (PREFIX / 'usr/bin', PREFIX / 'usr/share/autoconf',
                      PREFIX / 'usr/share/automake-1.17'):
        for path in directory.rglob('*'):
            if not path.is_file() or path.is_symlink():
                continue
            try:
                text = path.read_text()
            except UnicodeError:
                continue
            for old in ('/usr/share/autoconf', '/usr/share/automake-1.17',
                        '/usr/share/aclocal', '/usr/share/libtool', '/usr/bin/m4'):
                text = text.replace(old, str(PREFIX) + old)
            path.write_text(text)
    for name, target in [('automake', 'automake-1.17'), ('aclocal', 'aclocal-1.17'),
                         ('pkg-config', 'pkgconf')]:
        link = PREFIX / 'usr/bin' / name
        if not link.exists():
            link.symlink_to(target)


def build():
    libs = PREFIX / 'usr/lib/x86_64-linux-gnu'
    env = dict(os.environ)
    env.update(PATH=f'{WORK}/go/bin:{PREFIX}/usr/bin:' + env['PATH'],
               LD_LIBRARY_PATH=f'{PREFIX}/lib:{libs}',
               PERL5LIB=f'{PREFIX}/usr/share/autoconf:{PREFIX}/usr/share/automake-1.17',
               ACLOCAL_PATH=f'{PREFIX}/usr/share/aclocal',
               ACLOCAL_AUTOMAKE_DIR=f'{PREFIX}/usr/share/aclocal-1.17',
               AUTOMAKE_LIBDIR=f'{PREFIX}/usr/share/automake-1.17',
               AC_MACRODIR=f'{PREFIX}/usr/share/autoconf',
               autom4te_perllibdir=f'{PREFIX}/usr/share/autoconf',
               M4=f'{PREFIX}/usr/bin/m4',
               AUTOM4TE=f'{PREFIX}/usr/bin/autom4te',
               AUTOCONF=f'{PREFIX}/usr/bin/autoconf',
               AUTOHEADER=f'{PREFIX}/usr/bin/autoheader',
               AUTORECONF=f'{PREFIX}/usr/bin/autoreconf',
               SQLITE_CFLAGS=f'-I{PREFIX}/usr/include',
               SQLITE_LIBS=f'-L{libs} -lsqlite3',
               UV_CFLAGS=f'-I{PREFIX}/usr/include',
               UV_LIBS=f'-L{libs} -luv',
               LDFLAGS=f'-Wl,-rpath,{libs}',
               GOMODCACHE=f'{WORK}/gomodcache', GOCACHE=f'{WORK}/gocache',
               CGO_CFLAGS=f'-I{PREFIX}/include -I{PREFIX}/usr/include',
               CGO_LDFLAGS=f'-L{PREFIX}/lib -L{libs} -Wl,-rpath,{PREFIX}/lib -Wl,-rpath,{libs}',
               PKG_CONFIG_PATH=f'{PREFIX}/lib/pkgconfig:{libs}/pkgconfig',
               PKG_CONFIG_SYSROOT_DIR=str(PREFIX))
    source = WORK / 'src/raft'
    run(['autoreconf', '-fi'], cwd=source, env=env)
    run(['./configure', f'--prefix={PREFIX}', '--without-lz4'], cwd=source, env=env)
    run(['make', '-j4'], cwd=source, env=env)
    run(['make', 'install'], cwd=source, env=env)
    env.update(RAFT_CFLAGS=f'-I{PREFIX}/include', RAFT_LIBS=f'-L{PREFIX}/lib -lraft')
    source = WORK / 'src/cowsql'
    run(['autoreconf', '-fi'], cwd=source, env=env)
    run(['./configure', f'--prefix={PREFIX}', '--disable-backtrace'], cwd=source, env=env)
    run(['make', '-j4'], cwd=source, env=env)
    run(['make', 'install'], cwd=source, env=env)
    # Build the stock supported demo without modifying cowsql or adding a SQL service.
    env.pop('PKG_CONFIG_SYSROOT_DIR', None)
    source = WORK / 'src/go-cowsql'
    run(['go', 'mod', 'download'], cwd=source, env=env)
    run(['go', 'build', '-mod=readonly', '-tags', 'libsqlite3',
         '-o', WORK / 'cowsql-demo', './cmd/cowsql-demo'], cwd=source, env=env)
    metadata = {'pins': PINS, 'archives': ARCHIVES,
                'packages': {p.name: digest(p) for p in DOWNLOADS.glob('*.deb')},
                'go': subprocess.check_output([str(WORK / 'go/bin/go'), 'version'], text=True).strip(),
                'compiler': subprocess.check_output(['cc', '--version'], text=True).splitlines()[0],
                'raft_configure': ['--without-lz4'],
                'cowsql_configure': ['--disable-backtrace'],
                'cowsql_demo_sha256': digest(WORK / 'cowsql-demo')}
    (WORK / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')


if __name__ == '__main__':
    prepare()
    build()
