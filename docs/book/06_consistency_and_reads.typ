#import "theme.typ": callout

= Consistency and Reads

== Local Snapshot Reads

`engine_read_snapshot` uses the durable host's read-only connection and returns the number
of result rows. It rejects write statements and propagates stepping errors. It does not return a
network result set or coordinate a distributed read. The host must serialize access to the engine
and its applied watermark. A local replica may lag other replicas.

File-backed engines enable SQLite WAL. The historical `:memory:` benchmarks do not measure WAL
read concurrency or file-backed latency. Query cost depends on data, indexes and storage; no fixed
microsecond latency is guaranteed.

== Read-Your-Writes with an Applied Watermark

```odin
rows, err := engine_read_snapshot(&engine, query, min_watermark = committed_slot)
```

If `engine.applied_through` is lower than the requested slot, the engine returns `Stale_Watermark`.
Otherwise it executes the query locally. The host can wait for catch-up or route to another replica.
The token must refer to the client's observed committed outcome, not merely the initial proposed
slot: revocation can cause resubmission in a later slot.

This mechanism can supply read-your-writes when a host routes tokens correctly and restores a
valid applied state. Switching replicas without carrying a token does not guarantee a monotonic
view. The library does not implement client routing or waiting.

== Linearizable Reads

A local watermark check alone does not prove that no newer write completed elsewhere before the
read. The durable host now supplies an ordered-barrier reference API: `begin_read` reserves a fresh
durable identifier after invocation and proposes a unique no-op marker. `poll_read` opens a local
SQLite snapshot only after that exact marker and its contiguous prefix have applied. A write
acknowledged before invocation must precede this marker in that prefix.

A host allows one active ticket. Completion consumes it even if the query fails; cancellation or
restart retires it. If another value occupies the proposed slot, `Displaced` requires a fresh barrier.
An isolated minority cannot complete the barrier. Callers must keep delivering messages and ticks,
serialize host access and treat the initial proposal slot as pending rather than a completed fence.

This is a consensus write for each read, with the corresponding disk and quorum costs. It is not
a lease optimization. The three-process tests exercise fresh fences at every voter, minority
isolation and a stale restarted voter observing already acknowledged writes. The native service
now adds authentication and typed results; full service-level history qualification remains open.

The count-only reference API bounds reads to one statement, 4 KiB SQL, 65,536 rows and
approximately one million SQLite VM instructions. A query exceeding its work budget returns
`Query_Limit`; partial rows are not a successful result. The progress budget never decides a
replicated write's outcome. The native value-result API tightens the row limit to 4096 and adds
a 256 KiB internal result budget. Applications should use bounded, indexed queries and pagination.
