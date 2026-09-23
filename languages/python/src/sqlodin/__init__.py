"""SQLodin: durable SQL with a small, explicit Python API."""
from .client import Connection, PendingWrite, connect
from .errors import (ConnectionError, ConstraintError, Error, PendingWriteError,
                     QueryError, SerializationError, SessionError, UnknownOutcome)
from .results import Row, Rows, WriteResult
from .transport import Endpoint, TLS
from .vector import Vector
from .search import SearchIndex

__all__ = [
    'Vector', 'SearchIndex', 'connect', 'Connection', 'Endpoint', 'TLS', 'PendingWrite', 'Row', 'Rows', 'WriteResult',
    'Error', 'ConnectionError', 'ConstraintError', 'PendingWriteError', 'QueryError',
    'SessionError', 'SerializationError', 'UnknownOutcome',
]
__version__ = '0.3.0'
