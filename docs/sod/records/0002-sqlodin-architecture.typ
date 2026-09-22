#let sod-number = "0002"
#let sod-title = "SQLodin Architecture: Multi-Master Replicated SQLite Protocol"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "Complete architectural specification of the multi-master SQLite protocol, elimination of the 42ms penalty, sqlite-vec, and FTS5 integration"
#let sod-labels = ("architecture", "sqlite", "multi-master", "consensus", "sqlite-vec", "fts5")
#let sod-authors = ("Vikrant Rathore <vikrant@insan.ai>", "SQLodin Contributors")
#let sod-category = "Architectural Specification"
#let sod-status = "Committed"
#let sod-last-updated = "2026-09-22"

#import "../../shared/sod.typ": sod-document

#show: doc => sod-document(
  sod-number,
  sod-title,
  doc,
  authors: sod-authors,
  state: sod-state,
  created: sod-created,
  discussion: sod-discussion,
  labels: sod-labels,
  category: sod-category,
  status: sod-status,
  last-updated: sod-last-updated,
)

= Abstract

This document specifies the architecture of `sqlodin` version `0.1.0`: a high-performance, bounded, data-oriented multi-master replicated SQLite database engine written in Odin. `sqlodin` provides concurrent multi-master inserts, deletes, and reads across all cluster nodes without the single-leader forwarding bottleneck or the classic 42ms cross-region network penalty observed in single-leader systems such as Zaxonlite.

The engine integrates Odin's SQLite engine with the `sqlite-vec` vector similarity search extension and SQLite FTS5 full-text search. The consensus core is implemented as a pure, deterministic effect machine with zero heap allocations during consensus transitions and an enforced durability gate.

= Status and Implementation Boundary

This committed specification describes the implemented core protocol, consensus layer, SQLite mutation state machine, and vector/FTS search integration:

#table(
  columns: (auto, auto, 1fr), inset: 5pt,
  [*Component*], [*State*], [*Implementation or evidence boundary*],
  [Multi-Master Consensus], [Committed], [Rotating slot ownership protocol, 1-RTT fast path, zero forwarding.],
  [Mutation Engine], [Committed], [Deterministic logical mutation log, Snowflake primary key partition.],
  [SQLite State Machine], [Committed], [Contiguous slot application into SQLite WAL mode, idempotent deletes.],
  [Search Extensions], [Committed], [Static sqlite-vec (vec0) registration and SQLite FTS5 integration.],
  [Read Consistency], [Committed], [Local snapshot reads (0 RTT), Read-Your-Writes slot watermarks, read fences.],
)

= The Multi-Master Problem and Elimination of the 42ms Penalty

== The Single-Leader Bottleneck in Zaxonlite

Zaxonlite achieved crash consistency by replicating the raw physical page frames of SQLite's write-ahead log (WAL). Because SQLite B-trees cannot merge physical page writes produced independently by multiple nodes, Zaxonlite was structurally constrained to a single writer:

1. *Single-Writer Serializability:* All write transactions must execute sequentially on the single elected leader node.
2. *The Forwarding Penalty (42ms WAN Latency):* If a client in Tokyo or Frankfurt issues an insert to a local node while the leader resides in Northern Virginia, the local node cannot execute or propose the write. It must forward the request over the wide-area network (WAN) to the remote leader. Under typical cross-continent fiber latencies, this round-trip introduces an unavoidable ~42ms network penalty per write before consensus even begins!
3. *Lease Ping-Pong:* Systems that attempt dynamic leadership handoff or exclusive write leases incur multiple rounds of phase-1 prepare/promise exchanges, causing latency spikes of 40–100ms and dueling proposer contention.

== The SQLodin Multi-Master Protocol

SQLodin redesigns the protocol from first principles to enable concurrent writes on every node with zero forwarding delay:

