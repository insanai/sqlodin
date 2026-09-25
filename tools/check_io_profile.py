#!/usr/bin/env python3
"""Build and validate Linux forwarding-only I/O counters before profiling voters."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    work = ROOT/'build/io-profile'
    work.mkdir(parents=True, exist_ok=True)
    source = ROOT/'internal/io_profile'
    library, probe = work/'profile.so', work/'probe'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-fPIC', '-shared',
                    str(source/'profile.c'), '-ldl', '-o', str(library)], check=True)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', str(source/'probe.c'),
                    '-o', str(probe)], check=True)
    with tempfile.TemporaryDirectory(dir=work) as directory:
        result = subprocess.run([str(probe), str(Path(directory)/'data')], check=True,
            capture_output=True, text=True, env={**os.environ, 'LD_PRELOAD': str(library)}, timeout=10)
        lines = [line for line in result.stderr.splitlines() if line.startswith('SQLODIN_IO_PROFILE ')]
        assert len(lines) == 1, result.stderr
        counters = json.loads(lines[0].split(' ', 1)[1])
        assert counters['sync_calls'] == 3 and counters['write_calls'] == 3, counters
        assert counters['write_bytes'] == 56 and counters['errors'] == 2, counters
        assert counters['sync_ns'] > 0 and counters['write_ns'] > 0, counters
    report = dict(passed=True, counters=counters,
                  verified='exact counters, unchanged bytes and forwarded EBADF from write and sync',
                  sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in (source/'profile.c', source/'probe.c', library, probe, Path(__file__))})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print('PASS I/O forwarding, errno preservation and exact counters', flush=True)


if __name__ == '__main__':
    main()
