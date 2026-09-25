#!/usr/bin/env python3
"""Bounded Linux SIGKILL checks for certified local generation publication."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from check_durability import ROOT, kill_stopped, run

PHASES = ('Image_Checked', 'Before_Application_Step', 'After_Application_Step',
          'Application_Copied', 'Before_Suffix_Commit', 'Suffix_Copied', 'Base_Written',
          'Recovered', 'Before_Outcome_Trim_Commit', 'After_Outcome_Trim_Commit', 'Before_Identity_Commit', 'Before_Directory_Sync', 'Ready',
          'After_Directory_Sync', 'Before_Publication', 'Before_Catalog_Commit', 'After_Publication')
RETIREMENT_PHASES = ('After_Retirement_Files', 'After_Retirement_Sync', 'Before_Retirement_Commit')

IMAGE_PHASES = ('After_Image_Retirement_Files', 'After_Image_Retirement_Sync',
                'Before_Image_Retirement_Commit')

ROOT_PHASES = ('After_Root_Retirement_Files', 'After_Root_Retirement_Sync',
               'Before_Root_Retirement_Commit')

BACKUP_PHASES = ('Before_Image_Step', 'After_Image_Step', 'Image_Copied', 'Image_Synced',
                 'Image_Verified', 'Before_Manifest', 'Before_Manifest_Sync',
                 'After_Manifest_Sync', 'Manifest_Durable')

RESTORE_PHASES = tuple('Restore_' + name for name in
                       ('Initialized', 'Before_Image_Step', 'After_Image_Step', 'Image_Verified',
                        'Application_Rebased', 'Files_Synced', 'Before_Ready_Commit', 'Ready'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--case', action='append', choices=(*PHASES, *RETIREMENT_PHASES, *IMAGE_PHASES, *ROOT_PHASES, *BACKUP_PHASES, *RESTORE_PHASES))
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Select a new evidence path; previous failures are retained')
    if platform.system() != 'Linux':
        parser.error('These process-crash checks require Linux')
    report = dict(complete=False, passed=False, checks=[], platform=platform.platform(), debug=args.debug,
                  run_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  scope='local generation publication with retained predecessor; SIGKILL, not power loss')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        scratch = ROOT / 'build/test-tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='generation-crash-', dir=scratch) as temp:
            work = Path(temp)
            report['filesystem'] = json.loads(run('findmnt', '--json', '-T', work))
            assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            binary = work / 'probe'
            run(os.environ.get('ODIN', 'odin'), 'build', ROOT / 'internal/durability_probe',
                '-debug' if args.debug else '-o:speed', '-vet', '-strict-style', f'-out:{binary}')
            report['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
            for phase in args.case or (*PHASES, *RETIREMENT_PHASES, *IMAGE_PHASES, *ROOT_PHASES, *BACKUP_PHASES, *RESTORE_PHASES):
                directory = work / phase
                directory.mkdir()
                operation = ('restore' if phase in RESTORE_PHASES else
                             'backup' if phase in BACKUP_PHASES else
                             'retire-root' if phase in ROOT_PHASES else
                             'retire-image' if phase in IMAGE_PHASES else
                             'retire' if phase in RETIREMENT_PHASES else 'gen')
                boundary = phase.removeprefix('Restore_') if phase in RESTORE_PHASES else phase
                kill_stopped([binary, directory, operation+'-write', boundary])
                result = run(binary, directory, operation+'-verify', boundary)
                report['checks'].append(dict(phase=phase, passed=True, verification=result))
                print('PASS', phase, result, flush=True)
            report.update(complete=True, passed=True)
    except BaseException as exc:
        report['error'] = repr(exc)
        if isinstance(exc, subprocess.CalledProcessError):
            report['failure_stdout'], report['failure_stderr'] = exc.stdout, exc.stderr
        raise
    finally:
        sources = sorted([*ROOT.glob('src/**/*.odin'),
                          *ROOT.glob('internal/durability_probe/*.odin')])
        report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sources}
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
