#import "figures.typ": steps
= Work, memory and latency
<runtime>

Odin gives the host control over data layout and allocation. That control removes
some overhead; it does not remove the need to persist votes, wait for a quorum or
execute SQLite. To improve performance, first identify which resource limits progress.

== Own the data that outlives a turn

The service uses a fixed connection array and a serialized owner for host state.
Configuration lives in its own arena. Short-lived decoding and results use a temporary
allocator. A payload borrowed from a decoder or protocol effect cannot remain borrowed
after that storage is reused. Pending protocol and durable work therefore own their copies.

The consensus window is a fixed array of 64 active slots. With window size $W$ and
bounded value size $B$, its value storage grows as $O(W B)$, independent of lifetime
history length. Slot reuse is tied to the applied floor; modulo indexing alone would
overwrite a still-needed slot. SQLite, TLS, queues and worker state add allocations
outside this array. Fixed capacity is not zero memory cost.

The mutation representation shares vector storage across columns instead of reserving
a full embedding per scalar column. Small requests still carry and copy a bounded value
through several layers. Those copies and JSON encoding remain measured costs, even when
the consensus transition itself performs no heap allocation.

== Admission protects the quorum path

The 32-connection pool admits at most 24 authenticated clients and four incoming
handshakes/rejected-client connections. Fixed peers retain capacity. Each connection
has a bounded frame buffer and at most 64 queued frames, also capped at 2 MiB total.
JSON nesting is checked before recursive decoding.

The owner considers clients in bounded turns. It may admit up to sixteen already waiting
writes and share a fresh marker among already waiting reads. Peer receive and output
bursts are bounded at eight steps. This amortizes work without waiting for a batching
timer to collect requests. Slow-peer traffic can be dropped for retransmission rather
than accumulated without limit.

#figure(steps((
  ([Admit], [Bound clients, frames and already waiting work.]),
  ([Advance], [Serve peer traffic and durable transitions.]),
  ([Yield], [Return between bounded maintenance units.]),
)), caption: [Bounds keep one queue from consuming all service turns. They do not preempt a blocked system call.])

Maintenance uses one worker/job with bounded chunks and explicit cancellation. The final
generation catch-up applies one transaction per owner turn. A transaction itself can
still perform substantial I/O. A SQLite progress callback counts VM work; an optimized
B-tree operation can do disk work inside one VM opcode. Neither count is a hard deadline.

#pagebreak()
== A simple cost model

Let $f$ be the time spent at a durability barrier and $b$ the number of useful requests
sharing it. That barrier contributes roughly $f/b$ per request when amortized. This is
not a throughput formula for the entire database: a write crosses multiple ordered
stages, and quorum waits, application work and queueing can dominate elsewhere.

Client latency includes admission, protocol progress, durable voting, earlier-slot
completion, local application and the response path. A healthy owner may choose a value
in one quorum round trip. That does not make the client operation a one-RTT transaction.

In a stable workload, Little's law relates average in-flight work $L$, completed rate
$lambda$ and average response time $T$:

$ L = lambda T. $

Increasing clients can expose more batching. Beyond the bottleneck it mainly grows
waiting time. This relation assumes a stable measurement interval; it should not be
used to infer capacity from a growing backlog or a failed run.

Low CPU utilization is compatible with poor latency when threads wait on storage.
High throughput with weaker synchronization is a different durability contract.
@benchmarks reports both measured rates and persistence boundaries, so an optimization
cannot appear successful merely by changing what is being measured.

== What the resource checks show

The corrected bounded load test exercises full client admission, slow consumers with
120,000-byte responses, excess clients, stalled handshakes, writes and live maintenance.
It records 3,840 operations and roughly 29–35 MiB peak ordinary voter RSS. Instrumented
runs measure allocations separately because instrumentation changes timing.

These observations support the tested short-query profile. They do not establish a
maximum database size or immunity to arbitrary hostile SQL. The service fails closed
on unknown replicated execution/storage errors. If all voters lack resources for the
same chosen write, quorum alone cannot make that write executable.

The #link("../../specs/resource-contract.typ")[resource contract] defines bounds and
fault handling. The #link("../../specs/service-batching.typ")[batching argument] records
why the optimizations preserve ordering and where performance remains below its goals.


== Embed the durable host

An Odin embedding owns the responsibilities that `sqlodin serve` normally supplies.
Serialize access to each host. Drive peer delivery and ticks, consume outgoing packets,
and stop serving when an unknown storage failure poisons the host. Do not call SQLite
through a second writer or mutate its metadata outside the ordered host.

#table(columns: (1.15fr, 1.85fr),
  table.header([Host operation], [Caller responsibility]),
  [`open_store`, `close`], [Own the locked format-5 directory and release resources explicitly.],
  [`propose`, `propose_batch`], [Keep the request identity; a returned slot is not success.],
  [`step`, `step_batch`, `tick`], [Drive protocol progress and handle copied output before reuse.],
  [`outcome`, `acknowledged`], [Match the expected chosen request, not merely a slot number.],
  [`begin_read`, `poll_read`], [Use a fresh single-use ticket for a quorum-backed read.],
  [`next_id`], [Use durable reservations when IDs must survive restart.],
)

The concrete entry points are in `src/durable/`; `tests/test_durable.odin` exercises
their lifecycle. The in-memory example under `examples/` teaches message flow but
has a different policy and no disk durability. Do not use its completion condition
as the storage contract for an embedded production host.
