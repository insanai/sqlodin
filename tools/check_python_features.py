#!/usr/bin/env python3
"""Disk-backed native service checks for vector/FTS/hybrid search and SQLAlchemy."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

from check_network_service import ROOT, Cluster, checks
import sqlodin


def features(c, record):
    with c.connect(timeout=20) as db:
        versions = db.query('SELECT sqlite_version() AS sqlite, vec_version() AS vector').one()
        assert versions['sqlite'] == '3.51.3' and versions['vector'] == 'v0.1.9', versions
        record('pinned_sqlite_fts_and_vector_versions')
        index = db.create_search_index('documents', dimensions=3)
        index.put(1, title='Paxos', body='durable consensus protocol', vector=[1, 0, 0])
        index.put(2, title='SQLite', body='durable database transactions', vector=[0.8, 0.2, 0])
        index.put(3, title='Gardens', body='green leaves and flowers', vector=[0, 1, 0])
        assert [r['id'] for r in index.full_text('consensus')] == [1]
        assert [r['id'] for r in index.nearest([1, 0, 0])] == [1, 2, 3]
        assert index.nearest([1, 0, 0], metric='cosine')[0]['id'] == 1
        hybrid = index.hybrid('durable', [1, 0, 0], limit=3, candidates=3)
        assert [r['id'] for r in hybrid] == [1, 2, 3], list(hybrid)
        record('atomic_search_index_fts_vector_and_single_snapshot_hybrid')
        # Repeat an exact multi-statement/vector request at another master.
        captured = []
        original = db._call
        def capture(request):
            if request['op'] == 'execute': captured.append(db.pending)
            return original(request)
        db._call = capture
        index.put(1, title='Changed', body='revised protocol', vector=[0, 0, 1])
        pending = sqlodin.PendingWrite.from_json(captured[-1].to_json())
        with c.connect((2,), pending=pending) as other:
            other.resolve_pending()
        assert len(index.full_text('consensus')) == 0
        assert index.full_text('revised').one()['id'] == 1
        assert index.nearest([0, 0, 1])[0]['id'] == 1
        index.delete(3)
        assert len(index.full_text('flowers')) == 0
        record('search_update_delete_and_cross_master_vector_retry')
        try:
            with db.transaction() as tx:
                tx.execute('INSERT INTO documents_fts(rowid,title,body) VALUES(?,?,?)', (99, 'bad', 'rollback'))
                tx.execute('INSERT INTO documents(id,title,body,embedding) VALUES(?,?,?,?)',
                           (99, 'bad', 'rollback', sqlodin.Vector([1])))
        except sqlodin.ConstraintError:
            pass
        else: raise AssertionError('Expected vector-dimension CHECK rollback')
        assert len(index.full_text('rollback')) == 0
        # The writer still denies other virtual modules and nondeterministic input.
        for sql in ('DELETE FROM documents_fts_data;',
                    "UPDATE documents_fts_content SET c0='tampered';",
                    'CREATE VIRTUAL TABLE forbidden USING vec0(embedding float[3]);',
                    "INSERT INTO documents_fts(rowid,title,body) VALUES(90,'bad',random())"):
            try: db.execute(sql)
            except sqlodin.QueryError: pass
            else: raise AssertionError('Policy boundary unexpectedly widened')
        try:
            db.execute("INSERT INTO documents_fts(rowid,title,body) VALUES(1,'duplicate','bad')")
        except sqlodin.ConstraintError:
            pass
        else: raise AssertionError('Duplicate FTS rowid must be a durable constraint rejection')
        assert index.full_text('revised').one()['id'] == 1
        record('fts_and_content_rollback_and_policy_boundary')
        # Larger vectors bypass the text-parameter limit without unbounded BLOB bindings.
        big = sqlodin.Vector([i / 384 for i in range(384)])
        db.execute('CREATE TABLE embeddings(id INTEGER PRIMARY KEY, v BLOB)')
        db.execute('INSERT INTO embeddings VALUES(?,?)', (1, big))
        actual = db.query('SELECT v FROM embeddings WHERE id=?', (1,)).scalar()
        assert sqlodin.Vector.from_bytes(actual) == big
        assert db.query('SELECT vec_distance_l2(v,?) FROM embeddings', (big,)).scalar() == 0
        record('384_dimension_typed_binding_blob_roundtrip')
    sqlalchemy_checks(c, record)
    for node in (1, 2, 3): c.stop(node)
    for node in (1, 2, 3): c.start(node)
    for node in (1, 2, 3):
        with c.connect((node,), timeout=20) as db:
            index = db.search_index('documents', dimensions=3)
            assert index.full_text('revised').one()['id'] == 1
            assert [r['id'] for r in index.nearest([0, 0, 1])] == [1, 2]
            assert [r['id'] for r in index.hybrid('revised', [0, 0, 1], limit=2, candidates=2)] == [1, 2]
            assert db.query('SELECT COUNT(*) FROM sqlalchemy_items').scalar() == 3
    record('search_and_sqlalchemy_all_voter_crash_recovery')


def sqlalchemy_checks(c, record):
    from sqlalchemy import Column, Integer, MetaData, String, Table, bindparam, func, inspect, select, text
    from sqlalchemy.exc import DBAPIError, IntegrityError
    from sqlodin.sqlalchemy import create_engine, VectorType
    endpoints = [sqlodin.Endpoint(m['address'], m['identity']) for m in c.members]
    tls = sqlodin.TLS(c.root / 'ca.pem', c.root / 'client.pem', c.root / 'client.key')
    engine = create_engine(endpoints, cluster='network-qualification', tls=tls, autocommit=True, timeout=20)
    table = Table('sqlalchemy_items', MetaData(), Column('id', Integer, primary_key=True, autoincrement=False),
                  Column('name', String), Column('embedding', VectorType(3)))
    try:
        table.create(engine)
        with engine.connect() as conn:
            conn.execute(table.insert(), dict(id=1, name='first', embedding=[1, 0, 0]))
            conn.execute(table.insert(), [dict(id=2, name='second', embedding=[0, 1, 0]),
                                          dict(id=3, name='third', embedding=[0, 0, 1])])
            row = conn.execute(select(table).where(table.c.id == 1)).mappings().one()
            assert row['embedding'] == sqlodin.Vector([1, 0, 0])
            distance = func.vec_distance_l2(table.c.embedding, bindparam('v', type_=VectorType(3)))
            ids = conn.execute(select(table.c.id).order_by(distance, table.c.id), {'v': [1, 0, 0]}).scalars().all()
            assert ids == [1, 2, 3]
            assert inspect(conn).has_table('sqlalchemy_items')
            assert 'sqlalchemy_items' in inspect(conn).get_table_names()
            try:
                conn.execute(table.insert(), [dict(id=4, name='rollback', embedding=[1, 0, 0]),
                                              dict(id=1, name='duplicate', embedding=[1, 0, 0])])
            except IntegrityError: conn.rollback()
            else: raise AssertionError('Expected atomic executemany rollback')
            assert conn.execute(select(func.count()).select_from(table)).scalar_one() == 3
            try: conn.execute(table.insert().returning(table.c.id), dict(id=5, name='bad', embedding=[1, 0, 0]))
            except DBAPIError: conn.rollback()
            else: raise AssertionError('RETURNING must not silently discard rows')
            # FTS and vectors may also be queried directly through SQLAlchemy text().
            assert conn.execute(text('SELECT rowid FROM documents_fts WHERE documents_fts MATCH :q'),
                                dict(q='revised')).scalar_one() == 1
        record('sqlalchemy_core_typed_vectors_fts_and_atomic_executemany')
    finally:
        engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'bin/sqlodin')
    parser.add_argument('--openssl', default=str(Path(__file__).resolve().parents[1] / 'build/native/openssl'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = dict(complete=False, platform=platform.platform(), policy=6, format=4,
                  scope='three native processes, durable disk; vector/FTS/hybrid search and SQLAlchemy Core AUTOCOMMIT', checks=[])
    report['binary_sha256'] = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for d in ('src', 'service', 'transport', 'languages/python/src')
                              for p in (ROOT / d).rglob('*') if p.suffix in ('.odin', '.py')}
    def record(name):
        report['checks'].append(dict(name=name, passed=True))
        print('PASS', name, flush=True)
    root = ROOT / 'build/search-work'
    root.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=root) as work:
            if sys.platform == 'linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', work], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(Path(work), args.binary.resolve(), args.openssl)
            try:
                checks(c, record)
                features(c, record)
                report['complete'] = True
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-6000:] for p in c.root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__': main()
