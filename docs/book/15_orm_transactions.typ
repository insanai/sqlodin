#import "theme.typ": callout
#pagebreak()
= SQLAlchemy ORM Transactions

The Python 0.3 adapter defaults to SERIALIZABLE transactions. A Session can flush
objects, obtain generated integer keys, read its own writes and commit related
objects atomically. Rollback, exceptions and connection close discard staged work.
Nested savepoints support rollback and release. Explicit AUTOCOMMIT remains available.

```python
from sqlalchemy.orm import Session
from sqlodin.sqlalchemy import create_engine

engine = create_engine(nodes, cluster="orders", tls=tls)
with Session(engine) as session, session.begin():
    order = Order(customer="Ada")
    session.add(order)
    session.flush()
    session.add(Line(order_id=order.id, product="Book"))
```

== Bounded optimistic execution

A fresh quorum barrier supplies the transaction's application revision. The client
retains staged SQL and parameters. Each flush or read evaluates that body on a
short-lived SQLite connection and rolls it back before processing another request.
The database is not copied, and no SQLite writer lock survives a network round trip.
Previews have a VM instruction budget and never acknowledge durable writes.

Commit submits the complete body and revision through Paxos. Each replica validates
the revision in log order and atomically records application effects, revision,
outcome and retry identity. Successful application requests advance the revision;
read barriers, rejections and duplicate retries do not. An intervening application
write produces SQLSTATE 40001 and requires retrying the whole transaction, including
its reads and application decisions. The client never reruns user code automatically.

This conservative database-wide check prevents lost updates and write skew under
the existing deterministic SQL contract. Read-only transactions can serialize at
their initial barrier. The contract does not prove arbitrary SQL deterministic;
the durable function policy still applies at commit, including to SQL defaults.

#callout(title: "A timeout is not a rollback", kind: "warning")[
An uncertain commit carries its exact pending identity, including the read revision.
Save it and resolve that same request with the native client. Rollback/reset is
refused while a commit remains unresolved. Discard the affected SQLAlchemy connection
after saving the identity; starting a fresh transaction cannot resolve the old one.
]

== Costs and boundaries

Transactions allow eight write statements, 4096 SQL bytes, sixteen write parameters
and 384 vector components. Repeated previews replay staged writes, which adds CPU
work. Database-wide validation can also abort transactions touching unrelated rows.
Keep transactions short; this implementation does not establish high-contention
throughput or unbounded ORM bulk operations. General reflection, explicit DML
RETURNING and two-phase/XA transactions remain unsupported.

Journal format 4 / SQL policy 6 rejects older stores and peers. There is no automatic
or rolling migration. Keep old binaries and data until an export/import migration
has been separately validated. See `docs/orm-transactions.md` for retry and recovery
examples, and the service chapter for JSON-backed correctness evidence.
