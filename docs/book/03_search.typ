#import "figures.typ": steps
= Full-text and vector search
<search>

Search uses ordinary replicated content rows, FTS5 text indexing and sqlite-vec
distance functions. The Python helper updates content, embeddings and FTS rows in
one transaction. A search query uses one database snapshot after a fresh read barrier.

```python
with sqlodin.connect(nodes, cluster="orders", tls=tls) as db:
    docs = db.create_search_index("documents", dimensions=3)
    docs.put(1, title="Consensus", body="Durable Paxos replication",
             vector=[0.9, 0.1, 0.0])
    words = docs.full_text("Paxos", limit=5)
    nearby = docs.nearest([1, 0, 0], metric="l2", limit=5)
    combined = docs.hybrid("durable", [1, 0, 0], limit=5, candidates=30)
```

This example uses `sqlodin`, `nodes` and `tls` from @clients. Create an index once.
On later connections, use `db.search_index("documents", dimensions=3)`.
Opening a handle does not validate an existing schema. Direct SQL can break the
relationship between content and FTS rows, so use the helper for index mutations.

== What the scores mean

FTS5 ranks matching text with BM25; lower scores rank first in this API. Vector
search ranks an exact distance scan. For vectors $x$ and $y$ of dimension $d$,
Euclidean distance is

$ D_2(x,y) = sqrt(sum_(i=1)^d (x_i-y_i)^2). $

Cosine distance is one minus normalized similarity:

$ D_c(x,y) = 1 - frac(sum_(i=1)^d x_i y_i,
  sqrt(sum_(i=1)^d x_i^2) sqrt(sum_(i=1)^d y_i^2)). $

Cosine requires nonzero vectors. These formulas compare geometry, not meaning by
themselves. The embedding model determines what that geometry represents.

An exact scan over $n$ candidate rows evaluates roughly $n d$ components. Returning
five results does not restrict the scan to five rows. SQLodin does not supply an
approximate nearest-neighbor index through this API; writable `vec0` tables are
outside the replicated SQL policy.

#pagebreak()
== Combine ranks, not incompatible scores

BM25 and vector distance have different scales. Hybrid retrieval instead combines
positions in two ranked candidate lists. With rank constant $k$ and ranks starting
at one, document $u$ receives

$ "RRF"(u) = sum_(L: u in L) frac(1, k + "rank"_L(u)). $

A document missing from a list receives no contribution from that list. Higher fused
scores rank first; document IDs break ties. The helper computes both lists within
one query, so they observe the same database snapshot.

#figure(steps((
  ([Text candidates], [FTS5 match → BM25 rank.]),
  ([Vector candidates], [Exact distance → distance rank.]),
  ([Fusion], [Sum reciprocal ranks; sort by score and ID.]),
)), caption: [The two candidate lists feed one fused result. Neither score scale is reused directly.])

For example, with $k=60$, a document ranked first and third scores
$1/61 + 1/63 approx 0.03227$. A document appearing only at rank one scores
$1/61 approx 0.01639$. Candidate truncation can therefore change the fused ranking.

== Representations and bounds

`sqlodin.Vector` stores immutable finite float32 values. Components are rounded before
encoding, so retries preserve the submitted values. Each vector has 1–384 components;
the request has a shared 384-component budget. Embeddings occupy ordinary BLOB columns.
Use `Vector.from_bytes()` to decode a returned embedding.

Titles, bodies and FTS expressions each retain the 256-byte UTF-8 parameter limit.
This is a bounded chunk interface, not unrestricted document ingestion. Search results
also obey the read instruction and result budgets. A too-expensive query fails without
returning a partial success. Custom tokenizers and general FTS maintenance commands
are outside the tested interface.
