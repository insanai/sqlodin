#import "theme.typ": blue, gray, callout

= The SQLite State Machine Engine

== Embedded Engine Architecture

The imported Paxos library performs no I/O or SQLite commands. The host persists its effect writes,
confirms durability, copies outgoing payloads and passes contiguous `Committed(Mutation)` entries to
`engine_apply_batch`. The SQLite WAL is not a substitute for the Paxos promise/vote journal.

An engine owns its writer connection, applied watermark, an eight-statement DML cache and local
Snowflake generator state. Calls on that engine and its consensus node must be serialized by the host.

The durable host also owns a read-only connection for local aggregates and window queries; the
writer retains the stricter replicated function policy. Access remains serialized.
File databases use WAL and `synchronous=FULL`. Initialization creates or reads:

```sql
CREATE TABLE IF NOT EXISTS _sqlodin_state (
    id INTEGER PRIMARY KEY CHECK(id=1),
    applied INTEGER NOT NULL
);
INSERT OR IGNORE INTO _sqlodin_state VALUES (1, 0);
```

The stored slot is loaded on reopen. A preexisting database without trustworthy application metadata
needs a coordinated migration or reconstruction from matching durable history, not blind replay.

== Contiguous and Atomic Application

`engine_apply_slot` wraps a single entry; `engine_apply_batch` groups entries in one transaction.
Zero slots and gaps return `Invalid_Slot`. Entries at or below the applied watermark are ignored.
Mutation lengths, kinds and identifiers are validated before taking slices or generating SQL.

```sql
BEGIN IMMEDIATE;
-- Execute the contiguous mutation batch.
UPDATE _sqlodin_state SET applied = ? WHERE id=1;
COMMIT;
```

BEGIN, bindings, execution and COMMIT are checked. A failure rolls back the batch and keeps the
in-memory watermark unchanged. Only successful COMMIT advances `Engine.applied_through`.
This is the legacy engine batch interface. The durable host's format-2 outcome path below isolates
each request and distinguishes expected SQL rejection from storage failure.

Structured inserts use INSERT OR REPLACE, updates assign supplied columns, and deletes target the
primary key. This overwrite behavior is a policy, not conflict detection. No-op slots still advance
persistent metadata. A batch can amortize transaction overhead across contiguous decisions.

== Binding Lifetimes and Raw SQL

Text and vectors are bound directly from an immutable mutation with explicit byte lengths. Cached
statements are reset and bindings cleared before the mutation can be released. Vector payloads are
BLOBs of f32 values; their shared fixed-capacity buffer avoids per-column embedding reservations.

Replicated SQL, including triggers reached by structured mutations, runs under an authorizer that prevents transaction escape and changes to internal
metadata. The legacy engine allows FTS5's read-only data_version query. The durable host applies a
stricter function policy and rejects virtual-table creation. Neither interface establishes arbitrary
SQL determinism. Format-2 transaction requests provide durable retry identity; legacy raw SQL does not.

#pagebreak()
== Recovery Boundary

SQLite recovery and the persisted applied slot restore application state. Separately replay the durable
Paxos journal and call the upstream-backed restoration adapter. Retain or serve historical decisions
when a peer asks for slots below the memory floor; larger gaps can require a certified state image.
The simulator models durability in memory. The separate durable host described below supplies a
disk-backed journal and historical range service; snapshots and production transport remain future work.

== Durable Host and Restart Verification

The `src/durable` package now implements the fixed-membership host. Its application tables,
Paxos journal, chain head and ID reservations share one disk database. Journal transactions use
WAL with FULL synchronization; dependent messages and application work are released only after
successful journal COMMIT. A storage failure poisons the host and suppresses outgoing packets and
client acknowledgements until recovery succeeds.

The versioned codec writes scalar fields in little-endian order and preserves complete logical
mutation values without pointers or compiler padding. SHA-256 chained records and a transactional
head detect damaged or missing retained history. Startup checks identity, membership, format,
SQLite integrity and log continuity, restores promises and votes, then applies the remaining
contiguous decision suffix. File creation is explicit: a missing acceptor file is never silently
recreated during a restart.

Linux verification kills processes before journal COMMIT, after journal COMMIT, after SQL COMMIT,
and after acknowledgement. A three-voter test kills the process hosting all replicas immediately
after its 80th acknowledged write, then verifies all recovered copies. Unit regressions exercise
concurrent master admission, disk-full/read-only failures, corrupted history, persisted promises,
restart-safe IDs and catch-up beyond the 64-slot memory window.

#callout(title: "Scope of the durability evidence", kind: "warning")[
  These are process-crash and injected-failure tests, not physical power-cut certification.
  Storage must honor synchronization. Format 2 retains full disk history: disk space and restart
  time grow with history. Snapshot transfer, log compaction, membership changes, lost-disk
  replacement, backup rollback fencing and a production transport remain outside this host.
]

The original crash report is `benchmarks/results/linux-durability.json`; the transaction/retry campaign
uses `linux-production-p1-durability.json`. The Linux build
pins SQLite 3.51.3, including its WAL-reset corruption fix. See `docs/durability.md` for the precise
acknowledgement, deterministic SQL, deployment and recovery contracts.
