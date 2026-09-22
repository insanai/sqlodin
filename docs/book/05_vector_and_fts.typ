#import "theme.typ": blue, gray, callout

= Dense Vector Search (`sqlite-vec`) & FTS5

== Why Vector and Full-Text Search in Distributed SQLite?

Modern application workloads increasingly require AI capability embedded directly into primary
datastores:
- Semantic search via dense neural embeddings (e.g. OpenAI `text-embedding-3`, BERT).
- Retrieval-Augmented Generation (RAG) knowledge retrieval.
- Exact keyword search with BM25 ranking for hybrid relevance.

Traditionally, developers deploy specialized external vector databases (such as Pinecone or Milvus)
alongside Elasticsearch and Postgres. This introduces distributed two-phase commits, synchronization
lag, operational overhead, and multi-network failure modes.

SQLodin natively integrates both *dense vector similarity search* and *full-text search* within the
replicated, multi-master SQLite engine.

== Native Compilation of `sqlite-vec`

`sqlite-vec` is an ultra-fast, zero-dependency SQLite vector search extension written in pure C by
Alex Garcia. It provides SIMD-accelerated distance metrics (Cosine similarity, L2 Euclidean distance)
over high-dimensional floating-point vectors.

To integrate `sqlite-vec` seamlessly into Odin without external runtime shared-library paths (`.dylib`),
SQLodin compiles the C extension directly into a static archive (`libsqlite_vec.a`):

```bash
clang -O3 -fPIC -c src/sqlite/sqlite-vec.c -o src/sqlite/sqlite-vec.o \
    -DSQLITE_CORE -DSQLITE_VEC_STATIC -DSQLITE_VEC_OMIT_FS
ar rcs src/sqlite/libsqlite_vec.a src/sqlite/sqlite-vec.o
```

In Odin, the extension is imported and linked statically via `src/sqlite/sqlite_vec.odin`:

```odin
package sqlite

import "core:c"

foreign import sqlite_vec "libsqlite_vec.a"

@(default_calling_convention="c")
foreign sqlite_vec {
    sqlite3_vec_init :: proc(
        db: sqlite3,
        pzErrMsg: ^cstring,
        pApi: rawptr,
    ) -> c.int ---
}
```

When an engine opens a connection, it invokes `sqlite3_vec_init(db, nil, nil)`, immediately making
the `vec0` virtual table module available to SQL queries.

== Vector Query Semantics (`vec0`)

Creating a vector index in SQLodin is identical to standard SQLite DDL:

```sql
CREATE VIRTUAL TABLE document_embeddings USING vec0(
    embedding float[384] distance_metric=cosine
);
```

Inserting vector data into the distributed log:

```sql
INSERT INTO document_embeddings (rowid, embedding)
VALUES (101, '[0.021, -0.451, 0.881, ...]');
```

Performing K-Nearest Neighbor (KNN) vector similarity search:

```sql
SELECT rowid, distance
FROM document_embeddings
WHERE embedding MATCH '[0.019, -0.449, 0.879, ...]'
ORDER BY distance
LIMIT 5;
```

== FTS5 Full-Text Search

SQLodin links against SQLite with `ENABLE_FTS5=1`. Full-text virtual tables support tokenization,
prefix matching, and BM25 ranking:

```sql
CREATE VIRTUAL TABLE articles USING fts5(title, content, tokenize='porter unicode61');

SELECT rowid, rank
FROM articles
WHERE articles MATCH 'paxos AND "multi-master"'
ORDER BY rank
LIMIT 10;
```

== Hybrid Search: Reciprocal Rank Fusion

Because both `vec0` and `fts5` run inside the identical SQLite process, applications can execute
*Hybrid Reciprocal Rank Fusion (RRF)* in a single transaction:
```sql
WITH vector_matches AS (
    SELECT rowid, row_number() OVER (ORDER BY distance) AS v_rank
    FROM document_embeddings
    WHERE embedding MATCH ? ORDER BY distance LIMIT 20
),
text_matches AS (
    SELECT rowid, row_number() OVER (ORDER BY rank) AS t_rank
    FROM articles
    WHERE articles MATCH ? ORDER BY rank LIMIT 20
)
SELECT coalesce(v.rowid, t.rowid) AS doc_id,
       (1.0 / (60 + coalesce(v.v_rank, 1000))) +
       (1.0 / (60 + coalesce(t.t_rank, 1000))) AS rrf_score
FROM vector_matches v
FULL OUTER JOIN text_matches t ON v.rowid = t.rowid
ORDER BY rrf_score DESC LIMIT 10;
```
Every replica in the cluster evaluates this query deterministically against its local snapshot.
