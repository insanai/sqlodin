#!/usr/bin/env python3
"""Disk-backed ORM transaction, conflict and commit-recovery checks."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

from check_network_service import ROOT, Cluster, checks
import sqlodin
from sqlodin import dbapi


def orm_checks(c, record):
    from sqlalchemy import ForeignKey, Integer, String, func, select, text
    from sqlalchemy.exc import IntegrityError, OperationalError
    from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, relationship
    from sqlodin.sqlalchemy import create_engine

    class Base(DeclarativeBase): pass
    class Parent(Base):
        __tablename__ = 'orm_parent'
        id: Mapped[int] = mapped_column(primary_key=True)
        name: Mapped[str] = mapped_column(String, unique=True)
        children: Mapped[list['Child']] = relationship(back_populates='parent', cascade='all, delete-orphan')
    class Child(Base):
        __tablename__ = 'orm_child'
        id: Mapped[int] = mapped_column(primary_key=True)
        parent_id: Mapped[int] = mapped_column(ForeignKey('orm_parent.id'))
        label: Mapped[str] = mapped_column(String)
        parent: Mapped[Parent] = relationship(back_populates='children')

    endpoints = [sqlodin.Endpoint(m['address'], m['identity']) for m in c.members]
    tls = sqlodin.TLS(c.root / 'ca.pem', c.root / 'client.pem', c.root / 'client.key')
    engine = create_engine(endpoints, cluster='network-qualification', tls=tls, timeout=20)
    other = create_engine(endpoints[1:], cluster='network-qualification', tls=tls, timeout=20)
    try:
        Base.metadata.create_all(engine)
        with Session(engine) as session, c.connect(timeout=20) as outside:
            with session.begin():
                parent = Parent(name='committed', children=[Child(label='first')])
                session.add(parent)
                session.flush()
                assert parent.id == 1 and parent.children[0].id == 1
                assert session.scalar(select(func.count()).select_from(Parent)) == 1
                assert outside.query('SELECT COUNT(*) FROM orm_parent').scalar() == 0
                parent.name = 'updated after flush'
            assert parent.name == 'updated after flush'  # expire-on-commit reload
            assert outside.query('SELECT name FROM orm_parent').scalar() == parent.name
        record('orm_begin_flush_generated_keys_relationships_and_visibility')

        with Session(engine) as session:
            session.add(Parent(name='rolled back'))
            session.flush()
            session.rollback()
            assert session.scalar(select(func.count()).select_from(Parent)) == 1
        try:
            with Session(engine) as session, session.begin():
                session.add(Parent(name='exception rollback'))
                session.flush()
                raise ValueError('application error')
        except ValueError: pass
        with Session(engine) as session:
            session.add(Parent(name='close rollback'))
            session.flush()  # close without commit
        with c.connect() as db:
            assert db.query('SELECT COUNT(*) FROM orm_parent').scalar() == 1
        record('orm_rollback_exception_and_close_discard_all_staged_writes')

        with Session(engine) as session, session.begin():
            session.add(Parent(name='outer'))
            session.flush()
            try:
                with session.begin_nested():
                    session.add(Parent(name='nested rollback'))
                    session.flush()
                    raise ValueError('rollback savepoint')
            except ValueError: pass
            try:
                with session.begin_nested():
                    session.add(Parent(name='outer'))
                    session.flush()
            except IntegrityError: pass
            with session.begin_nested():
                session.add(Parent(name='nested committed'))
            assert session.scalar(select(func.count()).select_from(Parent)) == 3
        record('orm_nested_savepoint_rollback_constraint_and_release')

        with Session(engine) as session:
            session.add(Child(parent_id=99999, label='bad foreign key'))
            try: session.flush()
            except IntegrityError: session.rollback()
            else: raise AssertionError('Immediate foreign key constraint must reject flush')
            assert session.scalar(select(func.count()).select_from(Child)) == 1
        record('orm_foreign_key_flush_error_and_session_reuse')

        # Predicate reads followed by disjoint writes must not admit write skew.
        with Session(engine) as first, Session(other) as second:
            assert first.scalar(select(func.count()).select_from(Parent)) == 3
            assert second.scalar(select(func.count()).select_from(Parent)) == 3
            first.get(Parent, 1).name = 'disjoint winner'
            second.get(Parent, 2).name = 'disjoint loser'
            first.flush(); second.flush(); first.commit()
            try: second.commit()
            except OperationalError as exc:
                assert isinstance(exc.orig, dbapi.SerializationError)
                second.rollback()
            else: raise AssertionError('Predicate read/disjoint write must conflict')
            assert second.get(Parent, 2).name == 'outer'
        record('orm_predicate_reads_and_disjoint_writes_prevent_write_skew')

        with Session(engine) as first, Session(other) as second:
            a, b = first.get(Parent, 1), second.get(Parent, 1)
            a.name, b.name = 'first winner', 'stale loser'
            first.flush()
            second.flush()
            first.commit()
            try: second.commit()
            except OperationalError as exc:
                assert isinstance(exc.orig, dbapi.SerializationError) and exc.orig.sqlstate == '40001'
                second.rollback()
            else: raise AssertionError('Stale transaction must not overwrite a committed update')
            assert second.get(Parent, 1).name == 'first winner'
            second.rollback()
            with second.begin():
                second.get(Parent, 1).name = 'retry winner'
        record('orm_cross_master_conflict_and_complete_transaction_retry')

        with Session(engine) as session, c.connect() as db:
            assert session.get(Parent, 1).name == 'retry winner'
            db.execute("UPDATE orm_parent SET name='concurrent' WHERE id=1")
            try: session.scalar(select(func.count()).select_from(Parent))
            except OperationalError as exc:
                assert isinstance(exc.orig, dbapi.SerializationError)
                session.rollback()
            else: raise AssertionError('Changed snapshot must abort subsequent reads')
        record('orm_repeatable_read_detects_intervening_commit')

        with engine.connect() as conn:
            with conn.begin():
                conn.execute(text("UPDATE orm_parent SET name='core atomic' WHERE id=1"))
                assert conn.execute(text('SELECT name FROM orm_parent WHERE id=1')).scalar_one() == 'core atomic'
        with engine.connect() as conn:
            conn.execute(text("UPDATE orm_parent SET name='pool rollback' WHERE id=1"))
        with c.connect() as db:
            assert db.query('SELECT name FROM orm_parent WHERE id=1').scalar() == 'core atomic'
        record('core_transaction_and_pool_reset_rollback')

        victim = None
        try:
            with Session(engine) as session, session.begin():
                session.get(Parent, 1).name = 'staged failover'
                session.flush()
                raw = session.connection().connection.dbapi_connection.native
                address = raw.endpoints[raw._index].address
                victim = next(m['id'] for m in c.members if m['address'] == address)
                c.stop(victim)
                assert session.scalar(select(Parent.name).where(Parent.id == 1)) == 'staged failover'
        finally:
            if victim is not None: c.start(victim)
        record('orm_staged_transaction_survives_contacted_voter_loss')

        # Simulate a committed response lost to the application. This is a lost
        # acknowledgement, not a new transaction. Retry through another master.
        with engine.connect() as conn:
            raw = conn.connection.dbapi_connection
            original = raw.native._call
            captured = []
            def lose_commit(request):
                response = original(request)
                if request['op'] == 'execute':
                    captured.append(raw.native.pending)
                    raise sqlodin.ConnectionError('test: reply lost after application')
                return response
            raw.native._call = lose_commit
            conn.execute(text("UPDATE orm_parent SET name='ack recovered' WHERE id=1"))
            try: conn.commit()
            except OperationalError as exc:
                pending = exc.orig.pending
                assert pending == captured[-1] and pending.read_version > 0
                with c.connect((2,), pending=sqlodin.PendingWrite.from_json(pending.to_json()), timeout=20) as db:
                    db.resolve_pending()
                # This connection still has an unresolved local identity. Never
                # let pool reset turn it into a reported rollback or another write.
                try: raw.rollback()
                except dbapi.OperationalError: pass
                else: raise AssertionError('Unknown commit must block rollback')
                conn.invalidate()
            else: raise AssertionError('Expected explicit uncertain commit')
        record('orm_uncertain_commit_identity_recovery_on_another_master')

        with engine.connect() as conn:
            raw = conn.connection.dbapi_connection
            conn.execute(text("UPDATE orm_parent SET name='quorum recovered' WHERE id=3"))
            c.stop(2); c.stop(3)
            try:
                raw.native.timeout = 1
                try: conn.commit()
                except OperationalError as exc:
                    pending = exc.orig.pending
                    assert pending is not None and pending.read_version > 0
                else: raise AssertionError('A minority must not acknowledge a commit')
            finally:
                c.start(2); c.start(3)
            with c.connect((3,), pending=pending, timeout=20) as db:
                db.resolve_pending()
            conn.invalidate()
        record('orm_minority_commit_unknown_then_quorum_recovery')

        for node in (1, 2, 3): c.stop(node)
        for node in (1, 2, 3): c.start(node)
        for node in (1, 2, 3):
            with c.connect((node,), timeout=20) as db:
                assert db.query('SELECT name FROM orm_parent WHERE id=1').scalar() == 'ack recovered'
                assert db.query('SELECT COUNT(*) FROM orm_parent').scalar() == 3
                assert db.query('SELECT COUNT(*) FROM orm_child').scalar() == 1
        record('orm_commits_survive_all_voter_crash_recovery')
    finally:
        engine.dispose()
        other.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'bin/sqlodin')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = dict(complete=False, format=4, policy=None, platform=platform.platform(), checks=[],
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for directory in ('src', 'service', 'languages/python/src')
                    for p in (ROOT / directory).rglob('*') if p.suffix in ('.odin', '.py')})
    def record(name):
        report['checks'].append(dict(name=name, passed=True)); print('PASS', name, flush=True)
    root = ROOT / 'build/orm-work'; root.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=root) as work:
            if platform.system() == 'Linux':
                report['filesystem'] = json.loads(subprocess.check_output(['findmnt', '-J', '-T', work], text=True))
                assert report['filesystem']['filesystems'][0]['fstype'] not in ('tmpfs', 'ramfs')
            c = Cluster(Path(work), args.binary.resolve(), str(ROOT / 'build/native/openssl'))
            try:
                checks(c, record)
                orm_checks(c, record)
                with c.connect() as db:
                    report['policy'] = db.status().get('policy')
                report['complete'] = True
            finally:
                c.close()
                report['logs'] = {p.name: p.read_text()[-6000:] for p in c.root.glob('*.log')}
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__': main()
