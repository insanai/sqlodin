#import "theme.typ": blue, gray, callout

= Consistency Models & Distributed Reads

== Read Spectrum in Replicated Databases

In a distributed database, read operations can offer different consistency guarantees depending on
latency and freshness trade-offs:

#table(
  columns: (100pt, 120pt, 100pt, 120pt),
  align: center + horizon,
  table.header([*Read Level*], [*Coordination*], [*Latency*], [*Freshness*]),
  [Local Snapshot], [Zero (Local WAL)], [< 100 microseconds], [Monotonic local view],
  [Read-Your-Writes], [Local Watermark Check], [< 100 microseconds], [Fresh to client's writes],
  [Linearizable Read], [Quorum Read Exchange], [1 RTT (~15-40ms)], [Strict real-time global],
)

== Local Snapshot Reads

For high-throughput read workloads (such as vector KNN indexing or full-text analytics), clients
can read directly from any node's local SQLite database without participating in consensus:

```odin
rows, err := engine_read_snapshot(&engine, "SELECT * FROM docs WHERE ...")
```

Because SQLite WAL mode provides point-in-time Snapshot Isolation (readers do not block writers and
writers do not block readers), local reads execute in sub-millisecond time (typically 10 to 40
microseconds) without locking or network overhead.

== Read-Your-Writes Watermarks

A classic defect of multi-master systems is the *casual consistency anomaly*:
+ A user posts a comment on Node 1. The write commits in slot 42.
+ The user refreshes the page, routing to Node 2 (geographically closer).
+ If Node 2 is lagging at slot 40, the user does not see their own comment!

SQLodin solves this with *Watermark Reads*:

```odin
engine_read_watermark :: proc(
    e: ^Engine,
    sql: string,
    min_watermark: Slot,
) -> (int, Error) {
    if e.applied_through < min_watermark {
        return 0, .Stale_Watermark
    }
    return engine_read_snapshot(e, sql)
}
```

When a client executes a write on Node 1, SQLodin returns the committed `Slot` number (e.g. `42`).
When the client subsequent issues a read request to any node, it passes `min_watermark = 42`.
- If the node has applied slot 42 or higher, the query executes immediately.
- If the node has only applied slot 40, it returns `.Stale_Watermark`. The client or routing proxy
  can await replication catch-up or retry against an up-to-date node.

This delivers guaranteed *Read-Your-Writes Consistency* across a distributed multi-master cluster
with zero consensus coordination during read queries.
