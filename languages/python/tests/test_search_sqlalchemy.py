import math
import pytest
import sqlodin
from sqlodin import dbapi
from sqlodin.parameters import encode, prepare
from sqlodin.sqlalchemy import VectorType, create_engine
from sqlodin.transport import Transport


def test_vector_float32_roundtrip_and_limits():
    value = sqlodin.Vector([0.1, -0.0, 1.0])
    assert value[0] != 0.1  # Canonical IEEE float32, not an unrounded Python float64.
    assert sqlodin.Vector.from_bytes(value.to_bytes()) == value
    assert encode(value)['vector'] == list(value)
    for invalid in ([], [math.nan], [math.inf], [1e100], [0.0] * 385):
        with pytest.raises(ValueError): sqlodin.Vector(invalid)
    with pytest.raises(ValueError): prepare('SELECT ?,?', (sqlodin.Vector([0] * 384), sqlodin.Vector([1])))
    with pytest.raises(ValueError): sqlodin.Vector.from_bytes(b'bad')


def test_vector_pending_identity_serialization():
    value = sqlodin.PendingWrite('1' * 32, 1, 'INSERT INTO t VALUES(?1)', (sqlodin.Vector([0.1, 0.2]),))
    assert sqlodin.PendingWrite.from_json(value.to_json()) == value
    assert sqlodin.PendingWrite.from_json('{"session":"' + '2' * 32 +
                                         '","sequence":1,"sql":"DELETE FROM t","parameters":[]}').parameters == ()


def test_index_identifier_validation():
    for name in ('x; DROP TABLE x', 'sqlite_internal', '_sqlodin_state', 'x' * 61, 'a.b'):
        with pytest.raises(ValueError): sqlodin.SearchIndex(None, name, dimensions=3)
    with pytest.raises(ValueError): sqlodin.SearchIndex(None, 'docs', dimensions=0)
    index = sqlodin.SearchIndex(None, 'x' * 60, dimensions=3)
    with pytest.raises(ValueError): index.nearest([1, 2])
    with pytest.raises(ValueError): index.hybrid('x', [1, 2, 3], candidates=1, limit=2)


@pytest.mark.parametrize('statement,expected', [
    ('-- comment\nSELECT 1', 'query'),
    ('WITH a AS (SELECT 1) SELECT * FROM a', 'query'),
    ('WITH a AS (SELECT 1) UPDATE t SET n=1', 'execute'),
    ("SELECT 'UPDATE; RETURNING', \"RETURNING\"", 'query'),
    ('CREATE TABLE t(id INTEGER)', 'execute'),
])
def test_dbapi_sql_classification(statement, expected):
    assert dbapi._kind(statement) == expected


@pytest.mark.parametrize('statement', ['BEGIN', 'PRAGMA journal_mode=OFF',
                                      'INSERT INTO t VALUES(1) RETURNING id', 'SAVEPOINT x'])
def test_unsupported_dbapi_contracts_fail_before_sending(statement):
    with pytest.raises(dbapi.NotSupportedError): dbapi._kind(statement)


def test_dbapi_one_statement():
    with pytest.raises(dbapi.ProgrammingError): dbapi._kind('SELECT 1; DELETE FROM t')


def test_sqlalchemy_vector_processors_and_ddl():
    from sqlalchemy import Column, Integer, MetaData, Table
    from sqlalchemy.schema import CreateTable
    from sqlodin.sqlalchemy import SQLodinDialect
    table = Table('vectors', MetaData(), Column('id', Integer, primary_key=True), Column('v', VectorType(3)))
    dialect = SQLodinDialect()
    assert 'v BLOB' in str(CreateTable(table).compile(dialect=dialect))
    vector = VectorType(3)
    bound = vector.bind_processor(dialect)([1, 2, 3])
    assert vector.result_processor(dialect, None)(bound.to_bytes()) == bound
    with pytest.raises(ValueError): vector.bind_processor(dialect)([1])
    with pytest.raises(ValueError): vector.result_processor(dialect, None)(sqlodin.Vector([1]).to_bytes())


def test_dbapi_uncertain_identity_not_returned_to_pool(monkeypatch):
    monkeypatch.setattr(Transport, '__init__', lambda self, tls: None)
    monkeypatch.setattr(Transport, 'close', lambda self: None)
    def fail(*args): raise sqlodin.ConnectionError('lost reply')
    monkeypatch.setattr(Transport, 'exchange', fail)
    db = dbapi.connect(sqlodin.Endpoint('127.0.0.1:1', 'one'), cluster='x', tls=None,
                       timeout=0.02, autocommit=True)
    monkeypatch.setattr(db.native, 'session_epoch', lambda: 0)
    monkeypatch.setattr(db.native, '_begin_optimistic', lambda: 1)
    monkeypatch.setattr(db.native, '_preview', lambda *a: {'changes': 1, 'lastrowid': 0})
    try:
        with pytest.raises(dbapi.OperationalError) as error:
            db.cursor().execute('DELETE FROM t')
        assert error.value.pending == db.native.pending
        with pytest.raises(dbapi.OperationalError): db.rollback()
        with pytest.raises(dbapi.OperationalError): db.cursor()
    finally: db.close()


def test_transaction_read_version_is_part_of_saved_commit():
    value = sqlodin.PendingWrite('3' * 32, 2, 'DELETE FROM t', read_version=42)
    assert sqlodin.PendingWrite.from_json(value.to_json()) == value
    assert sqlodin.PendingWrite.from_json(value.to_json()).read_version == 42
    for invalid in (-1, 2**63, True):
        with pytest.raises(ValueError): sqlodin.PendingWrite('3' * 32, 2, 'DELETE FROM t', read_version=invalid)


def test_default_engine_uses_transactional_mode():
    engine = create_engine([], cluster='x', tls=None)
    try:
        assert engine.dialect.get_default_isolation_level(None) == 'SERIALIZABLE'
        assert engine.dialect.postfetch_lastrowid
    finally: engine.dispose()


def test_failed_begin_is_dbapi_error_and_can_roll_back():
    class Native:
        pending = None
        def _begin_optimistic(self): raise sqlodin.ConnectionError('no quorum')
    db = dbapi.Connection(Native())
    with pytest.raises(dbapi.OperationalError): db.savepoint('first')
    with pytest.raises(dbapi.OperationalError): db.cursor()
    db.rollback()
    assert db._version is None and not db._failed


def test_autocommit_rejection_discards_read_version():
    class Native:
        pending = None
        def _begin_optimistic(self): return 9
        def _preview(self, *args): raise sqlodin.ConstraintError('Constraint')
    db = dbapi.Connection(Native(), autocommit=True)
    with pytest.raises(dbapi.IntegrityError): db.cursor().execute('DELETE FROM t')
    assert db._version is None and db._statements == []
