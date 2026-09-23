#!/usr/bin/env python3
"""Check compile-time capacity contracts and runtime durability gates in separate Odin processes.

Every compile-fail fixture must be rejected with a diagnostic that carries a hint; every
durability fixture must abort in both debug and optimized builds with the named diagnostic.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ODIN = os.environ.get('ODIN', 'odin')
PREFIX = 'package main\nimport sqlodin "review:src"\n'
INIT = '''
    m: sqlodin.Membership(1)
    ids := [1]sqlodin.Node_Id{1}
    _ = sqlodin.membership_init(&m, ids[:])
    noop := sqlodin.mutation_make_skip(0, 0)
'''

COMPILE_FAIL = {
    # name: (declarations, body, expected diagnostic fragments)
    'zero_window': (
        '',
        ' n: sqlodin.MultiMaster_Node(sqlodin.Mutation, 1, 0, 1, .Host_Managed)\n _ = sqlodin.node_init(&n, 1, m, noop)\n',
        ('#assert', 'Hint:'),
    ),
    'zero_chunk': (
        '',
        ' n: sqlodin.MultiMaster_Node(sqlodin.Mutation, 1, 4, 0, .Host_Managed)\n _ = sqlodin.node_init(&n, 1, m, noop)\n',
        ('#assert', 'Hint:'),
    ),
    'window_not_power_of_two': (
        '',
        ' n: sqlodin.MultiMaster_Node(sqlodin.Mutation, 1, 3, 1, .Host_Managed)\n _ = sqlodin.node_init(&n, 1, m, noop)\n',
        ('#assert', 'Hint:'),
    ),
    'chunk_exceeds_window': (
        '',
        ' n: sqlodin.MultiMaster_Node(sqlodin.Mutation, 1, 4, 5, .Host_Managed)\n _ = sqlodin.node_init(&n, 1, m, noop)\n',
        ('#assert', 'Hint:'),
    ),
    'zero_members': (
        '',
        ' z: sqlodin.Membership(0)\n _ = sqlodin.membership_init(&z, ids[:])\n',
        ('#assert', 'Hint:'),
    ),
    'too_many_members': (
        '',
        ' big: sqlodin.Membership(65536)\n _ = sqlodin.membership_init(&big, ids[:])\n',
        ('#assert', 'Hint:'),
    ),
}

DURABILITY = (
    (
        'messages_before_confirm',
        '_ = sqlodin.effects_messages_slice(&e)',
        'messages_slice before confirm_writes_durable',
    ),
    ('reset_before_confirm', 'sqlodin.effects_reset(&e)', 'reset discarded unconfirmed writes'),
    (
        'correct_order',
        'sqlodin.effects_confirm_writes_durable(&e)\n    _ = sqlodin.effects_messages_slice(&e)\n    sqlodin.effects_reset(&e)',
        None,
    ),
    ('zero_value_is_ready', 'sqlodin.effects_reset(&e)\n    _ = sqlodin.effects_messages_slice(&e)', None),
)


def run_check(source):
    return subprocess.run(
        [ODIN, 'check', str(source), '-file', f'-collection:review={ROOT}'],
        capture_output=True,
        text=True,
    )


with tempfile.TemporaryDirectory(prefix='sqlodin-contracts-') as directory:
    directory = Path(directory)
    source, binary = directory / 'main.odin', directory / 'check'

    for name, (declarations, body, expected) in COMPILE_FAIL.items():
        source.write_text(PREFIX + declarations + 'main :: proc() {' + INIT + body + '}\n')
        result = run_check(source)
        if result.returncode == 0 or any(fragment not in result.stderr for fragment in expected):
            raise SystemExit(f'{name}: expected the compiler to reject this program\n{result.stdout}{result.stderr}')
        print(f'PASS compile-fail {name}')

    for mode in ('-debug', '-o:speed'):
        for name, operation, expected in DURABILITY:
            pending = (
                ''
                if name == 'zero_value_is_ready'
                else '    sqlodin.effects_add_write(&e, sqlodin.Write_Promise{ballot = sqlodin.ballot_make(1, 0, 1)})\n'
            )
            source.write_text(
                PREFIX
                + 'main :: proc() {\n    e: sqlodin.Effects(sqlodin.Mutation, 1, 4, 1, .Enforced)\n'
                + pending
                + '    '
                + operation
                + '\n}\n'
            )
            subprocess.run(
                [
                    ODIN,
                    'build',
                    str(source),
                    '-file',
                    f'-collection:review={ROOT}',
                    f'-out:{binary}',
                    mode,
                ],
                check=True,
            )
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            if expected:
                if result.returncode == 0 or expected not in result.stderr or 'Hint:' not in result.stderr:
                    raise SystemExit(f'{name} {mode}: expected durability rejection\n{result.stderr}')
            elif result.returncode:
                raise SystemExit(f'{name} {mode}: correct ordering failed\n{result.stderr}')
            print(f'PASS durability {name} {mode}')
