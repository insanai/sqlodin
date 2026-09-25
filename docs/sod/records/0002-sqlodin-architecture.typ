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

#import "../../shared/sod.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2"

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

*SOD* stands for *SQLODIN Discussions* — versioned engineering records for discussion on improvement, architecture, and enhancements of SQLodin.

= Status and Implementation Boundary

*Committed; reviewed 25 September 2026.* The accepted architecture is implemented and qualified
for the fixed three-voter scope in `docs/releases/2026-09-25.typ`. This is not a frozen Published
specification. Qualification does not establish arbitrary SQL support, live membership changes,
Byzantine tolerance or increasing write throughput with each added replica.

The service uses store format 5, SQL policy 9 and peer wire 3. Native CLI and Python package
versions are separate. The complete `paxos-odin` dependency is pinned at
`c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c`; SQLodin does not maintain a partial protocol copy.

#decision-box(title: "Complete Upstream Paxos Library Pin")[
  SQLodin pins the complete upstream `paxos-odin` library rather than a partial protocol fork. The consensus state machine is completely pure: zero heap allocation during state transitions, zero direct disk or network I/O, and strictly bounded memory.
]

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

- Live voter enrollment, sharding, Byzantine agreement and arbitrary extensions are outside this design.
- Replication provides availability and local read placement; every replica executes the ordered writes through one local SQLite engine.

= Design Overview

The SQLodin system architecture cleanly separates external client services, admission gating, pure consensus transitions, durable journal storage, and local SQLite application.

#diagram-card(caption: [Figure 1: SQLodin layered architecture and subsystem boundaries.])[
  #scale(82%, reflow: true)[#cetz.canvas({
    import cetz.draw: *

    let layer-rect(y, fill, strk, title, detail) = {
      rect((0, y), (11.4, y + 1.15), fill: fill, stroke: 0.8pt + strk, radius: 0.12)
      content((0.25, y + 0.82), anchor: "west", text(weight: "bold", size: 8.8pt, fill: rgb("#0f172a"))[#title])
      content((0.25, y + 0.32), anchor: "west", text(size: 6.8pt, fill: rgb("#475569"))[#detail])
    }

    layer-rect(6.0, rgb("#e6f4f6"), rgb("#166777"), "Layer 1: Client Interfaces & ORM", "Interactive CLI (`bin/sqlodin`), Python package (`sqlodin`), SQLAlchemy dialect, Embedded API")
    layer-rect(4.8, rgb("#f1f5f9"), rgb("#64748b"), "Layer 2: Transport & Security", "mTLS authentication, peer & client roles, frame codec (64 KiB frame cap), fresh read cohorts")
    layer-rect(3.6, rgb("#fef3c7"), rgb("#d97706"), "Layer 3: Admission & Policy Engine", "Deterministic SQL Policy 9, parameter bounds, epoch fencing, optimistic revision check")
    layer-rect(2.4, rgb("#ede9fe"), rgb("#7c3aed"), "Layer 4: Paxos Multi-Master Engine", "Pinned paxos-odin, rotating slot ownership, zero-allocation transition, majority quorums")
    layer-rect(1.2, rgb("#ecfdf5"), rgb("#059669"), "Layer 5: Durable Host Storage (Format 5)", "Generation catalog, group commits, single-fsync amortization, certified images, replay tails")
    layer-rect(0.0, rgb("#fdf2f8"), rgb("#db2777"), "Layer 6: SQLite Execution Engine", "SQLite WAL, FTS5 full-text search, sqlite-vec exact vector distance, outcome ledger, watermark")

    // Request & evidence flows
    line((11.7, 6.6), (11.7, 0.6), mark: (end: ">", fill: rgb("#64748b")), stroke: 0.9pt + rgb("#64748b"))
    content((11.9, 3.6), anchor: "west", text(size: 7.2pt, fill: rgb("#64748b"))[admitted proposals], angle: -90deg)

    line((-0.3, 0.6), (-0.3, 6.6), mark: (end: ">", fill: rgb("#059669")), stroke: 0.9pt + rgb("#059669"))
    content((-0.5, 3.6), anchor: "west", text(size: 7.2pt, fill: rgb("#059669"))[durability & outcomes], angle: 90deg)
  })]
]

