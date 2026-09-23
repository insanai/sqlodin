#!/usr/bin/env python3
"""Append read-only inspection of stopped benchmark databases to a completed Linux report."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[1]


def inspect_sqlodin(folder):
    rows = []
    for path in sorted(folder.glob('node-*.db')):
        with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as connection:
            identity, = connection.execute('SELECT identity FROM _sqlodin_journal_meta').fetchone()
            if not identity.startswith('sqlodin-journal-v1;'):
                raise RuntimeError('Unknown journal format')
            records, = connection.execute('SELECT count(*) FROM _sqlodin_journal').fetchone()
            # Wire v1 has a 57-byte record header; the next byte is Mutation.kind.
            chosen, skips = connection.execute('''SELECT count(DISTINCT slot),
                count(DISTINCT CASE WHEN substr(data,58,1)=x'00' THEN slot END)
                FROM _sqlodin_journal WHERE kind=4''').fetchone()
            applied, = connection.execute('SELECT applied FROM _sqlodin_state WHERE id=1').fetchone()
        rows.append({'file': path.name, 'journal_records': records, 'chosen_slots': chosen,
                     'skip_slots': skips, 'sql_slots': chosen - skips, 'applied_through': applied})
    if len(rows) != 3:
        raise RuntimeError('Expected three stopped SQLodin databases')
    return rows


def sqlite_images(folder):
    images = []
    for path in sorted(folder.rglob('*')):
        if not path.is_file() or path.stat().st_size < 16:
            continue
        with path.open('rb') as stream:
            if stream.read(16) == b'SQLite format 3\x00':
                images.append(str(path.relative_to(folder)))
    return images


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    if not report.get('complete'):
        raise SystemExit('Wait until all database processes have stopped and the run is complete')
    work = Path(report['run_directory'])
    for group, prefix in [('realworld', 'realworld'), ('sequential_writes', 'sequential')]:
        for sample in report[group]:
            folder = Path(sample.get('sample_run_directory', str(work))) / f"{prefix}-{sample['repeat']-1}-{sample['system']}"
            if sample['system'] == 'sqlodin':
                sample['journal_inspection'] = inspect_sqlodin(folder)
            if sample['system'] in ('sqlodin', 'zaxonlite', 'rqlite'):
                sample['on_disk_sqlite_images'] = sqlite_images(folder)
                if len(sample['on_disk_sqlite_images']) < 3:
                    raise RuntimeError(f'Missing on-disk SQLite images: {folder}')
    report['storage_inspected_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report['storage_inspector_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Verified on-disk SQLite images and recorded SQLodin journal/skip counts')


if __name__ == '__main__':
    main()
