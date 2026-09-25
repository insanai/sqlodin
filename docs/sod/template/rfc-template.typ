#let sod-number = "XXXXX"
#let sod-title = "Title Goes Here"
#let sod-state = "prediscussion"
#let sod-created = "YYYY-MM-DD"
#let sod-discussion = "Draft discussion note"
#let sod-labels = ("architecture", "storage", "consensus")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Architectural Proposal"
#let sod-status = "Internal Draft"
#let sod-last-updated = "None"

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

State the problem, the proposed architectural or protocol direction, and the precise reason this document exists. Explain how this enhancement improves SQLodin's multi-master consensus, durability, SQLite execution, or developer experience.

= Status and Implementation Boundary

State what ships today, what is proposed, and what empirical evidence or formal model supports this status. A committed design is not automatically an implemented or production-certified feature. Date reviews and link specific test suites, benchmark targets, and code commits.

#table(
  columns: (1fr, 1.2fr, 2.5fr),
  inset: 6pt,
  stroke: 0.5pt + rgb("#cbd5e1"),
  table.header([*Subsystem / Component*], [*Status*], [*Scope and Verification Boundary*]),
  [Consensus Protocol], [Proposed / Implemented], [Fixed 3-voter quorum; verified via bounded model checker.],
  [Durable Host Storage], [Draft / Prototype], [Format 5 generation store; fsync barrier amortization.],
  [SQLite Application], [In Progress], [Deterministic SQL policy 9; rollback isolation and outcome ledger.],
)

= Introduction & Background

Provide the architectural background and the constraints that make this topic worth discussing now. Explain the existing limitations in SQLodin and how this proposal fits into the broader roadmap.

= Terminology and Scope

Define the technical terms used throughout the document and establish an explicit boundary between in-scope features and out-of-scope concerns.

- *Voter*: An active consensus member persisting voting promises and accepted values.
- *Slot*: A single monotonically increasing position in the global ordered log.
- *Ballot*: A unique round number `(counter, voter_id)` establishing proposal ownership.
- *Applied Prefix*: The contiguous, gap-free prefix of chosen transactions executed in SQLite.
- *Certified Image*: A durable point-in-time snapshot with a cryptographic seal and replay horizon.

#table(
  columns: (1fr, 1fr),
  inset: 6pt,
  stroke: 0.5pt + rgb("#cbd5e1"),
  table.header([*In Scope*], [*Explicitly Out of Scope*]),
  [Deterministic SQL execution order], [Arbitrary nondeterministic extensions (`random()`, clock)],
  [Fixed-membership majority quorums], [Dynamic re-enrollment or Byzantine fault tolerance],
  [Durable crash-safe recovery], [Multi-region cross-datacenter WAN sharding],
)

= Problem Statement

Describe the deficiency in the current system, performance bottleneck, or race condition. Detail the failure scenarios that motivate this proposal.

= Goals and Non-Goals

== Goals

- Guarantee strict serializability and deterministic SQL execution across all healthy voters.
- Bound memory consumption and enforce zero-allocation consensus transitions.
- Ensure crash consistency through durable sync barriers before client acknowledgements.
- Provide clear Elm-style diagnostics and actionable remediation for operator errors.

== Non-Goals

- Do not introduce asynchronous un-fenced writes that compromise durability for raw throughput.
- Do not add complex dynamic consensus reconfiguration without explicit prior proof derivations.

= High-Level Architecture & Workflow

Explain the overarching mechanism and provide a visual workflow diagram. Every proposal must make its end-to-end dataflow explicit.

