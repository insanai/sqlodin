"""Errors distinguish rejected requests from writes whose outcome is unknown."""


class Error(Exception):
    """Base class for SQLodin client errors."""


class ConnectionError(Error):
    """No usable authenticated connection, or an invalid server response."""


class QueryError(Error):
    """The server rejected a SQL statement or its bounded result."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class ConstraintError(QueryError):
    """A constraint rejected and rolled back the entire transaction."""


class SerializationError(QueryError):
    """The read version changed; retry the complete transaction after rollback."""
    sqlstate = "40001"


class SessionError(QueryError):
    """A session identity is stale, conflicted, or cannot be admitted."""


class PendingWriteError(Error):
    """Resolve the outstanding write before submitting another one."""


class UnknownOutcome(Error):
    """The write may have committed. Retry its identity, never a fresh write."""

    def __init__(self, pending):
        self.pending = pending
        super().__init__("Write outcome unknown; call resolve_pending() to retry the same request")
