"""Synchronous connections with explicit recovery of uncertain durable writes."""
import base64
import json
import re
import secrets
import threading
import time
from collections.abc import Sequence
from dataclasses import dataclass

from .errors import (ConnectionError, ConstraintError, PendingWriteError, QueryError,
                     SessionError, SerializationError, UnknownOutcome)
from .parameters import Value, encode, prepare
from .vector import Vector
from .results import Row, Rows, WriteResult
from .transport import Endpoint, TLS, Transport


@dataclass(frozen=True)
class PendingWrite:
    session: str
    sequence: int
    sql: str
    parameters: tuple[Value, ...] = ()
    read_version: int = 0
    epoch: int = 0

    def __post_init__(self):
        if not re.fullmatch(r'[0-9a-f]{32}', self.session) or int(self.session, 16) == 0:
            raise ValueError("Session must be 32 lowercase hexadecimal digits, not all zero")
        if type(self.sequence) is not int or not 1 <= self.sequence < 2**63:
            raise ValueError("Sequence must be a positive signed 64-bit integer")
        if not self.sql or '\x00' in self.sql or len(self.sql.encode('utf-8')) > 4096:
            raise ValueError("Invalid pending SQL body")
        if type(self.read_version) is not int or not 0 <= self.read_version < 2**63:
            raise ValueError("Invalid transaction read version")
        if type(self.epoch) is not int or not 0 <= self.epoch < 2**63:
            raise ValueError("Invalid session epoch")
        object.__setattr__(self, 'parameters', tuple(self.parameters))
        if len(self.parameters) > 16:
            raise ValueError("Too many parameters")
        if sum(len(v) for v in self.parameters if isinstance(v, Vector)) > 384:
            raise ValueError("A request supports at most 384 vector components in total")
        for value in self.parameters:
            encode(value)

    def to_json(self) -> str:
        """Save securely before recovery; contains SQL and parameter values."""
        parameters = [{"vector": list(v)} if isinstance(v, Vector) else v for v in self.parameters]
        return json.dumps(dict(session=self.session, sequence=self.sequence, sql=self.sql,
                               parameters=parameters, read_version=self.read_version, epoch=self.epoch), allow_nan=False)

    @classmethod
    def from_json(cls, text: str) -> 'PendingWrite':
        value = json.loads(text)
        value["parameters"] = tuple(Vector(p["vector"]) if isinstance(p, dict) and set(p) == {"vector"}
                                    else p for p in value.get("parameters", ()))
        return cls(**value)


