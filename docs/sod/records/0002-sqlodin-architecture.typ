#let sod-number = "0002"
#let sod-title = "SQLodin Architecture: Multi-Master Replicated SQLite Protocol"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "Fixed-voter SQL ordering, host boundaries and client semantics"
#let sod-labels = ("architecture", "sqlite", "multi-master", "consensus", "sqlite-vec", "fts5")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Architectural Specification"
#let sod-status = "Committed"
#let sod-last-updated = "2026-09-25"

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

SQLodin orders bounded SQL transactions through a fixed set of voters. Any voter can admit a
write. Each replica applies the same chosen prefix to SQLite. This record explains why the
system separates consensus, durable storage, SQL execution and client service. SOD 0003 states
the proof obligations; SOD 0004 records the durable host and qualification decisions.

= Status and Implementation Boundary

*Committed; reviewed 25 September 2026.* The accepted architecture is implemented and qualified
for the fixed three-voter scope in `docs/releases/2026-09-25.typ`. This is not a frozen Published
specification. Qualification does not establish arbitrary SQL support, live membership changes,
Byzantine tolerance or increasing write throughput with each added replica.

The service uses store format 5, SQL policy 9 and peer wire 3. Native CLI and Python package
versions are separate. The complete paxos-odin dependency is pinned at
`c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c`; SQLodin does not maintain a partial protocol copy.

= Introduction

SQLite supplies a transactional application store. Consensus supplies an order across machines.
Neither supplies the other's guarantees. A chosen command can still be waiting for local SQL
application. A local commit can still be unsafe to acknowledge if the ordering evidence was not
made durable. The host must connect these boundaries explicitly.

= Terminology and Scope

A *voter* persists promises and accepted values. A *slot* names one position in the ordered log.
A value is *chosen* after a durable majority accepts it. The *applied prefix* is the contiguous
sequence executed locally. An *owner* has the initial proposal right for a slot; it is not the
sole writer for the database. Membership is fixed for the qualified configuration.

= Problem Statement

Concurrent entry points must agree on one SQL history without forwarding every proposal to a
standing leader. An idle or failed owner must not leave an unfillable hole. Crash recovery must
preserve both the voting evidence and the application prefix. Client retries must not repeat
an already executed effect.

= Goals and Non-Goals

== Goals

- Admit writes at any configured voter and preserve one agreed execution order.
- Keep consensus transitions deterministic, bounded and separate from I/O.
- Acknowledge only after quorum durability and local durable application.
- Offer explicit read consistency and bounded, durable retry identities.

== Non-Goals

Live voter enrollment, sharding, Byzantine agreement and arbitrary extensions are outside this
design. Replication gives availability and read placement; every replica still executes the
ordered writes through one SQLite writer.

= Design Overview

#block(fill: rgb("f1f5f9"), inset: 10pt, breakable: false)[
  CLI / Python / embedded caller → bounded request admission \
  → pinned Paxos state machine → owned durable effects \
  → chosen contiguous prefix → SQLite data + outcome + applied watermark \
  → client acknowledgement
]

The upstream core emits effects into caller-owned storage. It does not perform disk or network
I/O. The SQLodin host owns persistence, transport, application and responses. Explicit ownership
keeps borrowed buffers from outliving their input and prevents workers from mutating protocol state.

= Detailed Design

== Rotating ownership and recovery

For voters numbered 1 through $N$, slot ownership is
$ "owner"(s) = ((s - 1) mod N) + 1. $
The reserved owner ballot may begin with Accept. A healthy, uncontested slot can be chosen in
one quorum exchange, including its durable voting barriers. This is not end-to-end SQL latency.

Idle positions are closed with quorum-chosen no-ops. A stalled owner can be recovered through a
higher-ballot prepare. Recovery must adopt the highest accepted value reported by that quorum;
it may use a no-op only when the protocol permits it. Bounded demand frontiers and fair recovery
service prevent idle slot selection from manufacturing an endless stream of new work.

== Logical transactions

Replicas agree on SQL and typed parameters, not independently modified SQLite pages. The durable
SQL policy admits a constrained deterministic subset. A transaction carries a session, sequence,
epoch and canonical request identity. The outcome and applied watermark commit with the data.
Reusing an identity for different content is rejected. Retirement advances a durable epoch fence;
old requests cannot silently become new requests after outcome rows are reclaimed.

