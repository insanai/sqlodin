#!/usr/bin/env python3
"""Five actual journal/application SIGKILL boundaries for retry-epoch retirement."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

from check_durability import ROOT, kill_stopped, run


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if sys.platform != 'linux' or args.output.exists(): p.error('Linux and a new evidence path required')
    report = dict(complete=False, passed=False, checks=[],
                  run_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  scope='separated durable stores, process SIGKILL, not physical power loss')
    scratch = ROOT/'build/test-tmp'
    scratch.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            report['filesystem'] = json.loads(run('findmnt', '-J', '-T', root))
            assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            binary = root/'probe'
            run(os.environ.get('ODIN', 'odin'), 'build', ROOT/'internal/durability_probe',
                '-debug', '-vet', '-strict-style', '-define:SQLODIN_TEST_SEPARATED=true', f'-out:{binary}')
            report['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
            for boundary in ('before', 'journal', 'sql', 'application', 'ack'):
                path = root/f'{boundary}.db'
                run(binary, path, 'session-init', '-')
                kill_stopped([binary, path, 'session-write', boundary])
                result = run(binary, path, 'session-verify', boundary)
                report['checks'].append(dict(boundary=boundary, passed=True, output=result))
                print('PASS', boundary, flush=True)
            report.update(complete=True, passed=True)
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        report['sources'] = {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                             for d in ('src', 'internal/durability_probe') for f in (ROOT/d).rglob('*.odin')}
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