#block(
  width: 100%,
  inset: 10pt,
  radius: 4pt,
  fill: rgb("f8fafc"),
  stroke: 0.5pt + rgb("cbd5e1"),
)[
  *1. Rotating Slot Ownership (Log Partitioning):* For an $N$-node cluster, slot ownership is partitioned statically: Node $i$ owns every slot $S$ where $S equiv i (mod N)$. \
  *2. 1-RTT Fast-Path Commit:* When Node $i$ receives a local write (insert, delete, or transaction), it assigns the proposal directly to its next pre-owned slot $S$. Because Node $i$ is the designated owner of slot $S$ with ballot `ballot_make(0, 0, node_id)`, *no Phase 1 (Prepare/Promise) is executed*. Node $i$ broadcasts `Accept` directly to its peers. Peers verify `ballot >= promised` and reply `Accepted`. Upon receiving a majority quorum, the slot is committed in *exactly one network round-trip* (1 RTT). \
  *3. Zero Forwarding:* Any node is a master for its incoming writes. Writes complete locally without routing to a remote primary.
]

== Skip Coordination and Contiguous Progress

Because replicas apply transactions in contiguous slot order ($1, 2, 3, 4, dots$), an idle master with no incoming writes must not block the commit line. SQLodin provides:

1. *Lightweight Skips:* An idle node periodically issues a `Skip` message (a zero-payload no-op proposal in its owned slot) or piggybacks an advanced trim watermark onto heartbeats.
2. *Revocation of Stalled Slots:* If a node crashes or becomes unresponsive, any active peer after a configurable stall timeout initiates a bounded Phase 1 campaign (revocation) to claim the stalled slot and propose a no-op, unblocking the global log line.

= Deterministic Logical Mutations vs Raw WAL Frames

To support concurrent multi-master writes while ensuring all replicas converge to identical database states, SQLodin replaces physical page replication with a deterministic logical mutation log.

== Logical Transaction Descriptor

A proposed write is packaged into a deterministic `Mutation` record:
- `.Insert`: table name, column list, row values, and pre-assigned primary key.
- `.Delete`: table name, target primary key or indexed predicate.
- `.Update`: table name, modified columns, new values, target key.
- `.Raw_SQL`: deterministic SQL statements with parameterized arguments.

== Conflict-Free Primary Key Partitioning (Snowflake IDs)

To guarantee that concurrent inserts on different masters never collide on auto-increment IDs, SQLodin incorporates a distributed 64-bit Snowflake/UUIDv7 ID generator:

```
bits 63..22: timestamp_ms (42 bits, ~139 years of millisecond precision)
bits 21..12: node_id      (10 bits, up to 1024 cluster nodes)
bits 11..0:  sequence     (12 bits, up to 4096 unique IDs per ms per node)
```

Every insert without an explicit user-supplied key receives a cluster-unique, monotonically increasing 64-bit ID. Inserts across masters never conflict.

== Multi-Master Deletes and Idempotency

Deletes target records by primary key. Because transactions are applied in total contiguous slot order, delete operations are idempotent:
- If the target row exists when the slot is applied, it is removed.
- If a concurrent delete on another master already removed the row in an earlier slot, the subsequent delete is a safe, deterministic no-op.
- Both operations result in identical table state across all replicas.

== Non-Deterministic Functions

Functions that depend on local node state (such as `CURRENT_TIMESTAMP`, `random()`, or client UUIDs) are evaluated and bound by the receiving master at proposal time. Replicas execute the fully resolved values, ensuring byte-level and semantic determinism.

= Integrated Vector Search (sqlite-vec) and Full-Text Search (FTS5)

SQLodin natively embeds advanced AI and information retrieval capabilities directly into the replicated SQLite engine:

