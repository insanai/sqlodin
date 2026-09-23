#!/usr/bin/env python3
"""Run an already-built benchmark and report process CPU time and peak RSS.

Build cached/uncached binaries first; run sequentially on an otherwise idle machine.
No attempt is made to isolate a CPU core, control frequency, or measure a remote cluster.
"""
import argparse
import resource
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary')
parser.add_argument('--iterations', type=int, default=10000)
args = parser.parse_args()
if args.iterations < 1:
    parser.error('iterations must be positive')

before = resource.getrusage(resource.RUSAGE_CHILDREN)
start = time.perf_counter()
subprocess.run([args.binary, f'--iterations={args.iterations}'], check=True)
wall = time.perf_counter() - start
after = resource.getrusage(resource.RUSAGE_CHILDREN)
user = after.ru_utime - before.ru_utime
system = after.ru_stime - before.ru_stime
# Darwin reports bytes; Linux/BSD-style platforms commonly report KiB.
rss_mib = after.ru_maxrss / (1024 ** 2 if sys.platform == 'darwin' else 1024)
print(f'Whole benchmark process: wall={wall:.3f}s, user={user:.3f}s, '
      f'system={system:.3f}s, CPU/wall={(user + system) / wall:.1%}, peak RSS={rss_mib:.2f} MiB')
