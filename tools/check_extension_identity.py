#!/usr/bin/env python3
"""Link real engines against accepted/mismatched sqlite-vec build identities."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import build_native as native


def run(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = dict(complete=False, checks=[], identity=native.vec_identity())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='sqlodin-extension-') as work:
            root = Path(work)
            shutil.copytree(native.ROOT / 'src', root / 'src')
            (root / 'deps').symlink_to(native.ROOT / 'deps', target_is_directory=True)
            libraries = root / 'build/native'
            libraries.mkdir(parents=True)
            (libraries / 'libsqlite3.a').symlink_to(native.OUT / 'libsqlite3.a')
            probe = root / 'probe'
            probe.mkdir()
            (probe / 'main.odin').write_text('''package main
import sql "../src"
main :: proc() {
    engine, err := sql.engine_open(":memory:", 1, memory = true)
    defer sql.engine_close(&engine)
    when #config(EXPECT_REJECT, false) {
        assert(err == .Sqlite_Open_Failed && engine.db == nil)
    } else {
        assert(err == .None && engine.vec_enabled)
    }
}
''')
            for rejected in (False, True):
                archive = libraries / 'libsqlite_vec.a'
                if rejected:
                    archive.unlink()
                    source = root / 'mismatched-vec.c'
                    source.write_text('#include "sqlite-vec.c"\n'
                                      'const char *sqlodin_vec_identity(void) { return "mismatch"; }\n')
                    run(['cc', *native.VEC_FLAGS, '-I', native.OUT, '-c', source,
                         '-o', root / 'vec.o'])
                    run(['ar', 'rcs', archive, root / 'vec.o'])
                else:
                    shutil.copy2(native.OUT / 'libsqlite_vec.a', archive)
                binary = root / ('rejected' if rejected else 'accepted')
                run(['odin', 'build', probe, '-debug', '-strict-style',
                     f'-out:{binary}', f'-define:EXPECT_REJECT={str(rejected).lower()}'])
                run([binary])
                result['checks'].append(dict(rejected=rejected, passed=True,
                    archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest()))
                print('PASS', 'mismatched_extension_fails_closed' if rejected else 'pinned_extension_opens')
            result['complete'] = True
    finally:
        args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
