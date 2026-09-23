"""Atomic buffered transaction bodies, without misleading live SQL transactions."""
from .errors import PendingWriteError
from .parameters import prepare


class Transaction:
    def __init__(self, connection):
        self.connection = connection
        self.result = None
        self._statements = []
        self._parameters = []
        self._active = False
        self._used = False

    def __enter__(self):
        db = self.connection
        db._lock.acquire()
        try:
            db._ready()
            if self._used or db.pending is not None:
                raise PendingWriteError("Transaction already used or a write needs resolution")
            self._active = self._used = db._transaction = True
            return self
        except BaseException:
            db._lock.release()
            raise

    def execute(self, sql, parameters=()):
        if not self._active:
            raise PendingWriteError("Use transaction.execute() inside its with block")
        if len(self._statements) >= 8:
            raise ValueError("A transaction supports at most eight statements")
        text, values = prepare(sql, parameters, offset=len(self._parameters))
        # A newline terminates any trailing -- comment before our separator.
        body = '\n;\n'.join([*self._statements, text + '\n'])
        if len(body.encode('utf-8')) > 4096:
            raise ValueError("A transaction is limited to 4096 UTF-8 bytes")
        self._statements.append(text + '\n')
        self._parameters.extend(values)
        return self

    def __exit__(self, exc_type, exc, tb):
        db = self.connection
        try:
            self._active = db._transaction = False
            if exc_type is None and self._statements:
                self.result = db._execute_prepared('\n;\n'.join(self._statements), tuple(self._parameters))
        finally:
            db._lock.release()