#diagram-card(caption: [Figure 2: End-to-end transaction lifecycle from client submission to durable acknowledgement.])[
  #scale(78%, reflow: true)[#fletcher.diagram(
    node-stroke: 0.8pt,
    spacing: (1.5cm, 1.1cm),
    node((0,0), [Client Write\ Request], fill: rgb("#e6f4f6"), stroke: 0.8pt + rgb("#166777"), corner-radius: 4pt, name: <client>),
    node((1,0), [Admission &\ Policy Gate], fill: rgb("#f1f5f9"), stroke: 0.8pt + rgb("#64748b"), corner-radius: 4pt, name: <admit>),
    node((2,0), [Rotating Ballot\ Slot Allocation], fill: rgb("#fef3c7"), stroke: 0.8pt + rgb("#d97706"), corner-radius: 4pt, name: <slot>),
    node((3,0), [Quorum Accept\ (Majority Durable)], fill: rgb("#ede9fe"), stroke: 0.8pt + rgb("#7c3aed"), corner-radius: 4pt, name: <quorum>),
    node((3,1), [Contiguous Prefix\ Formation], fill: rgb("#fee2e2"), stroke: 0.8pt + rgb("#dc2626"), corner-radius: 4pt, name: <prefix>),
    node((2,1), [SQLite Apply\ (Engine + WAL)], fill: rgb("#ecfdf5"), stroke: 0.8pt + rgb("#059669"), corner-radius: 4pt, name: <sqlite>),
    node((1,1), [Outcome Ledger\ & Watermark Commit], fill: rgb("#f5f3ff"), stroke: 0.8pt + rgb("#7c3aed"), corner-radius: 4pt, name: <outcome>),
    node((0,1), [Durable Client\ Acknowledgement], fill: rgb("#e6f4f6"), stroke: 0.8pt + rgb("#166777"), corner-radius: 4pt, name: <ack>),

    edge(<client>, <admit>, "->", stroke: 0.7pt + rgb("#64748b")),
    edge(<admit>, <slot>, "->", label: text(size: 7.5pt)[valid SQL], stroke: 0.7pt + rgb("#64748b")),
    edge(<slot>, <quorum>, "->", label: text(size: 7.5pt)[ballot $b_0$], stroke: 0.8pt + rgb("#7c3aed")),
    edge(<quorum>, <prefix>, "->", label: text(size: 7.5pt)[chosen], stroke: 0.8pt + rgb("#dc2626")),
    edge(<prefix>, <sqlite>, "->", label: text(size: 7.5pt)[gap-free], stroke: 0.8pt + rgb("#059669")),
    edge(<sqlite>, <outcome>, "->", stroke: 0.7pt + rgb("#64748b")),
    edge(<outcome>, <ack>, "->", label: text(size: 7.5pt)[committed], stroke: 0.8pt + rgb("#166777")),
  )]
]

The upstream core emits effects into caller-owned storage. It does not perform disk or network
I/O. The SQLodin host owns persistence, transport, application and responses. Explicit ownership
keeps borrowed buffers from outliving their input and prevents workers from mutating protocol state.

= Detailed Design

== Rotating ownership and recovery

For voters numbered 1 through $N$, slot ownership is defined by:
$ "owner"(s) = ((s - 1) mod N) + 1. $
The reserved owner ballot may begin with Accept. A healthy, uncontested slot can be chosen in
one quorum exchange, including its durable voting barriers. This is not end-to-end SQL latency.