1. *`sqlite-vec` Dense Vector Indexing:*
   - Integrated as a static extension via `sqlite3_vec_init`.
   - Supports `vec0` virtual tables for storing high-dimensional float32 embeddings (e.g. 384, 768, 1536 dimensions).
   - Fast vector similarity search using cosine distance (`vec_distance_cosine`) and L2 Euclidean distance (`vec_distance_l2`).
   - Mutations containing vector embeddings replicate across the multi-master log and update vector indexes atomically on all replicas.

2. *SQLite FTS5 Full-Text Search:*
   - Built-in FTS5 full-text search engine with BM25 ranking.
   - Text documents inserted into virtual tables (`USING fts5(...)`) are indexed concurrently across nodes.
   - Any replica can serve hybrid queries combining vector similarity, full-text match, and relational SQL filters with zero network overhead.

= Read Consistency Levels

Clients can choose from three explicit read consistency guarantees:

1. *Local Snapshot Read (`.Local`):*
   - Executed immediately against the local SQLite WAL snapshot.
   - *Latency:* 0 network hops, sub-millisecond execution.
   - Suitable for read-heavy workloads, analytics, and vector search where eventual consistency is acceptable.

2. *Monotonic Read / Read-Your-Writes (`.Watermark`):*
   - The client supplies the slot watermark $W$ returned by its previous write.
   - The local node serves the read immediately if its applied slot $A >= W$.
   - If $A < W$, the node awaits local state machine catch-up before serving the snapshot.
   - Guarantees causal consistency and prevents backward time jumps.

3. *Linearizable Read (`.Linearizable`):*
   - The serving node confirms cluster freshness via a quorum read fence before serving the query, ensuring no unapplied committed writes exist.
   - Executes with zero disk I/O and zero log appends.

= Pure Effect Machine Consensus Core

Following the engineering principles established in POD 0002, SQLodin's consensus engine is a pure state machine:

1. *Deterministic Inputs:* `step(&node, envelope, &effects)`, `propose(&node, mutation, &effects)`, `tick(&node, &effects)`.
2. *Pure Transitions:* The core performs no direct I/O, allocates nothing on the heap, and accesses no clocks or sockets.
3. *Explicit Effects:* All output actions are appended to caller-owned buffers:
   - `writes`: durable journal records that must be persisted to disk.
   - `messages`: outbound network packets to cluster peers.
   - `committed`: slots ready to be applied by the SQLite state machine.
   - `responses`: acknowledgements to local client connections.
4. *Durability Gate:* The runtime gate strictly enforces that `writes` are fsynced to disk before `messages` are transmitted, preventing split-brain safety violations.

= Verification and Acceptance Gates

SQLodin is verified through an extensive suite of automated checks:
1. *Style & Zen Constraints:* `tools/check_style.py` enforces file length (<= 1408 lines), column width (<= 108 columns), and procedure logic density (<= 70 lines).
2. *Unit Test Suite:* Deterministic tests in `tests/` covering ballots, rotating slot ownership, fast-path 1-RTT commits, Snowflake generation, mutation serialization, SQLite state application, vector search, and FTS5.
3. *Seeded Chaos Simulator:* `sim/simulation.odin` drives multi-master clusters under packet loss, reordering, node crashes, and restarts, validating that all SQLite databases reach byte-level or content-level convergence.
4. *Latency & Throughput Benchmarks:* `bench/` verifies that multi-master writes avoid the 42ms forwarding penalty and achieve high concurrent throughput.

= References

- SOD 0001: The SQLodin Discussion Process.
- POD 0002: Paxos-Odin: Architecture and Pure State Machine Design (`paxos-odin`).
- POD 0010: Rotating Slot Ownership (`paxos-odin`).
- Mao, Yanhua, Junqueira, Flavio P., and Marzullo, Keith. "Mencius: Building Efficient Replicated State Machines for WANs." OSDI, 2008.
- SQLite Consortium. "Write-Ahead Logging." `https://www.sqlite.org/wal.html`.
- sqlite-vec: "A vector search SQLite extension that runs anywhere." `https://github.com/asg017/sqlite-vec`.
