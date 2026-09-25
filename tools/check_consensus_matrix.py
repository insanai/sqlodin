#!/usr/bin/env python3
"""Bounded pinned-core and SQLodin transport-fault regression matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PIN = 'c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seeds', type=int, default=6)
    parser.add_argument('--steps', type=int, default=10000)
    parser.add_argument('--dependency-manifest', type=Path)
    args = parser.parse_args()
    if args.output.exists() or not 1 <= args.seeds <= 30 or not 100 <= args.steps <= 100000:
        parser.error('Use a new output, 1..30 seeds and 100..100000 steps')
    report = dict(complete=False, pin=PIN, cases=[], seeds=args.seeds, steps=args.steps,
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for directory in ('src', 'sim', 'internal/inmemory')
                                 for p in (ROOT / directory).rglob('*.odin')},
                  harness_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        dependency = ROOT / 'deps/paxos-odin'
        if args.dependency_manifest:
            manifest = json.loads(args.dependency_manifest.read_text())
            actual = {str(p.relative_to(dependency)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in dependency.rglob('*.odin')}
            assert manifest['pin'] == PIN and actual == manifest['odin_sources']
            report['dependency_manifest_sha256'] = hashlib.sha256(args.dependency_manifest.read_bytes()).hexdigest()
        else:
            assert subprocess.check_output(['git', '-C', dependency, 'rev-parse', 'HEAD'], text=True).strip() == PIN
            assert not subprocess.check_output(['git', '-C', dependency, 'status', '--porcelain'], text=True).strip()
        work_root = ROOT / 'build/consensus-matrix'
        work_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=work_root) as work:
            work = Path(work)
            upstream = work / 'upstream.json'
            command = ['odin', 'test', str(dependency / 'tests'), '-debug',
                       f'-out:{work / "upstream"}', f'-define:ODIN_TEST_JSON_REPORT={upstream}']
            subprocess.run(command, cwd=ROOT, check=True, timeout=180)
            report['upstream'] = json.loads(upstream.read_text())
            assert report['upstream']['success'] == report['upstream']['total']
            simulator = work / 'sim'
            subprocess.run(['odin', 'build', 'sim', '-debug', f'-out:{simulator}'],
                           cwd=ROOT, check=True, timeout=180)
            report['simulator_sha256'] = hashlib.sha256(simulator.read_bytes()).hexdigest()
            for nodes in (1, 3, 5):
                for seed in range(1, args.seeds + 1):
                    started = time.monotonic()
                    command = [str(simulator), f'--nodes={nodes}', f'--seed={seed}', f'--steps={args.steps}']
                    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
                    case = dict(nodes=nodes, seed=seed, steps=args.steps, seconds=time.monotonic()-started,
                                exit_code=result.returncode, output=result.stdout+result.stderr)
                    report['cases'].append(case)
                    assert result.returncode == 0, case
                print(f'PASS {nodes} nodes, {args.seeds} seeds, {args.steps} steps/seed', flush=True)
        report['complete'] = True
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