#diagram-card(caption: [Figure 1: End-to-end transactional lifecycle from admission to durable commit.])[
  #scale(78%, reflow: true)[#fletcher.diagram(
    node-stroke: 0.8pt,
    spacing: (1.5cm, 1.1cm),
    node((0,0), [Client Write\ Request], fill: rgb("#e6f4f6"), stroke: 0.8pt + rgb("#166777"), corner-radius: 4pt, name: <req>),
    node((1,0), [Admission &\ Policy Gate], fill: rgb("#f1f5f9"), stroke: 0.8pt + rgb("#64748b"), corner-radius: 4pt, name: <gate>),
    node((2,0), [Rotating Ballot\ Slot Allocation], fill: rgb("#fef3c7"), stroke: 0.8pt + rgb("#d97706"), corner-radius: 4pt, name: <slot>),
    node((3,0), [Quorum Accept\ Phase (Majority)], fill: rgb("#ede9fe"), stroke: 0.8pt + rgb("#7c3aed"), corner-radius: 4pt, name: <quorum>),
    node((3,1), [Durable Journal\ Sync (`fsync`)], fill: rgb("#fee2e2"), stroke: 0.8pt + rgb("#dc2626"), corner-radius: 4pt, name: <sync>),
    node((2,1), [Contiguous Prefix\ Execution (SQLite)], fill: rgb("#ecfdf5"), stroke: 0.8pt + rgb("#059669"), corner-radius: 4pt, name: <apply>),
    node((1,1), [Outcome Ledger\ & Watermark Seal], fill: rgb("#f5f3ff"), stroke: 0.8pt + rgb("#7c3aed"), corner-radius: 4pt, name: <outcome>),
    node((0,1), [Client Ack\ & Telemetry], fill: rgb("#e6f4f6"), stroke: 0.8pt + rgb("#166777"), corner-radius: 4pt, name: <ack>),

    edge(<req>, <gate>, "->", stroke: 0.7pt + rgb("#64748b")),
    edge(<gate>, <slot>, "->", label: text(size: 7.5pt)[admit], stroke: 0.7pt + rgb("#64748b")),
    edge(<slot>, <quorum>, "->", label: text(size: 7.5pt)[propose], stroke: 0.7pt + rgb("#64748b")),
    edge(<quorum>, <sync>, "->", label: text(size: 7.5pt)[majority accept], stroke: 0.8pt + rgb("#7c3aed")),
    edge(<sync>, <apply>, "->", label: text(size: 7.5pt)[chosen prefix], stroke: 0.8pt + rgb("#059669")),
    edge(<apply>, <outcome>, "->", stroke: 0.7pt + rgb("#64748b")),
    edge(<outcome>, <ack>, "->", label: text(size: 7.5pt)[committed], stroke: 0.8pt + rgb("#166777")),
  )]
]

= Detailed Subsystem Design

Break the proposed design into concrete components, data structures, and protocol states.

#diagram-card(caption: [Figure 2: Component interaction and layer separation in the proposed subsystem.])[
  #scale(82%, reflow: true)[#cetz.canvas({
    import cetz.draw: *

    let block-layer(y, fill, strk, title, detail) = {
      rect((0, y), (11.0, y + 1.15), fill: fill, stroke: 0.8pt + strk, radius: 0.12)
      content((0.25, y + 0.82), anchor: "west", text(weight: "bold", size: 8.8pt, fill: rgb("#0f172a"))[#title])
      content((0.25, y + 0.32), anchor: "west", text(size: 6.8pt, fill: rgb("#475569"))[#detail])
    }

    block-layer(4.8, rgb("#e6f4f6"), rgb("#166777"), "Client & Service Layer (mTLS / Wire)", "Bounded frames (64 KiB), peer authentication, session management, fresh read cohorts")
    block-layer(3.6, rgb("#f1f5f9"), rgb("#64748b"), "Admission & Policy Engine", "Deterministic SQL Policy 9, statement validation, connection pools, epoch fencing")
    block-layer(2.4, rgb("#fef3c7"), rgb("#d97706"), "Paxos Consensus Core (pinned paxos-odin)", "Pure state machine, zero allocation transitions, slot ownership, majority quorums")
    block-layer(1.2, rgb("#ede9fe"), rgb("#7c3aed"), "Durable Host Storage (Format 5)", "Journal group commits, generation catalogs, certified snapshot images, replay tails")
    block-layer(0.0, rgb("#ecfdf5"), rgb("#059669"), "SQLite Engine & Extentions", "SQLite WAL, FTS5 full-text, sqlite-vec exact vector distance, outcome & watermark tables")

    // Flow arrows
    line((11.3, 5.4), (11.3, 0.6), mark: (end: ">", fill: rgb("#64748b")), stroke: 0.9pt + rgb("#64748b"))
    content((11.5, 3.0), anchor: "west", text(size: 7.2pt, fill: rgb("#64748b"))[downward requests], angle: -90deg)

    line((-0.3, 0.6), (-0.3, 5.4), mark: (end: ">", fill: rgb("#059669")), stroke: 0.9pt + rgb("#059669"))
    content((-0.5, 3.0), anchor: "west", text(size: 7.2pt, fill: rgb("#059669"))[outcomes & evidence], angle: 90deg)
  })]
]

== Subsystem Component A: Protocol State Machine

Describe the inputs, transition procedures, and output effects.

== Subsystem Component B: Durable Storage Layout

Document disk structures, binary serialization formats, and persistence boundaries.

= Invariants & Correctness Guarantees