Structured mutation helpers remain available. Generated Snowflake-style IDs are explicitly
reserved and supplied by the caller; ordinary SQL inserts do not automatically use them. Unique
node identities and durable reservation frontiers are required to prevent reuse after restart.
Total ordering does not make raw SQL retries idempotent.

== Reads and interactive transactions

Local reads use the replica's current snapshot. Watermark reads wait for a confirmed applied
prefix. Fresh reads join a closed cohort before its ordered marker is allocated, then execute
after that marker applies. Reusing an earlier marker would not establish freshness.

Interactive and ORM transactions use a private preview and an ordered commit that validates the
database revision. Any intervening revision can cause a conflict. This conservative rule covers
predicate reads, at the cost of conflicts even when two writes touch different rows. Rollback
and savepoints operate within the bounded transaction contract.

== Search and service boundary

FTS5 and scalar sqlite-vec distance functions support full-text and exact vector queries.
The durable SQL policy excludes `vec0` virtual tables; extension availability is not permission
to replicate every extension operation. Hybrid ranking combines query results under the chosen
read contract. Exact distance scans do not promise indexed nearest-neighbor performance.

The native service authenticates configured peers and clients with mTLS and rejects incompatible
identities and protocol versions. The CLI supplies interactive SQL and cluster operations. Python
supplies typed requests, search helpers and SQLAlchemy integration. The embedded API places
transport and durable-effect obligations on its host.

= Security & Correctness Considerations

Authentication does not make a malicious voter safe. The model assumes non-Byzantine members,
fixed membership, deterministic admitted SQL and storage that honors successful synchronization.
SOD 0003 explains the composition. Unknown execution or storage failures stop progress; the host
must not invent a deterministic SQL rejection or open an empty replacement store to continue.

= Operational Considerations

Memory is bounded at admission, protocol windows, effect queues and result construction. SQLite,
TLS and storage still consume memory outside the allocation-free consensus transition. The
qualified build pins SQLite, sqlite-vec and OpenSSL; operating-system runtime libraries remain.
Backup, restore, offline migration and coordinated certificate renewal have explicit procedures.
Dynamic resizing and rolling upgrades require separate accepted designs.

= Validation and Acceptance Gates

The release record binds the tested source, binaries and JSON evidence. Targeted tests exercise
all-owner admission, one-voter loss, restart, retries, SQL conflicts, read freshness, malformed
input and resource backpressure. Model checks and induction proofs address the abstract seams;
implementation tests connect them to code. Neither test duration nor a throughput target proves
agreement. Performance limitations are disclosed under SOD 0004.

= Alternatives Considered

A standing leader simplifies admission but changes the requested multi-master interface. The
selected rotating scheme retains direct proposals and pays for gap recovery. Independent page
replication was rejected because concurrent SQLite page changes do not define a mergeable SQL
history. A local protocol copy was rejected because it duplicates upstream reasoning and tests.
Database-wide optimistic validation was selected over row-only conflict checks because SQL
predicates, constraints and triggers can depend on rows the transaction did not directly update.

= Open Questions

No unresolved architecture question blocks the declared fixed-voter scope. Finer conflict
validation, dynamic membership and sharding remain future design subjects, not hidden current
features or new release conditions.

= Discussion and Revision Notes

*22 September:* Review found the partial upstream copy, unchecked application boundaries and
ambiguous raw-SQL retry semantics. The integration proposal selected the complete library,
atomic application watermarks, checked bindings and bounded shared vector storage. Its intent
is incorporated here; the unnumbered draft is abandoned as superseded.

*23–25 September:* The durable host, native service, fresh read markers and optimistic ORM
transactions replaced the earlier volatile and watermark-only boundary. Early `vec0` examples
do not define the durable policy. The initial “no production transport” note and planned read
fences are superseded. Historical layout measurements remain attributable in benchmark JSON;
they are not the current memory contract. Qualification and performance decisions are in SOD 0004.

= References

- SOD 0001: process and revision rules; SOD 0003: proof obligations; SOD 0004: durable host decisions.
- `specs/multimaster-refinement.typ`: protocol-to-host composition and code map.
- `specs/sql-policy.typ`, `specs/transaction-order.typ`, `specs/session-retirement.typ`.
- `docs/guides/network-service.typ`, `docs/guides/orm-transactions.typ`.
- `src/paxos.odin`, `src/durable/`, `deps/paxos-odin/`: adapter, host and complete protocol source.
