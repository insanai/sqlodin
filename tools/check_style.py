#!/usr/bin/env python3
"""Enforce the structural constraints of the Zen of Odin for InsanAI (SOD 0001).

- A source file has at most 1,408 physical lines.
- A line has at most 108 columns (hard limit; tabs count as four); 99 is the soft limit
  reported with --soft.
- A procedure body has at most 70 lines of logic (blank lines, comment lines, and
  ornamental divider lines are not counted).

Exit status is non-zero when a hard limit is broken, so the build fails.
"""
import argparse
import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_FILE_LINES = 1408
HARD_COLUMNS = 108
SOFT_COLUMNS = 99
MAX_PROC_LOGIC_LINES = 70
TAB = 4

PROC_START = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\s*::\s*(?:#force_inline\s+)?proc\b')
ORNAMENT = re.compile(r'^\s*//\s*[-=_*]{3,}\s*$')


def logic_lines(body):
    count = 0
    for line in body:
        stripped = line.strip()
        if not stripped or stripped.startswith('//') or ORNAMENT.match(line):
            continue
        count += 1
    return count


def check_procs(path, lines, problems):
    i = 0
    while i < len(lines):
        if PROC_START.match(lines[i]) and not lines[i].rstrip().endswith(('}', ')', ',')):
            j = i
            while j < len(lines) and not lines[j].rstrip().endswith('{'):
                j += 1
            if j >= len(lines):
                break
            k = j + 1
            while k < len(lines) and lines[k] != '}':
                k += 1
            name = lines[i].split('::')[0].strip()
            count = logic_lines(lines[j + 1:k])
            if count > MAX_PROC_LOGIC_LINES:
                problems.append(f'{path}:{i + 1}: {name} has {count} lines of logic (limit {MAX_PROC_LOGIC_LINES})')
            i = k
        i += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--soft', action='store_true', help='also report lines over the 99-column soft limit')
    parser.add_argument('paths', nargs='*', default=['src', 'tests', 'sim', 'bench', 'cli'])
    args = parser.parse_args()

    problems, soft = [], []
    for base in args.paths:
        for path in sorted((ROOT / base).glob('**/*.odin')):
            rel = path.relative_to(ROOT)
            lines = path.read_text().splitlines()
            if len(lines) > MAX_FILE_LINES:
                problems.append(f'{rel}: {len(lines)} lines (limit {MAX_FILE_LINES})')
            for number, line in enumerate(lines, 1):
                width = len(line.expandtabs(TAB))
                if width > HARD_COLUMNS:
                    problems.append(f'{rel}:{number}: {width} columns (hard limit {HARD_COLUMNS})')
                elif width > SOFT_COLUMNS:
                    soft.append(f'{rel}:{number}: {width} columns (soft limit {SOFT_COLUMNS})')
            check_procs(rel, lines, problems)

    if args.soft and soft:
        print('Soft limit exceeded (wrap when convenient):\n  ' + '\n  '.join(soft))
    if problems:
        print('-- STYLE CONSTRAINT VIOLATED ' + '-' * 51)
        print('\n'.join('  ' + p for p in problems))
        print('\nHint: split the file, wrap the line, or extract a helper procedure; see SOD 0001.')
        return 1
    print(f'PASS style: files <= {MAX_FILE_LINES} lines, lines <= {HARD_COLUMNS} columns, '
          f'procedures <= {MAX_PROC_LOGIC_LINES} logic lines')
    return 0


if __name__ == '__main__':
    sys.exit(main())