#diagram-card(caption: [Figure 3: Multi-master rotating slot partitioning across 3 voters with recovery transition.])[
  #scale(82%, reflow: true)[#cetz.canvas({
    import cetz.draw: *

    let slot-box(x, y, num, voter, state, fill, strk) = {
      rect((x, y), (x + 1.5, y + 1.1), fill: fill, stroke: 0.8pt + strk, radius: 0.1)
      content((x + 0.75, y + 0.75), text(weight: "bold", size: 8.5pt, fill: rgb("#0f172a"))[Slot #num])
      content((x + 0.75, y + 0.42), text(size: 7.0pt, fill: strk)[Owner: $V_#voter$])
      content((x + 0.75, y + 0.16), text(size: 6.2pt, fill: rgb("#64748b"))[#state])
    }

    // Row 1: Fast uncontested path
    content((0, 2.3), anchor: "west", text(weight: "bold", size: 8.5pt, fill: rgb("#166777"))[Normal Rotating Path (Owner Ballot $b_0$, 1 Round):])
    slot-box(0.0, 0.8, 1, 1, "Chosen (Fast)", rgb("#ecfdf5"), rgb("#059669"))
    slot-box(1.8, 0.8, 2, 2, "Chosen (Fast)", rgb("#ecfdf5"), rgb("#059669"))
    slot-box(3.6, 0.8, 3, 3, "Chosen (Fast)", rgb("#ecfdf5"), rgb("#059669"))
    slot-box(5.4, 0.8, 4, 1, "Chosen (Fast)", rgb("#ecfdf5"), rgb("#059669"))
    slot-box(7.2, 0.8, 5, 2, "Stalled...", rgb("#fef3c7"), rgb("#d97706"))
    slot-box(9.0, 0.8, 6, 3, "Waiting Slot 5", rgb("#f1f5f9"), rgb("#64748b"))

    // Transition arrow
    line((7.95, 0.7), (7.95, -0.3), mark: (end: ">", fill: rgb("#7c3aed")), stroke: 0.9pt + rgb("#7c3aed"))
    content((8.15, 0.2), anchor: "west", text(size: 7.2pt, fill: rgb("#7c3aed"))[Higher ballot recovery ($b > b_0$)])

    // Recovery explanation box
    rect((0.2, -1.7), (10.6, -0.5), fill: rgb("#f5f3ff"), stroke: 0.7pt + rgb("#7c3aed"), radius: 0.12)
    content((5.4, -1.1), text(size: 7.6pt, fill: rgb("#5b21b6"))[
      *Recovery Invariant:* Higher ballot prepares through majority quorum $Q$, adopts highest accepted value, or fills with No-Op if unchosen.
    ])
  })]
]

Idle positions are closed with quorum-chosen no-ops. A stalled owner can be recovered through a
higher-ballot prepare. Recovery must adopt the highest accepted value reported by that quorum;
it may use a no-op only when the protocol permits it. Bounded demand frontiers and fair recovery
service prevent idle slot selection from manufacturing an endless stream of new work.

== Logical transactions and SQL Policy 9

Replicas agree on SQL and typed parameters, not independently modified SQLite pages. The durable
SQL policy admits a constrained deterministic subset. A transaction carries a session, sequence,
epoch and canonical request identity. The outcome and applied watermark commit with the data.
Reusing an identity for different content is rejected. Retirement advances a durable epoch fence;
old requests cannot silently become new requests after outcome rows are reclaimed.

#invariant-box(title: "Deterministic Execution and Rollback Isolation")[
  All replicas execute identical logical mutations through SQLite with Policy 9 constraints (disallowing non-deterministic functions such as `random()`, system clocks, or unversioned triggers). Every transaction commits its outcome atomically with the applied watermark.
]

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

#warning-box(title: "Non-Byzantine and Failure Domain Assumptions")[
  Authentication does not make a malicious voter safe. The model assumes non-Byzantine members,
  fixed membership, deterministic admitted SQL and storage that honors successful synchronization.
  SOD 0003 explains the composition. Unknown execution or storage failures stop progress; the host
  must not invent a deterministic SQL rejection or open an empty replacement store to continue.
]

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

#table(
  columns: (1.2fr, 1.5fr, 1.8fr),
  inset: 6pt,
  stroke: 0.5pt + rgb("#cbd5e1"),
  table.header([*Alternative*], [*Pros*], [*Reason for Rejection*]),
  [Standing Leader (Raft)], [Simple admission without gaps], [Bottlenecks all writes at one node; does not fulfill multi-master design],
  [Independent Page Replication], [Bypasses SQL parser], [Concurrent SQLite page writes diverge without a mergeable history],
  [Local Paxos Protocol Fork], [Tailored local types], [Duplicates upstream reasoning, proofs, and maintenance burden],
  [Row-Level Optimistic Locks], [Higher write concurrency], [Fails to detect predicate, constraint, and table-wide trigger conflicts],
)

= Open Questions

No unresolved architecture question blocks the declared fixed-voter scope. Finer conflict
validation, dynamic membership and sharding remain future design subjects, not hidden current
features or new release conditions.

= Discussion and Revision Notes

#decision-box(title: "22 September 2026: Upstream Library and Atomic Application")[
  Review found the partial upstream copy, unchecked application boundaries and ambiguous raw-SQL retry semantics. The integration proposal selected the complete library, atomic application watermarks, checked bindings and bounded shared vector storage.
]

#decision-box(title: "23–25 September 2026: Durable Host & Native Service")[
  The durable host, native service, fresh read markers and optimistic ORM transactions replaced the earlier volatile and watermark-only boundary. Replaced text ASCII sketches with formal CeTZ layer diagrams and Fletcher execution lifecycles.
]

#decision-box(title: "25 September 2026: Revision under SOD 0005 (in discussion)")[
  The service's fresh reads now cross a quorum frontier instead of a proposed marker, and one journal barrier covers each service turn. The separated application database is a WAL NORMAL cache of the FULL journal. Owners' round-zero no-ops, and with three voters values this voter has also voted for, are learned without waiting for the owner's Commit. The read-order contract above is unchanged; see SOD 0005 for proofs, models and measurements.
]

= References

- SOD 0001: The SQLodin Discussion Process; SOD 0003: Proof obligations; SOD 0004: Durable host decisions.
- `specs/multimaster-refinement.typ`: Protocol-to-host composition and code map.
- `specs/sql-policy.typ`, `specs/transaction-order.typ`, `specs/session-retirement.typ`.
- `docs/guides/network-service.typ`, `docs/guides/orm-transactions.typ`.
- `src/paxos.odin`, `src/durable/`, `deps/paxos-odin/`: Adapter, host and complete protocol source.
