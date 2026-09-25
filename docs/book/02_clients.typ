#import "theme.typ": callout
#import "figures.typ": steps
= SQL, Python and transactions
<clients>

A successful write means that its expected request is durably chosen and applied
at the responding voter. A query uses a fresh quorum barrier by default. Neither a
proposal slot nor a local status response is a substitute for these conditions.

== A reusable Python connection

Install from the repository with `uv add ./languages/python`. The synchronous base
client requires Python 3.11 or later and has no runtime dependencies. Reuse a connection;
opening one per write consumes new durable session capacity.

```python
import sqlodin

nodes = [
    sqlodin.Endpoint("10.175.52.19:7600", "node1.sqlodin.test"),
    sqlodin.Endpoint("10.175.52.20:7600", "node2.sqlodin.test"),
    sqlodin.Endpoint("10.175.52.21:7600", "node3.sqlodin.test"),
]
tls = sqlodin.TLS(ca="ca.pem", cert="app.pem", key="app.key")
with sqlodin.connect(nodes, cluster="orders", tls=tls) as db:
    db.execute("UPDATE account SET balance=balance+? WHERE id=?", (20, 1))
    row = db.query("SELECT balance FROM account WHERE id=?", (1,)).one()
    print(row["balance"])
```

`execute()` returns a write result, not a row stream. `query()` returns immutable
rows with column names, numeric positions, `one()`, `first()` and `scalar()`.
Use aliases when a query repeats a column name. BLOB results become `bytes`.
Write `RETURNING` is rejected by the current replicated SQL policy.

A connection serializes its calls. Use separate reusable connections for concurrent
work. Do not share one across forked processes. The client has no native async API.

== Two kinds of transaction

#table(columns: (1fr, 1.8fr),
  table.header([Interface], [What it does]),
  [`db.transaction()`], [Buffers writes, then sends one atomic body. It has no query method.],
  [SQLAlchemy or CLI `BEGIN`], [Reads a fresh revision, previews staged work, then validates at commit.],
)

The next examples assume an open connection named `db`. A buffered write batch is
useful when the client already knows every change:

```python
with db.transaction() as tx:
    tx.execute("UPDATE account SET balance=balance-? WHERE id=?", (20, 1))
    tx.execute("UPDATE account SET balance=balance+? WHERE id=?", (20, 2))
```

A Python exception discards the unsent batch. A classified SQL error rolls back the
whole request. Do not put `BEGIN`, `COMMIT` or `ROLLBACK` inside this body; the service
owns its transaction boundaries. Plain `?` parameters remain bound values.

Install the optional dialect with `uv pip install './languages/python[sqlalchemy]'`.
Declare tables or ORM models explicitly; general schema reflection is not supported.
The following uses SQLAlchemy Core to show the complete transaction boundary:

```python
from sqlalchemy import text
from sqlodin.sqlalchemy import create_engine

engine = create_engine(nodes, cluster="orders", tls=tls)
with engine.begin() as conn:
    balance = conn.execute(
        text("SELECT balance FROM account WHERE id=:id"), {"id": 1}
    ).scalar_one()
    if balance >= 20:
        conn.execute(text("UPDATE account SET balance=balance-20 WHERE id=1"))
        conn.execute(text("UPDATE account SET balance=balance+20 WHERE id=2"))
```

ORM `Session` transactions use the same protocol. Flush can obtain generated integer
keys. Rollback discards staged work; nested savepoints edit that staged body. Releasing
a savepoint does not durably commit anything. Two-phase/XA transactions and general
DML `RETURNING` are outside the interface.

#figure(steps((
  ([Begin], [Obtain a fresh application revision.]),
  ([Preview], [Replay staged writes privately; read; roll back.]),
  ([Commit], [Order the body; compare revision; apply or reject.]),
)), caption: [No SQLite writer lock is held across a client network round trip.])

If another application write intervenes, the transaction conflicts, even when the
rows are disjoint. SQLSTATE `40001` means retry the entire transaction, including
its reads and decisions. SQLodin does not rerun application code automatically.
The reason this conservative rule handles predicate reads is developed in @transactions.

== Handle an unknown outcome

A lost response does not tell you whether a write committed. The Python connection
retains the exact pending request and blocks a different write until it is resolved.

```python
try:
    db.execute("UPDATE account SET balance=balance+? WHERE id=?", (20, 1))
except sqlodin.UnknownOutcome as exc:
    saved = exc.pending.to_json()  # persist securely for process recovery
    # After connectivity is restored, on the same connection:
    result = db.resolve_pending()
```

To recover on another connection, decode the saved identity with
`sqlodin.PendingWrite.from_json(saved)` and pass it as `pending=` to `connect()`.
Then resolve it. Do not submit the SQL under a new identity. Saved pending requests
contain SQL and application values; protect them like application data.

Python cannot recover a request identity lost in a process crash before the application
saved it. Use application-level operation IDs and reconciliation where that window
matters. The CLI instead saves its pending request in a private durable state file
before sending it. Keep that file and use `.pending` and `.retry` after reconnecting.

#callout(title: "Conflict and uncertainty require different actions")[
A definite conflict permits a new transaction after recomputing its reads. An unknown
commit requires resolving the old identity first. Treating uncertainty as an abort
can apply a payment twice.
]

The #link("../../languages/python/README.md")[Python reference] gives result types,
exceptions and search methods. @reference collects the service limits.
