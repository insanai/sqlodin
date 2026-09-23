#!/usr/bin/env python3
"""Inspect stopped on-disk native benchmark samples without changing their databases."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import sqlite3


def main():
    parser=argparse.ArgumentParser();parser.add_argument('report',type=Path);args=parser.parse_args()
    report=json.loads(args.report.read_text())
    if not report['complete']: parser.error('Wait for a complete run and stopped voters')
    for group,suffix in [('realworld','mixed'),('sequential_writes','kv')]:
        for row in report[group]:
            folder=Path(row.get('sample_run_directory',report['run_directory']))/f"{row['repeat']}-{row['system']}-{suffix}"
            images=[]
            for path in folder.rglob('*'):
                if not path.is_file() or path.stat().st_size<16: continue
                with path.open('rb') as f:
                    if f.read(16)==b'SQLite format 3\0': images.append(path)
            row['on_disk_sqlite_images']=[str(p.relative_to(folder)) for p in images]
            if row['system'] in ('sqlodin','rqlite','zaxonlite'):
                assert len(images)>=3,(folder,images)
            if row['system']=='sqlodin':
                rows=[]
                for path in sorted(folder.glob('data-*/node.db')):
                    with sqlite3.connect(path.as_uri()+'?mode=ro',uri=True) as db:
                        identity=db.execute('SELECT identity FROM _sqlodin_journal_meta').fetchone()[0]
                        assert identity.startswith('sqlodin-journal-v4;') and ';policy=6;' in identity
                        assert db.execute('PRAGMA integrity_check').fetchall()==[('ok',)]
                        assert db.execute('PRAGMA foreign_key_check').fetchall()==[]
                        rows.append(dict(file=str(path.relative_to(folder)),identity=identity,
                                         journal_records=db.execute('SELECT count(*) FROM _sqlodin_journal').fetchone()[0],
                                         applied_through=db.execute('SELECT applied FROM _sqlodin_state WHERE id=1').fetchone()[0],
                                         recorded_outcomes=db.execute('SELECT count(*) FROM _sqlodin_outcomes').fetchone()[0]))
                assert len(rows)==3
                row['journal_inspection']=rows
    report['storage_inspected_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    report['storage_inspector_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    temporary=args.report.with_suffix('.tmp');temporary.write_text(json.dumps(report,indent=2)+'\n');temporary.replace(args.report)
    print('Verified on-disk SQLite images and current SQLodin journal identities in every sample.')


if __name__=='__main__':main()