State formal safety properties, induction hypotheses, and recovery invariants. Use callout boxes to highlight non-negotiable guarantees.

#invariant-box(title: "Log Contiguity and Deterministic Ordering")[
  Let $S$ be the sequence of chosen values across all voters. For every voter $v$ and applied watermark $W_v$, the local database state $D_v$ satisfies:
  $ D_v = "Apply"(D_0, S[1 dots W_v]) $
  No transaction at slot $s > W_v + 1$ can be applied until all intervening slots $k in [W_v + 1, s]$ are chosen and durable.
]

#decision-box(title: "Fenced Outcome Ledger")[
  Every applied SQL transaction commits its canonical Request ID, Session ID, and Execution Outcome atomically within the same SQLite transaction that applies row mutations. Retrying an identical request yields the cached outcome without re-executing side effects.
]

= Security & Operational Considerations

- *Authentication & Wire Protection*: Mutual TLS (mTLS) with pinned CA roots and certificate validity checking.
- *Failure Modes & Crash Safety*: Handling `ENOSPC`, unexpected power loss, partial writes, and network partitions.
- *Operator Procedures*: Backup commands, offline migrations, and rolling certificate updates.

#warning-box(title: "Split-Brain and Quorum Loss")[
  If fewer than $floor(N/2) + 1$ voters are online and reachable, write progress must halt immediately. The node must not attempt unilateral partition repair or accept local mutations without confirmed quorum durability.
]

= Resource Budgets & Performance Targets

Specify concrete limits for memory, disk, network, and execution latency.

#table(
  columns: (1.2fr, 1fr, 1.8fr),
  inset: 6pt,
  stroke: 0.5pt + rgb("#cbd5e1"),
  table.header([*Resource Metric*], [*Target Budget*], [*Enforcement Mechanism*]),
  [Resident Memory (RSS)], [< 512 MiB per node], [Fixed buffer pools and bounded queue capacities],
  [Client Frame Limit], [64 KiB request / 1 MiB response], [Strict wire codec rejection on oversize frames],
  [Journal Replay Tail], [< 256 MiB dirty log], [Automatic generation checkpointing and snapshot trigger],
  [Write Acknowledgement p99], [< 50 ms (local SSD)], [Group commit batching with single `fsync` amortized],
)

= Validation and Acceptance Gates

Detail the testing strategy required to accept and promote this proposal.

1. *Unit & Property Tests*: Deterministic state-machine tests exercising all edge transitions.
2. *Bounded Model Checking*: TLA+ or Odin model verifying absence of deadlocks and state equivalence.
3. *Chaos & Fault Injection*: Process crash simulation during `fsync`, disk-full errors, and network partition recovery.
4. *Performance Qualification*: Matched benchmarks against baseline implementations with identical schema and durability guarantees.

= Alternatives Considered

Summarize alternative designs that were evaluated and explain why they were rejected.

#table(
  columns: (1.2fr, 1.5fr, 1.8fr),
  inset: 6pt,
  stroke: 0.5pt + rgb("#cbd5e1"),
  table.header([*Alternative*], [*Pros*], [*Primary Reason for Rejection*]),
  [Asynchronous Replication], [High write throughput, low latency], [Risk of data loss and split-brain divergence on crash],
  [EPaxos Dynamic Ownership], [Removes leader bottleneck], [Exponential state explosion for multi-table SQL dependencies],
  [Single Raft Leader], [Simpler protocol logic], [Bottlenecks all writes through one node; does not match multi-master requirements],
)

= Open Questions & Future Milestones

- What is the empirical latency penalty under high WAN packet loss?
- Should snapshot chunks be compressed with zstd during peer catch-up?

= Discussion and Revision Notes

Record dated design discussions, review decisions, and rationale.

#decision-box(title: "Working Group Review (YYYY-MM-DD)")[
  Initial proposal presented to the SQLodin Working Group. Accepted the separation of consensus transitions from I/O workers and mandated format-5 certified snapshot seals.
]

= References

- #link("0001-sod-process.typ")[SOD 0001: The SQLodin Discussion Process]
- #link("0002-sqlodin-architecture.typ")[SOD 0002: SQLodin Architecture]
- #link("0003-mathematical-foundations-and-proofs.typ")[SOD 0003: Mathematical Foundations and Safety Proofs]
- #link("0004-production-sql-and-durable-throughput.typ")[SOD 0004: Production SQL and Durable Throughput]
- Lamport, L. "Paxos Made Simple" (2001).
- SQLite Consortium. "SQLite Write-Ahead Logging (WAL) Architecture".
