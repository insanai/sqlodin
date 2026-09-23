"""DB-API transactions using bounded optimistic execution and durable commit."""
from collections.abc import Mapping
from itertools import islice
from .parameters import prepare
from .vector import Vector
from . import client as native
from . import errors

apilevel = '2.0'
threadsafety = 1
paramstyle = 'qmark'


class Warning(Exception): pass
class Error(Exception): pass
class InterfaceError(Error): pass
class DatabaseError(Error): pass
class DataError(DatabaseError): pass
class OperationalError(DatabaseError):
    def __init__(self, message, *, pending=None):
        self.pending = pending
        super().__init__(message)
class SerializationError(OperationalError):
    sqlstate = "40001"

class IntegrityError(DatabaseError): pass
class InternalError(DatabaseError): pass
class ProgrammingError(DatabaseError): pass
class NotSupportedError(DatabaseError): pass


def _translate(exc, pending=None):
    if isinstance(exc, errors.SerializationError):
        return SerializationError(str(exc))
    if isinstance(exc, errors.ConstraintError):
        return IntegrityError(str(exc))
    if isinstance(exc, (errors.UnknownOutcome, errors.PendingWriteError, errors.ConnectionError)):
        return OperationalError(str(exc), pending=getattr(exc, 'pending', pending))
    if isinstance(exc, errors.QueryError):
        return ProgrammingError(str(exc))
    if isinstance(exc, (ValueError, TypeError)):
        return DataError(str(exc))
    return OperationalError(str(exc), pending=pending)


