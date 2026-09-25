#!/usr/bin/env python3
"""Reproducible Linux benchmark with raw samples, verified work and per-process resources.

Builds three variants and interleaves them in a seeded randomized order each round.
No network traffic, consensus journal, durable writes or multi-core scaling is measured.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PIN = 'c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c'
VARIANTS = {
    'reference': ['-define:SQLODIN_SHAPE_CACHE=false', '-define:SQLODIN_QUEUE_INITIAL_CAPACITY=256'],
    'shape_cache': ['-define:SQLODIN_QUEUE_INITIAL_CAPACITY=256'],
    'optimized': [],
}


def command(args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def source_manifest():
    paths = set()
    for directory in ('src', 'internal', 'bench', 'deps/paxos-odin/src'):
        paths.update((ROOT / directory).rglob('*.odin'))
    paths.update(ROOT / 'tools' / p for p in ('benchmark.py', 'build_native.py'))
    manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(paths)}
    digest = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    return {'sha256': digest, 'files': manifest}


def run_sample(binary, case, cpu):
    mode, batch, payload = case
    args = ['taskset', '-c', str(cpu), str(binary), '--json', f'--mode={mode}',
            f'--batch={batch}', f'--payload-bytes={payload}',
            f'--iterations={OPTIONS.iterations}', f'--warmup={OPTIONS.warmup}']
    # wait4 reports this child's peak RSS, not the cumulative high-water mark of prior children.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        start = time.perf_counter()
        process = subprocess.Popen(args, cwd=ROOT, stdout=out, stderr=err)
        _, status, usage = os.wait4(process.pid, 0)
        wall = time.perf_counter() - start
        process.returncode = os.waitstatus_to_exitcode(status)
        out.seek(0)
        err.seek(0)
        stdout, stderr = out.read().decode(), err.read().decode()
        if process.returncode:
            raise RuntimeError(f'Benchmark failed: {args}\n{stdout}\n{stderr}')
    result = json.loads(stdout)
    if not result['verified'] or result['iterations'] != OPTIONS.iterations:
        raise RuntimeError('Unverified or incomplete benchmark')
    cpu_seconds = usage.ru_utime + usage.ru_stime
    result.update(process_wall_seconds=wall, user_cpu_seconds=usage.ru_utime,
                  system_cpu_seconds=usage.ru_stime, peak_rss_bytes=usage.ru_maxrss * 1024,
                  process_cpu_percent_of_one_core=cpu_seconds / wall * 100,
                  voluntary_context_switches=usage.ru_nvcsw,
                  involuntary_context_switches=usage.ru_nivcsw,
                  minor_page_faults=usage.ru_minflt, major_page_faults=usage.ru_majflt)
    return result


def summarize(samples):
    groups = {}
    for sample in samples:
        key = (sample['variant'], sample['mode'], sample['batch'], sample['payload_bytes'])
        groups.setdefault(key, []).append(sample)
    rows = []
    metrics = ('ops_per_second', 'batch_p50_us', 'batch_p95_us', 'batch_p99_us',
               'peak_rss_bytes', 'process_cpu_percent_of_one_core',
               'user_cpu_seconds', 'system_cpu_seconds', 'process_wall_seconds')
    for (variant, mode, batch, payload), group in sorted(groups.items()):
        row = dict(variant=variant, mode=mode, batch=batch, payload_bytes=payload,
                   samples=len(group), verified=all(s['verified'] for s in group))
        for metric in metrics:
            values = [s[metric] for s in group]
            med = statistics.median(values)
            row[metric] = dict(median=med, min=min(values), max=max(values),
                               mad=statistics.median(abs(v - med) for v in values))
        rows.append(row)
    return rows


def metadata(cpu):
    return {
        'hostname': platform.node(), 'platform': platform.platform(),
        'architecture': platform.machine(), 'cpu_affinity': [cpu],
        'allowed_cpus': sorted(os.sched_getaffinity(0)),
        'lscpu': json.loads(command(['lscpu', '-J'])),
        'meminfo': read('/proc/meminfo'), 'loadavg_before': read('/proc/loadavg'),
        'cpu_quota': read('/sys/fs/cgroup/cpu.max'),
        'memory_limit': read('/sys/fs/cgroup/memory.max'),
        'scaling_governor': read(f'/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor'),
        'boost': read('/sys/devices/system/cpu/cpufreq/boost'),
        'perf_event_paranoid': read('/proc/sys/kernel/perf_event_paranoid'),
    }


def main():
    if platform.system() != 'Linux':
        raise SystemExit('Run this suite on Linux (wait4 RSS units and CPU affinity are Linux-specific).')
    if OPTIONS.samples < 3 or OPTIONS.iterations < 12 or OPTIONS.warmup < 12:
        raise SystemExit('Use >=3 samples, >=12 warmup and measured operations.')
    if OPTIONS.iterations % 12 or OPTIONS.warmup % 12:
        raise SystemExit('Warmup and iterations must be multiples of 12.')
    if OPTIONS.cpu not in os.sched_getaffinity(0):
        raise SystemExit('Requested CPU is outside the allowed affinity.')
    if command(['git', '-C', 'deps/paxos-odin', 'rev-parse', 'HEAD']) != PIN:
        raise SystemExit('Unexpected Paxos revision')
    if command(['git', '-C', 'deps/paxos-odin', 'status', '--porcelain']):
        raise SystemExit('Paxos dependency must be clean')
    native = json.loads((ROOT / 'build/native/build.json').read_text())
    for name, expected in native['archives_sha256'].items():
        if hashlib.sha256((ROOT / 'build/native' / name).read_bytes()).hexdigest() != expected:
            raise SystemExit('Native archive changed since its build')
    work = ROOT / 'build/benchmark'
    work.mkdir(parents=True, exist_ok=True)
    binaries = {}
    for variant, flags in VARIANTS.items():
        binary = work / variant
        subprocess.run([OPTIONS.odin, 'build', 'bench', '-o:speed', f'-out:{binary}', *flags],
                       cwd=ROOT, check=True)
        # Validate the reference builds as well as the optimized path before measuring.
        subprocess.run([OPTIONS.odin, 'test', 'tests', '-o:speed', f'-out:{work / "tests"}', *flags],
                       cwd=ROOT, check=True)
        binaries[variant] = binary
    report = {
        'format': 1, 'run_at_utc': datetime.now(timezone.utc).isoformat(),
        'source': source_manifest(), 'base_revision': OPTIONS.base_revision,
        'paxos_pin': PIN, 'odin': command([OPTIONS.odin, 'version']),
        'native_build': native, 'host': metadata(OPTIONS.cpu),
        'methodology': {
            'scope': 'single-thread in-process consensus and SQLite :memory: application',
            'excludes': ['network', 'wire encoding', 'consensus journal', 'fsync',
                         'WAN latency', 'client forwarding', 'multi-core scaling'],
            'completion': 'all three replicas applied; sqlite mode applies one local database',
            'workload': 'unique integer primary key, integer value, optional fixed ASCII text',
            'batch': 'proposals admitted before draining; sqlite baseline uses one transaction per batch',
            'latency': 'nearest-rank batch completion microseconds, never divided by batch size',
            'verification': 'exact row count, every key/value/text, and applied prefix on every replica',
            'resources': 'per-child wait4 CPU and peak RSS include startup, warmup and verification',
            'throughput': 'timed operations only; setup, warmup and verification excluded',
            'summary': 'median, min, max and median absolute deviation; no outlier removal',
            'order': 'seeded shuffle of all cases and variants in each repetition',
            'random_seed': OPTIONS.seed, 'samples': OPTIONS.samples,
            'iterations': OPTIONS.iterations, 'warmup': OPTIONS.warmup,
            'paxos': {'voters': 3, 'window': 64, 'max_committed': 16, 'gate': 'Host_Managed'},
            'variant_flags': VARIANTS, 'common_flags': ['-o:speed'],
        },
        'binaries_sha256': {v: hashlib.sha256(p.read_bytes()).hexdigest() for v, p in binaries.items()},
        'samples': [],
    }
    rng = random.Random(OPTIONS.seed)
    cases = [(variant, (mode, batch, payload)) for variant in VARIANTS
             for mode in ('multi', 'single', 'sqlite') for batch in (1, 12) for payload in (0, 256)]
    OPTIONS.output.parent.mkdir(parents=True, exist_ok=True)
    for repetition in range(OPTIONS.samples):
        rng.shuffle(cases)
        for variant, case in cases:
            result = run_sample(binaries[variant], case, OPTIONS.cpu)
            result.update(variant=variant, repetition=repetition + 1)
            report['samples'].append(result)
        # A checkpoint is explicitly incomplete, so the book can never consume it by accident.
        checkpoint = OPTIONS.output.with_suffix('.partial.json')
        checkpoint.write_text(json.dumps(report, indent=2) + '\n')
        print(f'Completed round {repetition + 1}/{OPTIONS.samples}', flush=True)
    report['complete'] = True
    report['finished_at_utc'] = datetime.now(timezone.utc).isoformat()
    report['host']['loadavg_after'] = read('/proc/loadavg')
    report['summary'] = summarize(report['samples'])
    temporary = OPTIONS.output.with_suffix('.tmp')
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(OPTIONS.output)
    OPTIONS.output.with_suffix('.partial.json').unlink(missing_ok=True)
    print(f'Wrote {len(report["samples"])} verified samples to {OPTIONS.output}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'benchmarks/results/linux-latest.json')
    parser.add_argument('--samples', type=int, default=7)
    parser.add_argument('--iterations', type=int, default=24000)
    parser.add_argument('--warmup', type=int, default=2400)
    parser.add_argument('--cpu', type=int, default=2)
    parser.add_argument('--seed', type=int, default=22092026)
    parser.add_argument('--odin', default=os.environ.get('ODIN', 'odin'))
    parser.add_argument('--base-revision', default='uncommitted source snapshot; see source manifest')
    OPTIONS = parser.parse_args()
    main()
