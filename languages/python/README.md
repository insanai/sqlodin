# SQLodin for Python

A small synchronous client for SQLodin's native mTLS SQL service. Written by
Vikrant Rathore with assistance from Ronak Rathore. Python 3.11+, no runtime dependencies.
This is an initial client for the bounded SQLodin service, not a production-qualified release.

From this repository:

```sh
uv add ./languages/python
# Development
cd languages/python
uv sync --extra test
uv run pytest
uv build
```

Connect once and reuse the connection. Each endpoint's server name must match an
exact DNS SAN in its certificate; the address is the reachable host and port.

```python
import sqlodin

nodes = [
    sqlodin.Endpoint("10.175.52.19:7600", "node1.sqlodin.test"),
    sqlodin.Endpoint("10.175.52.20:7600", "node2.sqlodin.test"),
    sqlodin.Endpoint("10.175.52.21:7600", "node3.sqlodin.test"),
]
tls = sqlodin.TLS(ca="ca.pem", cert="app.pem", key="app.key")

with sqlodin.connect(nodes, cluster="orders", tls=tls) as db:
    db.execute("INSERT INTO orders(id, customer) VALUES (?, ?)", (42, "Ada"))
    order = db.query("SELECT id, customer FROM orders WHERE id = ?", (42,)).one()
    print(order["customer"])  # Ada
    print(order[0])           # 42
```

`execute()` returns `WriteResult(changes, applied, node, sequence)`. Successful writes
have durable quorum acceptance and local application. `query()` returns immutable
`Rows` with `columns`, iteration/indexing, `first()`, `one()`, and `scalar()`.
Rows support column names, numeric positions, `dict(row)` and `row.as_tuple()`.
Duplicate column names resolve to the first occurrence by name; positions preserve
all columns. Prefer SQL aliases for unambiguous names. SQL NULL becomes `None`,
integers retain 64-bit precision, and BLOB query values become `bytes`.

Queries default to a fresh quorum barrier. `consistency="local"` explicitly permits
stale results without a quorum. `status()` describes the contacted node's local
state; it does not prove quorum availability. Queries may run while a write is
uncertain, but their results do not resolve that write's identity.

## Atomic write batches

```python
with db.transaction() as tx:
    tx.execute("UPDATE accounts SET balance = balance - ? WHERE id = ?", (20, 1))
    tx.execute("UPDATE accounts SET balance = balance + ? WHERE id = ?", (20, 2))
print(tx.result.changes)
```

The context buffers SQL, then submits one atomic transaction body on successful
exit. A Python exception discards the unsent batch. A SQL constraint rolls back the
whole batch and raises `ConstraintError`. This is a write-only buffered batch:
there is no live transaction or query inside it. Do not include `BEGIN`, `COMMIT`,
or `ROLLBACK`. Statements use plain `?` placeholders. Values remain bound parameters,
including when the batch assigns distinct parameter positions to each statement.
`execute()` does not return rows; use `query()` for reads. SQL `RETURNING` rows are
currently discarded by the engine and are not exposed by this API.

## A timeout is not a rollback

The client retries connection failures across the supplied endpoints under one
operation deadline, preserving the same session, sequence, SQL, and parameters.
If it cannot learn the result, it raises `UnknownOutcome` and retains `db.pending`.
It refuses a new write until that request is resolved:

```python
try:
    db.execute("UPDATE accounts SET balance = balance + ? WHERE id = ?", (20, 1))
except sqlodin.UnknownOutcome as exc:
    # Restore connectivity, then retry the exact identity.
    result = db.resolve_pending()
```

For recovery after closing the connection, persist `exc.pending.to_json()` securely
and open a new connection with `pending=sqlodin.PendingWrite.from_json(saved)`.
Then call `resolve_pending()`. Saved requests contain application SQL and values.
Only one owner may advance a session. `Expired` and `Identity_Conflict` raise
`SessionError`; they do not silently create another session or rerun a payment.
Recovery of a request lost in a Python process crash *before its pending identity
was persisted* is not automatic. Use application-level unique operation IDs and
reconciliation for that case. This client makes no general exactly-once claim.

A connection serializes calls with a lock; use distinct reusable connections for
concurrency. Do not share connections across forked processes. New sessions consume
persistent server capacity, so reuse connections rather than opening one per write.
The native client has no async interface or connection pool. The optional SQLAlchemy
adapter provides optimistic serializable transactions by default, described below.

## Current bounds

The server supports fixed voter membership, at most 8 statements / 4096 SQL bytes /
16 parameters per transaction, and 256 UTF-8 bytes per text parameter. Parameters
support `str`, signed 64-bit `int`, finite `float`, `Vector`, and `None`; arbitrary BLOB parameters are
not yet supported. Queries are read-only, one statement, at most 4096 rows, with a
256 KiB internal result budget and an instruction budget. Large results fail as a
whole (`QueryError`), so use bounded application pagination. Replicated SQL follows
the engine's deterministic function policy. Host addresses are currently numeric
IPv4 endpoints. Live voter changes and production qualification remain open.

## Vector, full-text, and hybrid search

```python
with sqlodin.connect(nodes, cluster="orders", tls=tls) as db:
    docs = db.create_search_index("documents", dimensions=3)  # once
    docs.put(1, title="Consensus", body="Durable Paxos replication",
             vector=[0.9, 0.1, 0.0])
    print(docs.full_text("Paxos").one()["title"])
    print(docs.nearest([1, 0, 0], metric="l2").first())
    print(docs.hybrid("durable", [1, 0, 0], limit=5, candidates=30))
    # On later connections, open a handle without creating tables:
    docs = db.search_index("documents", dimensions=3)
```