class Connection:
    def __init__(self, endpoints: Sequence[Endpoint], *, cluster: str, tls: TLS,
                 timeout: float = 10, pending: PendingWrite | None = None):
        self.endpoints = tuple(endpoints)
        if not self.endpoints or any(not isinstance(e, Endpoint) for e in self.endpoints):
            raise ValueError("Provide at least one Endpoint(address, server_name)")
        if not cluster or not 0 < timeout <= 60:
            raise ValueError("Cluster is required; timeout must be in (0, 60] seconds")
        self.cluster, self.timeout = cluster, timeout
        self._session = pending.session if pending else secrets.token_hex(16)
        self._sequence = pending.sequence if pending else 1
        self._pending = pending
        self._epoch = pending.epoch if pending else None
        self._transport = Transport(tls)
        self._index = 0
        self._lock = threading.RLock()
        self._closed = False
        self._transaction = False

    @property
    def pending(self) -> PendingWrite | None:
        return self._pending

    def close(self) -> None:
        with self._lock:
            self._transport.close()
            self._closed = True

    def __enter__(self):
        self._ready()
        return self

    def __exit__(self, *exc):
        self.close()

    def _ready(self):
        if self._closed:
            raise ConnectionError("Connection is closed")
        if self._transaction:
            raise PendingWriteError("Use the transaction's execute() while building an atomic batch")

    def execute(self, sql: str, parameters: Sequence[Value] = ()) -> WriteResult:
        """Execute a durable transaction body; ? values are bound, never formatted."""
        text, values = prepare(sql, parameters)
        with self._lock:
            self._ready()
            return self._execute_prepared(text, values)

    def _execute_prepared(self, text, values, read_version=0):
        if self._pending is not None:
            raise PendingWriteError("Resolve the outstanding write before submitting another")
        if self._epoch is None:
            self._epoch = self.session_epoch()
        self._pending = PendingWrite(self._session, self._sequence, text, values, read_version, self._epoch)
        return self._resolve()

    def resolve_pending(self) -> WriteResult:
        """Retry the exact saved identity and content, including after failover."""
        with self._lock:
            self._ready()
            if self._pending is None:
                raise PendingWriteError("There is no pending write")
            return self._resolve()

    def _resolve(self):
        pending = self._pending
        request = dict(op='execute', sql=pending.sql, session=pending.session,
                       sequence=pending.sequence, session_epoch=pending.epoch, read_version=pending.read_version, parameters=[encode(v) for v in pending.parameters])
        try:
            response = self._call(request)
        except ConnectionError as exc:
            raise UnknownOutcome(pending) from exc
        code = response.get('error', '')
        if code in ('Expired', 'Identity_Conflict', 'Session_Limit'):
            raise SessionError(code)
        if code not in ('', 'Constraint', 'Policy', 'Sequence_Gap', 'Invalid_SQL',
                        'Invalid_Request', 'Unsupported', 'Conflict'):
            raise UnknownOutcome(pending)
        self._pending = None
        if code not in ('Invalid_Request', 'Unsupported'):
            self._sequence += 1
        if code == "Conflict":
            raise SerializationError(code)
        if code:
            raise ConstraintError(code) if code == 'Constraint' else QueryError(code)
        return WriteResult(response['changes'], response['applied'], response['node'], response['sequence'])

    def query(self, sql: str, parameters: Sequence[Value] = (), *, consistency: str = 'linearizable') -> Rows:
        """Read after a fresh quorum barrier; local reads explicitly allow stale data."""
        if consistency not in ('linearizable', 'local'):
            raise ValueError("Consistency must be 'linearizable' or 'local'")
        text, values = prepare(sql, parameters)
        with self._lock:
            self._ready()
            response = self._call(dict(op='query', sql=text, consistency=consistency,
                                       parameters=[encode(v) for v in values]))
            self._raise_query(response)
            try:
                columns = tuple(response['columns'])
                if not all(isinstance(c, str) for c in columns):
                    raise ValueError('Invalid column names')
                rows = tuple(Row(columns, tuple(_decode(v) for v in row)) for row in response['rows'])
                if any(len(row.as_tuple()) != len(columns) for row in rows):
                    raise ValueError('Invalid row width')
                return Rows(columns, rows, response['applied'], response['node'])
            except (KeyError, TypeError, ValueError) as exc:
                raise ConnectionError("Malformed query result") from exc

    def status(self) -> dict:
        """Local node information, not a quorum health check."""
        with self._lock:
            self._ready()
            result = self._call(dict(op='status'))
            self._raise_query(result)
            return {k: result[k] for k in ('cluster', 'node', 'protocol', 'policy', 'applied',
                    'snapshot_prefix', 'snapshot_sealed', 'snapshot_error', 'generation_prefix') if k in result}

    def session_epoch(self) -> int:
        """Read the current retry-session epoch through a fresh quorum barrier."""
        with self._lock:
            self._ready()
            response = self._call(dict(op='session_epoch'))
            # Pre-epoch services never retire session rows and have only epoch zero.
            if response.get('error') == 'Unsupported':
                return 0
            self._raise_query(response)
            epoch = response.get('session_epoch')
            if type(epoch) is not int or not 0 <= epoch < 2**63:
                raise ConnectionError('Malformed session epoch')
            return epoch

    def retire_sessions(self, *, expected_epoch: int) -> int:
        """Fence the old epoch and reclaim its session rows.

        Quiesce clients and resolve their pending writes first. Old pending writes
        then fail with Expired; never relabel them into a new epoch. After a lost
        response, retry this same expected_epoch. Open new connections afterwards.
        """
        if type(expected_epoch) is not int or not 0 <= expected_epoch < 2**63-1:
            raise ValueError('Invalid expected session epoch')
        with self._lock:
            self._ready()
            if self._pending is not None or self._transaction:
                raise PendingWriteError('Resolve pending work before retiring sessions')
            response = self._call(dict(op='retire_sessions', session_epoch=expected_epoch))
            self._raise_query(response)
            epoch = response.get('session_epoch')
            if type(epoch) is not int or epoch < expected_epoch+1:
                raise ConnectionError('Malformed retirement response; retry the same expected_epoch')
            return epoch

    def request_snapshot(self) -> int:
        """Request a distributed snapshot; return its proposed checkpoint slot.

        This is admission, not certification or a backup completion guarantee.
        Inspect status()['snapshot_sealed'] for the locally learned certificate.
        A displaced checkpoint may require a new request.
        """
        with self._lock:
            self._ready()
            response = self._call(dict(op='snapshot'))
            self._raise_query(response)
            slot = response.get('snapshot_requested')
            if type(slot) is not int or slot <= 0:
                raise ConnectionError('Malformed snapshot admission result')
            return slot

    @staticmethod
    def _raise_query(response):
        if response['status'] != 'ok':
            if response.get('error') == 'Conflict': raise SerializationError('Conflict')
            if response.get('error') == 'Constraint': raise ConstraintError('Constraint')
            raise QueryError(response.get('error', 'Unknown'))

    def _call(self, request):
        deadline = time.monotonic() + self.timeout
        request = dict(request, protocol=1, cluster=self.cluster)
        last_error = None
        while time.monotonic() < deadline:
            endpoint = self.endpoints[self._index]
            # Divide the remaining budget so an unavailable seed cannot consume
            # the entire failover deadline. Every retry retains the write identity.
            attempt = min(deadline, time.monotonic() + max(0.1, (deadline - time.monotonic()) / len(self.endpoints)))
            request['timeout_ms'] = max(1, min(60000, int((attempt - time.monotonic()) * 900)))
            try:
                response = self._transport.exchange(endpoint, request, attempt)
                self._validate(response, request)
                if response.get('error') not in ('Busy', 'Unknown_Outcome', 'Read_Timeout'):
                    return response
                last_error = response['error']
            except (ConnectionError, TimeoutError) as exc:
                last_error = str(exc)
            self._transport.close()
            self._index = (self._index + 1) % len(self.endpoints)
            time.sleep(min(0.01, max(0, deadline - time.monotonic())))
        raise ConnectionError(f"Operation deadline exceeded: {last_error}")

    def _validate(self, response, request):
        if response.get('cluster') != self.cluster or response.get('protocol') != 1:
            raise ConnectionError("Response cluster or protocol mismatch")
        if response.get('status') not in ('ok', 'error'):
            raise ConnectionError("Invalid response status")
        for name in ('node', 'applied', 'changes', 'sequence'):
            if type(response.get(name)) is not int or response[name] < 0:
                raise ConnectionError(f"Invalid response {name}")
        if request['op'] == 'execute' and response['sequence'] != request['sequence']:
            raise ConnectionError("Write response identity mismatch")
        code = response.get('error')
        if not isinstance(code, str) or (response['status'] == 'ok') != (code == ''):
            raise ConnectionError("Invalid error/status combination")

    def _begin_optimistic(self):
        with self._lock:
            self._ready()
            response = self._call(dict(op='begin'))
            self._raise_query(response)
            epoch = response.get('session_epoch', 0)
            if type(epoch) is not int or not 0 <= epoch < 2**63:
                raise ConnectionError('Malformed transaction session epoch')
            if self._epoch is None:
                self._epoch = epoch
            version = response.get('read_version')
            if type(version) is not int or not 1 <= version < 2**63:
                raise ConnectionError('Invalid transaction read version')
            return version

    def _preview(self, body, values, version, query='', query_values=()):
        with self._lock:
            self._ready()
            response = self._call(dict(op='preview', sql=body, read_version=version,
                parameters=[encode(v) for v in values], read_sql=query,
                read_parameters=[encode(v) for v in query_values]))
            self._raise_query(response)
            return response

    def search_index(self, name: str, *, dimensions: int):
        """Open a named ordinary-BLOB/FTS5 index handle without creating schema."""
        from .search import SearchIndex
        return SearchIndex(self, name, dimensions=dimensions)

    def create_search_index(self, name: str, *, dimensions: int):
        """Atomically create an FTS5 index and its typed-vector content table."""
        index = self.search_index(name, dimensions=dimensions)
        index.create()
        return index

    def transaction(self):
        """Buffer a write-only batch; commit the complete body on successful exit."""
        from .transaction import Transaction
        return Transaction(self)


def _decode(value):
    kind = value['kind']
    if kind == 'Null':
        return None
    if kind == 'Integer':
        return value['integer']
    if kind == 'Real':
        return value['real']
    if kind == 'Text':
        return value['text']
    if kind == 'Blob':
        return base64.b64decode(value['text'], validate=True)
    raise ValueError(f"Unknown result kind: {kind}")


def connect(endpoints: Endpoint | Sequence[Endpoint], *, cluster: str, tls: TLS,
            timeout: float = 10, pending: PendingWrite | None = None) -> Connection:
    """Create a reusable connection; the first operation establishes mTLS."""
    if isinstance(endpoints, Endpoint):
        endpoints = [endpoints]
    return Connection(endpoints, cluster=cluster, tls=tls, timeout=timeout, pending=pending)