def _kind(sql):
    """Classify one statement using top-level tokens, preserving quoted SQL/data."""
    words, depth, i = [], 0, 0
    while i < len(sql):
        c = sql[i]
        if sql.startswith('--', i):
            end = sql.find('\n', i)
            i = len(sql) if end < 0 else end
        elif sql.startswith('/*', i):
            end = sql.find('*/', i + 2)
            if end < 0: raise ProgrammingError('Unterminated comment')
            i = end + 2
        elif c in "'\"`[":
            closing = ']' if c == '[' else c
            i += 1
            while i < len(sql):
                if sql[i] == closing:
                    i += 1
                    if closing != ']' and i < len(sql) and sql[i] == closing:
                        i += 1
                        continue
                    break
                i += 1
            else: raise ProgrammingError('Unterminated quote')
        elif c == '(':
            depth += 1
            i += 1
        elif c == ')':
            depth -= 1
            i += 1
        elif c == ';' and depth == 0:
            words.append(';')
            i += 1
        elif (c.isalpha() or c == '_') and depth == 0:
            end = i + 1
            while end < len(sql) and (sql[end].isalnum() or sql[end] == '_'): end += 1
            words.append(sql[i:end].upper())
            i = end
        else:
            i += 1
    while words and words[-1] == ';': words.pop()
    if not words or ';' in words or depth != 0:
        raise ProgrammingError('Execute exactly one balanced SQL statement')
    if 'RETURNING' in words:
        raise NotSupportedError('DML RETURNING is not supported by the SQLodin service')
    kind = words[0]
    if kind == 'WITH':
        kind = next((w for w in words[1:] if w in ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'REPLACE')), '')
    if kind in ('SELECT', 'VALUES'):
        return 'query'
    if kind in ('INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'CREATE', 'DROP', 'ALTER'):
        return 'execute'
    raise NotSupportedError('Only queries and DML/DDL statements are supported; transaction control uses Connection methods')


def connect(endpoints, *, cluster, tls, timeout=10, autocommit=False):
    if type(autocommit) is not bool: raise ValueError('autocommit must be bool')
    return Connection(native.connect(endpoints, cluster=cluster, tls=tls, timeout=timeout), autocommit=autocommit)


class Connection:
    def __init__(self, connection, *, autocommit=False):
        self.native = connection
        self.closed = False
        self._autocommit = autocommit
        self._version = None
        self._statements = []
        self._savepoints = []
        self._failed = False

    @property
    def autocommit(self): return self._autocommit
    @autocommit.setter
    def autocommit(self, value):
        if type(value) is not bool: raise NotSupportedError('autocommit must be bool')
        self._ready()
        if value != self._autocommit and self._version is not None:
            raise ProgrammingError('Commit or roll back before changing autocommit')
        self._autocommit = value

    def _ready(self, *, allow_failed=False):
        if self.closed: raise InterfaceError('Connection is closed')
        if self.native.pending is not None:
            raise OperationalError('Unresolved commit; recover its identity before reuse', pending=self.native.pending)
        if self._failed and not allow_failed:
            raise OperationalError('Transaction aborted; roll back before reuse')

    def _begin(self):
        self._ready()
        if self._version is None:
            try:
                self._version = self.native._begin_optimistic()
            except errors.Error as exc:
                self._failed = True
                raise _translate(exc, self.native.pending) from exc

    @staticmethod
    def _body(statements):
        texts, values = [], []
        for sql, params in statements:
            text, bound = prepare(sql, params, offset=len(values))
            texts.append(text + '\n')
            values.extend(bound)
        body = '\n;\n'.join(texts)
        if len(statements) > 8 or len(body.encode('utf-8')) > 4096:
            raise DataError('Transaction exceeds eight statements or 4096 SQL bytes')
        if sum(len(v) for v in values if isinstance(v, Vector)) > 384:
            raise DataError('Transaction exceeds 384 vector components')
        return body, tuple(values)

    def _preview(self, statements, query='', values=()):
        body, parameters = self._body(statements)
        text, bound = prepare(query, values) if query else ('', ())
        self._begin()
        return self.native._preview(body, parameters, self._version, text, bound)

    def _clear(self):
        self._version = None
        self._statements.clear()
        self._savepoints.clear()
        self._failed = False

    def cursor(self):
        self._ready()
        return Cursor(self)

    def commit(self):
        self._ready()
        try:
            if self._statements:
                body, values = self._body(self._statements)
                with self.native._lock:
                    self.native._execute_prepared(body, values, self._version)
        except (errors.Error, ValueError, TypeError) as exc:
            self._failed = True
            raise _translate(exc, self.native.pending) from exc
        self._clear()

    def rollback(self):
        self._ready(allow_failed=True)
        self._clear()  # Previews always roll back on the server; nothing was committed.

    def savepoint(self, name):
        if self.autocommit: raise NotSupportedError('Savepoints require transactional mode')
        self._begin()
        self._savepoints.append((name, len(self._statements)))

    def _savepoint_index(self, name):
        self._ready()
        for index in range(len(self._savepoints) - 1, -1, -1):
            if self._savepoints[index][0] == name: return index
        raise ProgrammingError('Unknown savepoint')

    def rollback_savepoint(self, name):
        index = self._savepoint_index(name)
        del self._statements[self._savepoints[index][1]:]
        del self._savepoints[index + 1:]

    def release_savepoint(self, name):
        index = self._savepoint_index(name)
        del self._savepoints[index:]

    def close(self):
        self._clear()
        self.native.close()
        self.closed = True


class Cursor:
    arraysize = 1

    def __init__(self, connection):
        self.connection = connection
        self.description, self.lastrowid = None, None
        self.rowcount = -1
        self._rows, self._position = (), 0
        self.closed = False

    def _ready(self):
        if self.closed: raise InterfaceError('Cursor is closed')
        self.connection._ready()

    def execute(self, operation, parameters=()):
        self._ready()
        self.description, self.lastrowid, self.rowcount = None, None, -1
        self._rows, self._position = (), 0
        if isinstance(parameters, Mapping): raise ProgrammingError('Use qmark positional parameters')
        kind = _kind(operation)
        try:
            connection = self.connection
            if kind == 'query':
                if connection.autocommit:
                    result = connection.native.query(operation, parameters)
                    columns, rows = result.columns, tuple(row.as_tuple() for row in result)
                else:
                    result = connection._preview(connection._statements, operation, parameters)
                    columns = result['columns']
                    rows = tuple(tuple(native._decode(v) for v in row) for row in result['rows'])
                self.description = tuple((name, None, None, None, None, None, None) for name in columns)
                self._rows = rows
            else:
                candidate = [*connection._statements, (operation, tuple(parameters))]
                result = connection._preview(candidate)
                connection._statements = candidate
                self.rowcount, self.lastrowid = result['changes'], result['lastrowid']
                if connection.autocommit: connection.commit()
        except (errors.Error, ValueError, TypeError) as exc:
            if self.connection.autocommit and self.connection.native.pending is None:
                self.connection._clear()
            elif isinstance(exc, (errors.SerializationError, errors.ConnectionError)):
                self.connection._failed = True
            raise _translate(exc, self.connection.native.pending) from exc
        except Error:
            if self.connection.autocommit and self.connection.native.pending is None:
                self.connection._clear()
            raise
        return self

    def executemany(self, operation, seq_of_parameters):
        self._ready()
        if _kind(operation) != 'execute': raise NotSupportedError('executemany only supports writes')
        parameters = list(islice(iter(seq_of_parameters), 9))
        if len(parameters) > 8: raise NotSupportedError('An executemany is limited to eight statements')
        self.description, self.lastrowid, self.rowcount = None, None, 0
        self._rows, self._position = (), 0
        if not parameters: return self
        connection = self.connection
        before = list(connection._statements)
        auto = connection._autocommit
        connection._autocommit = False
        try:
            count = 0
            for values in parameters:
                self.execute(operation, values)
                count += self.rowcount
            self.rowcount, self.lastrowid = count, None
            if auto: connection.commit()
        except BaseException:
            connection._statements = before
            if auto and connection.native.pending is None: connection._clear()
            raise
        finally:
            connection._autocommit = auto
        return self

    def fetchone(self):
        self._ready()
        if self.description is None: raise ProgrammingError('No query result is available')
        if self._position == len(self._rows): return None
        row = self._rows[self._position]
        self._position += 1
        return row

    def fetchmany(self, size=None):
        self._ready()
        if self.description is None: raise ProgrammingError('No query result is available')
        size = self.arraysize if size is None else size
        if type(size) is not int or size < 0: raise ProgrammingError('Invalid fetch size')
        rows = []
        for _ in range(size):
            row = self.fetchone()
            if row is None: break
            rows.append(row)
        return rows

    def fetchall(self):
        return self.fetchmany(len(self._rows) - self._position)

    def close(self):
        self._rows = ()
        self.closed = True

    def setinputsizes(self, *args): pass
    def setoutputsize(self, *args): pass
    def __iter__(self): return self
    def __next__(self):
        row = self.fetchone()
        if row is None: raise StopIteration
        return row
