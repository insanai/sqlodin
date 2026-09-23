#import "theme.typ": callout

= Vector, Full-Text and Hybrid Search

The native service and Python client combine FTS5 text retrieval with exact vector
distance queries. Content, embeddings and FTS updates share a durable transaction.
Queries default to a fresh quorum barrier and one local snapshot. These guarantees
apply to the bounded API described here; they do not establish arbitrary extension
safety or search throughput at large dataset sizes.

== An atomic search document

```python
with sqlodin.connect(nodes, cluster="search", tls=tls) as db:
    docs = db.create_search_index("documents", dimensions=3)
    docs.put(1, title="Consensus", body="Durable Paxos replication",
             vector=[0.9, 0.1, 0.0])
    words = docs.full_text("Paxos", limit=10)
    nearby = docs.nearest([1, 0, 0], limit=10)
    combined = docs.hybrid("durable", [1, 0, 0],
                           limit=10, candidates=50)
```

Use `db.search_index` to open a handle to an existing index. Creation fails if either
table exists. A put atomically updates the ordinary content/embedding row, removes
the old FTS row, and inserts its replacement. Delete removes both representations.
Direct SQL can bypass this relationship; applications should use the index methods
for its mutations. Existing-schema validation is not automatic.

== Compact, typed vector parameters

`sqlodin.Vector` owns immutable finite float32 values. Python rounds each component
before submitting the request, so retry serialization preserves the actual stored
value. The Odin service uses the existing fixed mutation vector storage and codec;
it does not introduce an unbounded embedding allocation in durable state. A vector
contains 1–384 components; the whole request has a 384-component budget.

The embedding is an ordinary SQLite BLOB. Queries use sqlite-vec's
`vec_distance_l2` or `vec_distance_cosine`; selected BLOBs return bytes, and
`Vector.from_bytes` decodes them. Cosine distance requires nonzero vectors.
These queries scan the embedding column exactly. A small result limit does not
make the scan an approximate nearest-neighbor index or bound its work independently
of the dataset.

macOS and Linux builds verify SQLite 3.51.3 and sqlite-vec 0.1.9 source hashes
before compiling static archives. The CLI also statically links pinned OpenSSL 3.5.8.
A cluster requires matching engine/build fingerprints. SIMD performance depends on
the native library build; writing the host in Odin alone implies no speedup.

#callout(title: "Service bounds remain explicit", kind: "warning")[
Text parameters, including titles, bodies and FTS expressions, are limited to 256 UTF-8
bytes. Transactions permit eight statements, sixteen parameters and 4096 SQL bytes.
Queries have instruction and result budgets. This API currently targets bounded
chunks; it is not unrestricted document ingestion. Durable `vec0` virtual tables
remain unsupported. The legacy embedded examples have a different contract.
]

#pagebreak()
== Full-text ranking and fused retrieval

FTS5 accepts its normal MATCH query syntax, including phrases and boolean terms.
`full_text` ranks by ascending BM25 score and then document ID. `nearest` ranks by
ascending distance and then ID. Hybrid search selects bounded candidates from both
lists and uses reciprocal-rank fusion:

$ "score"(d) = sum_(r in "ranks"(d)) 1 / (k + r) $

Ranks begin at one and the default constant is 60. A document absent from one list
contributes only its other rank. Higher fused scores rank first; equal scores use
ascending document ID. Both candidate lists are computed in a single SQL statement,
so an intervening write cannot mix two snapshots. Limits and candidate counts are
1–100. This implementation does not perform embedding generation or learn relevance
weights; applications supply their own embeddings and retrieval evaluation.

SQL policy 6 retains built-in FTS5 creation and enables SQLite defensive mode to
prevent direct writes to its shadow tables. Duplicate FTS row IDs produce durable
constraint outcomes; they must not wedge the applied prefix. Nondeterministic write
functions and other virtual-table modules remain restricted. Custom tokenizers and
general maintenance commands are outside the tested API.

== SQLAlchemy ORM and Core

```python
from sqlalchemy import Column, Integer, MetaData, Table, select
from sqlodin.sqlalchemy import create_engine, VectorType

engine = create_engine(nodes, cluster="search", tls=tls)
items = Table("items", MetaData(),
    Column("id", Integer, primary_key=True, autoincrement=False),
    Column("embedding", VectorType(3)))
items.create(engine, checkfirst=True)
with engine.begin() as conn:
    conn.execute(items.insert(), {"id": 1, "embedding": [1, 0, 0]})
    row = conn.execute(select(items)).one()
engine.dispose()
```

Install the optional `sqlalchemy` extra. The registered `sqlodin://` dialect uses
bound parameters and the native mTLS client. VectorType validates dimensions and
converts returned BLOBs to Vector objects. FTS is also available through SQLAlchemy
`text`, and vector distance functions through typed `bindparam` expressions.

#callout(title: "Commit is the durable boundary", kind: "note")[
SQLAlchemy now defaults to SERIALIZABLE ORM/Core transactions. Flush evaluates
staged writes privately; commit publishes the complete batch through Paxos.
Rollback, connection close and nested savepoints discard staged work. Concurrent
application writes can cause a serialization failure requiring a whole-transaction
retry. Explicit AUTOCOMMIT remains available for independent statements.
]

The client guide documents uncertain-write recovery, atomic bounded executemany,
installation and the format-4 / policy-6 compatibility boundary. Correctness evidence
for these features appears in the native-service chapter; it is not a search benchmark.
