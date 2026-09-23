#let sod-number = "0002"
#let sod-title = "SQLodin Architecture: Multi-Master Replicated SQLite Protocol"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "Complete architectural specification of the multi-master SQLite protocol, direct owner proposals, sqlite-vec, and FTS5 integration"
#let sod-labels = ("architecture", "sqlite", "multi-master", "consensus", "sqlite-vec", "fts5")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
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

= Implementation Status Note (2026-09-22)

This historical design is superseded at the implementation boundary by the pinned upstream integration
SOD draft. SQLodin now supplies a fixed-membership durable Paxos journal and restart replay, but no production transport. Watermark reads are
implemented; quorum read fences, client response routing are not supplied; durable mutation serialization is implemented.
The durability gate checks a host acknowledgment; it cannot verify that the host actually fsynced data.
Earlier fixed latency and throughput claims are withdrawn. Consult the dated review and current README.

= Abstract

This document specifies the architecture of `sqlodin` version `0.1.0`: a high-performance, bounded, data-oriented multi-master replicated SQLite database engine written in Odin. `sqlodin` provides concurrent multi-master inserts, deletes, and reads across all cluster nodes without the single-leader forwarding bottleneck in its proposal path; comparative latency requires a matched distributed benchmark.

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
  [Read Consistency], [Committed], [Local snapshot reads and confirmed-write slot watermarks; distributed read fences remain planned.],
)

= The Multi-Master Problem and Direct Proposals

== Ordering Logical Transactions

SQLodin accepts transaction proposals at any configured voter, orders them in one consensus log,
and applies the same logical operations to each SQLite database. Proposal admission can be
concurrent while application remains serialized at each replica. Independently produced database
page images cannot simply be merged in arrival order. The protocol therefore agrees on logical
transactions before each replica executes their SQL.

The design separates three obligations: direct proposal admission, quorum-backed durable ordering,
and contiguous local application before acknowledgement. Their combined cost must be measured;
the consensus fast path alone does not establish client latency or sustained write capacity.

== The SQLodin Multi-Master Protocol

SQLodin configures the pinned paxos-odin implementation for direct owner proposals:

#block(
  width: 100%,
  inset: 10pt,
  radius: 4pt,
  fill: rgb("f8fafc"),
  stroke: 0.5pt + rgb("cbd5e1"),
)[
  *1. Rotating Slot Ownership (Log Partitioning):* For an $N$-node cluster, slot ownership is partitioned statically: Node $i$ owns every slot $S$ where $S equiv i (mod N)$. \
  *2. 1-RTT Fast-Path Commit:* When Node $i$ receives a local write (insert, delete, or transaction), it assigns the proposal directly to its next pre-owned slot $S$. Because Node $i$ is the designated owner of slot $S$ with ballot `ballot_make(0, 0, node_id)`, *no Phase 1 (Prepare/Promise) is executed*. Node $i$ broadcasts `Accept` directly to its peers. Peers verify `ballot >= promised` and reply `Accepted`. Upon receiving a majority quorum, the slot can be chosen in *one quorum round trip*, plus persistence barriers. Durable client completion also waits for contiguous application. \
  *3. Zero Forwarding:* Any node is a master for its incoming writes. Proposal admission needs no standing-leader forwarding hop; completion still waits for quorum durability and contiguous application.
]

== Skip Coordination and Contiguous Progress

Because replicas apply transactions in contiguous slot order ($1, 2, 3, 4, dots$), an idle master with no incoming writes must not block the commit line. SQLodin provides:

1. *Lightweight Skips:* An idle node periodically issues a `Skip` message (a zero-payload no-op proposal in its owned slot) through ordinary quorum voting.
2. *Revocation of Stalled Slots:* If a node crashes or becomes unresponsive, any active peer after a configurable stall timeout initiates a bounded Phase 1 campaign (revocation) to claim the stalled slot and propose a no-op, unblocking the global log line.

= Deterministic Logical Mutations vs Raw WAL Frames

To support concurrent multi-master writes while ensuring all replicas converge to identical database states, SQLodin replaces physical page replication with a deterministic logical mutation log.

== Logical Transaction Descriptor

A proposed write is packaged into a deterministic `Mutation` record:
- `.Insert`: table name, column list, row values, and pre-assigned primary key.
- `.Delete`: table name and target primary key.
- `.Update`: table name, modified columns, new values, target key.
- `.Raw_SQL`: caller-supplied SQL without retry identity or bound parameters.
- `.Transaction`: bounded SQL, typed parameters and a durable session/sequence identity.

== Conflict-Free Primary Key Partitioning (Snowflake IDs)

To guarantee that concurrent inserts on different masters never collide on auto-increment IDs, SQLodin exposes a 64-bit Snowflake-style ID generator (not UUIDv7):

```
bits 63..22: timestamp_ms (42 bits, ~139 years of millisecond precision)
bits 21..12: node_id      (10 bits; supported IDs 1..1023)
bits 11..0:  sequence     (12 bits, up to 4096 unique IDs per ms per node)
```

Callers reserve an ID with `durable.next_id` and supply it explicitly. SQL inserts do not
automatically receive Snowflake IDs. No-reuse guarantees require unique node identities and durable
reservation frontiers. Other unique constraints can still conflict.

