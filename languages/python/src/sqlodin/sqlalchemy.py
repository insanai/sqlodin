"""SQLAlchemy 2.0 dialect with optimistic serializable ORM transactions."""
from sqlalchemy import create_engine as sa_create_engine
from sqlalchemy.dialects import registry
from sqlalchemy.dialects.sqlite.base import SQLiteDialect
from sqlalchemy.types import UserDefinedType

from . import dbapi
from .vector import Vector


class SQLodinDialect(SQLiteDialect):
    name = 'sqlodin'
    driver = 'native'
    supports_statement_cache = True
    insert_returning = update_returning = delete_returning = False
    use_insertmanyvalues = False
    postfetch_lastrowid = True
    # Preview returns sqlite3_changes for the outer statement, excluding triggers.
    supports_sane_rowcount = True
    supports_sane_multi_rowcount = True
    supports_default_values = True

    def __init__(self, **kwargs):
        # SQLite's constructor assumes a local sqlite3 module. This remote driver
        # obtains the actual server version after connecting instead.
        module = kwargs.pop('dbapi', None)
        super().__init__(dbapi=None, **kwargs)
        self.dbapi = module

    @classmethod
    def import_dbapi(cls): return dbapi

    def create_connect_args(self, url):
        if url.host or url.database or url.username or url.password or url.query:
            raise ValueError('Use sqlodin:// with explicit connect_args for endpoints, cluster and TLS')
        return [], {}

    def _get_server_version_info(self, connection):
        value = connection.exec_driver_sql('SELECT sqlite_version()').scalar()
        return tuple(map(int, value.split('.')))

    def _get_default_schema_name(self, connection): return 'main'
    def get_default_isolation_level(self, connection): return 'SERIALIZABLE'
    def get_isolation_level(self, connection): return 'AUTOCOMMIT' if connection.autocommit else 'SERIALIZABLE'
    def get_isolation_level_values(self, connection): return ['SERIALIZABLE', 'AUTOCOMMIT']
    def detect_autocommit_setting(self, connection): return connection.autocommit

    def set_isolation_level(self, connection, level):
        if level not in ('SERIALIZABLE', 'AUTOCOMMIT'):
            raise dbapi.NotSupportedError('Supported isolation levels: SERIALIZABLE and AUTOCOMMIT')
        connection.autocommit = level == 'AUTOCOMMIT'

    def do_savepoint(self, connection, name):
        connection.connection.dbapi_connection.savepoint(name)

    def do_rollback_to_savepoint(self, connection, name):
        connection.connection.dbapi_connection.rollback_savepoint(name)

    def do_release_savepoint(self, connection, name):
        connection.connection.dbapi_connection.release_savepoint(name)

    def do_begin_twophase(self, connection, xid):
        raise dbapi.NotSupportedError('Two-phase transactions are unsupported')

    def do_execute(self, cursor, statement, parameters, context=None):
        cursor.execute(statement, parameters)

    def do_executemany(self, cursor, statement, parameters, context=None):
        cursor.executemany(statement, parameters)

    def has_table(self, connection, table_name, schema=None, **kw):
        if schema not in (None, 'main'): return False
        return bool(connection.exec_driver_sql(
            "SELECT 1 FROM sqlite_schema WHERE name=? AND type IN ('table','view')", (table_name,)).first())

    def get_table_names(self, connection, schema=None, **kw):
        if schema not in (None, 'main'): return []
        return [r[0] for r in connection.exec_driver_sql(
            "SELECT name FROM sqlite_schema WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_sqlodin_%' ORDER BY name")]

    def get_columns(self, *args, **kw):
        raise NotImplementedError('Schema reflection is not supported; declare SQLAlchemy tables explicitly')

    def get_foreign_keys(self, *args, **kw):
        raise NotImplementedError('Foreign-key reflection is not supported')

    def get_indexes(self, *args, **kw):
        raise NotImplementedError('Index reflection is not supported')

    def get_pk_constraint(self, *args, **kw):
        raise NotImplementedError('Primary-key reflection is not supported')


class VectorType(UserDefinedType):
    """SQLite BLOB storage with typed network float32 bindings and Vector results."""
    cache_ok = True

    def __init__(self, dimensions: int):
        if type(dimensions) is not int or not 1 <= dimensions <= 384:
            raise ValueError('Vector dimensions must be in 1..384')
        self.dimensions = dimensions

    def get_col_spec(self, **kw): return 'BLOB'

    def bind_processor(self, dialect):
        def process(value):
            if value is None: return None
            value = value if isinstance(value, Vector) else Vector(value)
            if len(value) != self.dimensions: raise ValueError('Vector dimension mismatch')
            return value
        return process

    def result_processor(self, dialect, coltype):
        def process(value):
            if value is None: return None
            vector = Vector.from_bytes(value)
            if len(vector) != self.dimensions: raise ValueError('Stored vector dimension mismatch')
            return vector
        return process


registry.register('sqlodin', 'sqlodin.sqlalchemy', 'SQLodinDialect')


def create_engine(endpoints, *, cluster, tls, autocommit=False, timeout=10, **options):
    """Create an ORM/Core engine with SERIALIZABLE transactions by default.

    Writes are provisional until commit. Concurrent application writes cause a
    serialization error; roll back and retry the entire transaction. Explicit
    autocommit=True opts into independently committed statements.
    """
    if type(autocommit) is not bool: raise ValueError('autocommit must be bool')
    if 'connect_args' in options or 'isolation_level' in options:
        raise ValueError('Connection arguments and isolation are set by this helper')
    return sa_create_engine('sqlodin://', isolation_level='AUTOCOMMIT' if autocommit else 'SERIALIZABLE',
                            connect_args=dict(endpoints=endpoints, cluster=cluster, tls=tls,
                                              timeout=timeout, autocommit=autocommit), **options)
