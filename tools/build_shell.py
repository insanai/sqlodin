#!/usr/bin/env python3
"""Build the pinned SQLite shell into SQLodin; no external sqlite executable."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/native'


def pinned_shell_source(pins):
    shell_pin = pins['sqlite_shell']
    if shell_pin['version'] != pins['sqlite']['version'] or shell_pin['url'] != pins['sqlite']['url']:
        raise SystemExit('SQLite engine and shell pins must match')
    expected = shell_pin['files']['shell.c']
    archive = ROOT / 'build/downloads' / pins['sqlite']['url'].rsplit('/', 1)[1]
    if archive.is_file():
        with zipfile.ZipFile(archive) as bundle:
            names = [p for p in bundle.namelist() if p.endswith('/shell.c')]
            if len(names) != 1: raise SystemExit('Missing/ambiguous SQLite shell source')
            source = bundle.read(names[0])
    else:
        # Source-only/offline native builds may retain the extracted pinned
        # source without its download archive. Apply the same checksum below.
        source = (OUT / 'shell.c').read_bytes()
    if hashlib.sha256(source).hexdigest() != expected:
        raise SystemExit('SQLite shell source checksum mismatch')
    return source


def main():
    pins = json.loads((ROOT / 'tools/native_sources.json').read_text())
    expected = pins['sqlite_shell']['files']['shell.c']
    source = pinned_shell_source(pins)
    (OUT / 'shell.c').write_bytes(source)
    cc, ar = shutil.which(os.environ.get('CC', 'cc')), shutil.which(os.environ.get('AR', 'ar'))
    flags = ['-O2', '-fPIC', '-DSQLITE_THREADSAFE=1', '-DSQLITE_OMIT_LOAD_EXTENSION',
             '-DSQLITE_OMIT_DEPRECATED', '-DSQLITE_ENABLE_FTS5', '-DHAVE_USLEEP=1',
             '-Dmain=sqlodin_sqlite_shell', '-DSQLITE_SHELL_INIT_PROC=sqlodin_shell_init']
    subprocess.run([cc, *flags, '-I', str(OUT), '-c', str(OUT / 'shell.c'),
                    '-o', str(OUT / 'shell.o')], check=True)
    helper = ROOT / 'internal/shell/local.c'
    subprocess.run([cc, '-O2', '-fPIC', '-D_XOPEN_SOURCE=700', '-D_DARWIN_C_SOURCE', '-D_DEFAULT_SOURCE', '-I', str(OUT), '-c', str(helper),
                    '-o', str(OUT / 'shell_init.o')], check=True)
    target = OUT / 'libsqlodin_shell.new.a'
    target.unlink(missing_ok=True)
    subprocess.run([ar, 'rcs', str(target), str(OUT / 'shell.o'), str(OUT / 'shell_init.o')], check=True)
    target.replace(OUT / 'libsqlodin_shell.a')
    (OUT / 'shell-build.json').write_text(json.dumps(dict(
        sqlite_version=pins['sqlite']['version'], source_sha256=expected,
        helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(), flags=flags,
        builder_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        compiler=subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
        archive_sha256=hashlib.sha256((OUT / 'libsqlodin_shell.a').read_bytes()).hexdigest(),
    ), indent=2) + '\n')


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / '.build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        main()