== Multi-Master Deletes and Idempotency

Structured deletes target a primary key. Deleting an absent row can be a no-op, but a retry in a
later slot is not generally idempotent: intervening writes or trigger effects can matter. Use a
format-2 transaction request for durable retry deduplication. Total ordering establishes execution
order; it does not make arbitrary SQL idempotent.

== Non-Deterministic Functions

Functions that depend on local node state (such as `CURRENT_TIMESTAMP`, `random()`, or client UUIDs)
must be evaluated and bound by the caller before proposal. The format-2 durable host rejects
functions outside its allowlist, including defaults omitted by the SQLite authorizer. Arbitrary SQL
determinism and engine/schema/ordering compatibility remain open production gates.


= Integrated Vector Search (sqlite-vec) and Full-Text Search (FTS5)

The embedded engine and volatile examples support sqlite-vec and FTS5. These features are not
yet qualified for the stricter durable transaction policy:

1. *`sqlite-vec` Dense Vector Indexing:*
   - Integrated as a static extension via `sqlite3_vec_init`.
   - Supports `vec0` virtual tables for storing high-dimensional float32 embeddings (the current mutation binding permits at most 384 dimensions per vector).
   - Fast vector similarity search using cosine distance (`vec_distance_cosine`) and L2 Euclidean distance (`vec_distance_l2`).
   - Mutations containing vector embeddings replicate across the multi-master log and update vector indexes atomically on all replicas.

2. *SQLite FTS5 Full-Text Search:*
   - Built-in FTS5 full-text search engine with BM25 ranking.
   - Text documents inserted into virtual tables (`USING fts5(...)`) are indexed concurrently across nodes.
   - Any replica can serve hybrid queries combining vector similarity, full-text match, and relational SQL filters with zero network overhead.

= Read Consistency Levels

The design distinguishes three read contracts; only the local and watermark APIs currently exist:

1. *Local Snapshot Read (`.Local`):*
   - Executed immediately against the local SQLite WAL snapshot.
   - *Latency:* no network coordination; execution time depends on the query and storage.
   - Suitable for read-heavy workloads, analytics, and vector search where eventual consistency is acceptable.

2. *Monotonic Read / Read-Your-Writes (`.Watermark`):*
   - The client supplies the slot watermark $W$ returned by its previous write.
   - The local node serves the read immediately if its applied slot $A >= W$.
   - If $A < W$, the node awaits local state machine catch-up before serving the snapshot.
   - Supplies read-your-writes only when the token names a confirmed applied write and is carried across replicas.

3. *Linearizable Read (proposed):*
   - The serving node confirms cluster freshness via a quorum read fence before serving the query, ensuring no unapplied committed writes exist.
   - A correct multi-owner barrier is required. The new SOD uses an ordered barrier as its initial reference; a no-log read fence needs a separate proof.

= Pure Effect Machine Consensus Core

Following the engineering principles established in POD 0002, SQLodin's consensus engine is a pure state machine:

1. *Deterministic Inputs:* `step(&node, envelope, &effects)`, `propose(&node, mutation, &effects)`, `tick(&node, &effects)`.
2. *Pure Transitions:* The core performs no direct I/O, allocates nothing on the heap, and accesses no clocks or sockets.
3. *Explicit Effects:* All output actions are appended to caller-owned buffers:
   - `writes`: durable journal records that must be persisted to disk.
   - `messages`: outbound network packets to cluster peers.
   - `committed`: slots ready to be applied by the SQLite state machine.
   - `requests`: host work such as historical range service; the host constructs client responses.
4. *Durability Gate:* The gate requires host confirmation before dependent effects are consumed.
   The host must actually synchronize storage before confirming; the type cannot detect a false confirmation.

= Verification and Acceptance Gates

SQLodin is verified through an extensive suite of automated checks:
1. *Style & Zen Constraints:* `tools/check_style.py` enforces file length (<= 1408 lines), column width (<= 108 columns), and procedure logic density (<= 70 lines).
2. *Unit Test Suite:* Deterministic tests in `tests/` covering ballots, rotating slot ownership, fast-path 1-RTT commits, Snowflake generation, mutation serialization, SQLite state application, vector search, and FTS5.
3. *Seeded Chaos Simulator:* `sim/simulation.odin` drives multi-master clusters under packet loss, reordering, node crashes, and restarts, validating that all SQLite databases reach byte-level or content-level convergence.
4. *In-Process Benchmarks:* `bench/` measures successful replication and SQLite application with a matched single-leader mode. It excludes sockets, consensus fsync and WAN forwarding; no fixed latency saving is established.

= References

- SOD 0001: The SQLodin Discussion Process.
- POD 0002: Paxos-Odin: Architecture and Pure State Machine Design (`paxos-odin`).
- POD 0010: Rotating Slot Ownership (`paxos-odin`).
- Mao, Yanhua, Junqueira, Flavio P., and Marzullo, Keith. "Mencius: Building Efficient Replicated State Machines for WANs." OSDI, 2008.
- SQLite Consortium. "Write-Ahead Logging." `https://www.sqlite.org/wal.html`.
- sqlite-vec: "A vector search SQLite extension that runs anywhere." `https://github.com/asg017/sqlite-vec`.