`put()` and `delete()` keep ordinary content/vector storage and the FTS5 table
consistent in one durable transaction. Use these methods for all index mutations;
direct SQL can bypass that relationship. Opening a handle does not validate an
existing schema. Creation fails if either table already exists.

`full_text()` uses [FTS5 query syntax and BM25](https://www.sqlite.org/fts5.html);
lower scores rank first. `nearest()` performs an **exact distance scan**, using
sqlite-vec's `vec_distance_l2` or `vec_distance_cosine`; it is not an ANN index.
Use nonzero stored and query vectors for cosine distance. Hybrid retrieval performs
reciprocal-rank fusion, summing `1 / (rank_constant + rank)` over the two candidate
lists. Higher fused scores rank first; ties use document IDs. Both lists are
computed by one query against one fresh fenced snapshot. A candidate missing from
one list contributes only its other rank. Limits and candidate counts are 1–100.
A candidate limit bounds sorting/results, not the work needed to scan embeddings.

Vectors use immutable `sqlodin.Vector` values: 1–384 finite float32 components,
canonicalized before encoding. The whole request has a 384-component budget.
Ordinary SQL accepts these as typed parameters and returns vector BLOBs as `bytes`:

```python
v = sqlodin.Vector([0.9, 0.1, 0.0])
row = db.query("SELECT vec_distance_l2(embedding, ?) FROM documents WHERE id=?",
               (v, 1)).one()
# Decode a selected embedding with sqlodin.Vector.from_bytes(blob).
```

Titles, bodies and FTS expressions retain the 256-byte UTF-8 parameter limit.
This is currently a bounded document/chunk API, not unrestricted document ingestion.
Searches remain subject to the read instruction/result budgets. The durable service
admits built-in FTS5 and protects its shadow tables using SQLite defensive mode;
`vec0` virtual-table creation remains unsupported. General FTS maintenance commands
and custom tokenizers are outside the tested API.

## SQLAlchemy ORM and Core (optional)

Install the optional dependency from this checkout:

```sh
uv pip install './languages/python[sqlalchemy]'
# For repository development:
uv sync --project languages/python --extra sqlalchemy --extra test
```

```python
from sqlalchemy import Column, Integer, MetaData, String, Table, select
from sqlodin.sqlalchemy import VectorType, create_engine

engine = create_engine(nodes, cluster="orders", tls=tls)
items = Table("items", MetaData(),
    Column("id", Integer, primary_key=True, autoincrement=False),
    Column("title", String),
    Column("embedding", VectorType(3)),
)
items.create(engine, checkfirst=True)
with engine.begin() as conn:
    conn.execute(items.insert(), {"id": 1, "title": "Paxos", "embedding": [1, 0, 0]})
    row = conn.execute(select(items).where(items.c.id == 1)).mappings().one()
    print(row["embedding"])  # Vector
engine.dispose()
```

The registered dialect is `sqlodin://`. It uses the same native mTLS client and
bound values. SQLAlchemy `text()` queries support FTS, and `VectorType` works with
`func.vec_distance_l2`/`func.vec_distance_cosine` and typed `bindparam` values.
VectorType validates dimensions on bind/result conversion; add a database CHECK
constraint if other writers must also be constrained.

The default is **SERIALIZABLE transactions**. `Session.begin()` and `engine.begin()`
commit atomically; rollback, exceptions and connection close discard staged work.
ORM flush returns generated integer primary keys and supports reads of staged writes.
Nested savepoints support rollback and release. Provide mapped classes or declared
Table metadata: general reflection, explicit DML RETURNING and two-phase/XA commits
remain unsupported. Explicit `autocommit=True` opts into independent statement commits.

```python
from sqlalchemy.orm import Session

with Session(engine) as session, session.begin():
    parent = Parent(name="Ada")
    session.add(parent)
    session.flush()  # parent.id is available; other sessions cannot see it yet
    session.add(Child(parent_id=parent.id, label="first"))
```

The server privately evaluates staged statements, rolls back the preview, and checks
its read revision again when the full transaction commits through Paxos. Any
intervening application write currently causes a serialization failure, including
writes to unrelated tables. Catch `sqlodin.dbapi.SerializationError` through
SQLAlchemy's `OperationalError.orig`, roll back, and retry the **whole transaction**.
Queries and flushes replay staged writes, so short transactions are preferable.
Transaction limits remain eight writes / 4096 SQL bytes / sixteen parameters / 384
vector components. Successful commit is the durable boundary, not flush.

Unknown commits raise `sqlodin.dbapi.OperationalError`; inspect `exc.orig.pending`.
Save that identity, resolve it with a native connection and the same authenticated
client SAN, and discard the affected pooled connection. Its saved read revision is
part of the retry identity. An unresolved commit blocks rollback/pool reset and new
writes. Do not start a fresh transaction as a substitute for resolving it.

See [the ORM transaction contract](../../docs/orm-transactions.md) for the execution
model, retry example, resource bounds and serializability argument.

## Compatibility and verification

Python 0.3.0 ORM transactions require the **format-4 / SQL-policy-6** service. The
revision is persisted with application outcomes and included in commit digests.
Older stores and peers fail closed; no automatic or rolling migration is provided.
Preserve existing data until a separately validated export/import migration is available.

`tools/check_orm_transactions.py` exercises ORM begin/flush, generated keys,
relationships, rollback/close, nested savepoints, constraint handling, concurrent
conflicts, pool cleanup, uncertain commits, quorum loss and all-voter recovery.
`tools/check_python_features.py` covers vectors, FTS and SQLAlchemy search paths.
Saved local/Linux correctness reports are under `benchmarks/results/`. They are
not search throughput benchmarks or production certification.
