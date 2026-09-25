#let sod-number = "XXXXX"
#let sod-title = "Pinned Upstream Paxos and SQLite Application Correctness"
#let sod-state = "prediscussion"
#let sod-created = "2026-09-22"
#let sod-discussion = "Implementation review"
#let sod-labels = ("consensus", "storage", "performance", "integration")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Engineering Discussion"
#let sod-status = "Pre-Discussion Draft"
#let sod-last-updated = "2026-09-25"

#import "../../shared/sod.typ": *

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

This specification proposes importing the complete pinned `paxos-odin` library as a Git submodule, replacing SQLodin's partial consensus fork with a verified, thin host adapter. It defines the atomic SQLite application boundary, the transactional high-watermark contract, statement cache ergonomics, and bounded vector memory budgets required for deterministic multi-master replication.

*SOD* stands for *SQLODIN Discussions* — versioned engineering records for discussion on improvement, architecture, and enhancements of SQLodin.

= Scope and Implementation Boundary

Import the complete `paxos-odin` repository as a Git submodule at `a3e1fd78ec8f0429e5024710189ef77fc31961af`. Remove SQLodin's partial protocol copy. A thin adapter forces rotating ownership and passes initialization, restoration, stepping, proposals, and ticks to upstream. Consensus errors retain upstream types and explanations; SQLite errors remain local. Changes to the pin require both libraries' test suites to pass.

#table(
  columns: (1.5fr, 1.2fr, 1.2fr, 2.1fr),
  stroke: 0.5pt + rgb("#cbd5e1"),
  fill: (col, row) => if row == 0 { rgb("#f1f5f9") } else { none },
  [#strong("Component")], [#strong("Target Area")], [#strong("Boundary")], [#strong("Acceptance Gate")],
  [Upstream Paxos Pin], [Consensus Core], [`paxos-odin` Submodule], [Passing upstream tests & bit-exact pin],
  [Host Adapter], [Integration], [`internal/engine`], [Rotating ownership & tick routing],
  [SQLite Watermark], [Storage & Engine], [`_sqlodin_state.applied`], [Atomic rollbacks & contiguous applied prefix],
  [Statement Cache], [Execution], [`internal/engine`], [8-slot bounded DML cache, zero re-parse],
  [Vector Payload], [Data Layout], [`Mutation` struct], [Bounded 384 float budget per slot],
)

#v(0.6em)

#diagram-card(caption: [Upstream Paxos Engine & SQLite Host Adapter Integration Architecture])[
  #diagram(
    spacing: (15mm, 10mm),
    node-stroke: 0.8pt,
    edge-stroke: 0.75pt,

    // Client / SQL layer
    node((0, 0), [Client Application\ (SQL Statements / Mutex)], fill: rgb("#f1f5f9"), stroke: 0.8pt + rgb("#475569"), corner-radius: 4pt, name: <client>),

    // Host Adapter
    node((1, 0), [SQLodin Host Adapter\ • Statement Cache (8 DML)\ • Snowflake ID Generator\ • Watermark Guard], fill: rgb("#e6f4f6"), stroke: 0.8pt + rgb("#166777"), corner-radius: 4pt, name: <adapter>),

    // Pinned Upstream Paxos
    node((2, 0), [Pinned `paxos-odin` Core\ (`a3e1fd78ec8f`)\ • Rotating Ownership\ • Quorum Agreement\ • Decided Slot Stream], fill: rgb("#ede9fe"), stroke: 0.8pt + rgb("#7c3aed"), corner-radius: 4pt, name: <paxos>),

    // SQLite Storage Engine
    node((1, 1), [SQLite Storage Engine\ • Table `_sqlodin_state`\ • Atomic Applied Watermark\ • User Tables & BLOBs], fill: rgb("#ecfdf5"), stroke: 0.8pt + rgb("#059669"), corner-radius: 4pt, name: <sqlite>),

    // Durable Consensus Journal
    node((2, 1), [Paxos Journal & WAL\ • Promises & Ballots\ • Replicated State History], fill: rgb("#fef3c7"), stroke: 0.8pt + rgb("#d97706"), corner-radius: 4pt, name: <wal>),

    // Edges
    edge(<client>, <adapter>, "->", [Execute SQL], label-side: left),
    edge(<adapter>, <paxos>, "->", [Propose Slot\ Tick / Step], label-side: left),
    edge(<paxos>, <adapter>, "->", [Decided\ Batch], label-side: right),
    edge(<adapter>, <sqlite>, "->", [Atomic Commit\ (Batch + Watermark)], label-side: left),
    edge(<paxos>, <wal>, "->", [Fsync Log], label-side: right),
  )
]

= Application Transactions and Atomic Watermarking

Apply contiguous decided batches within an explicit SQLite transaction (`BEGIN IMMEDIATE`). Roll back on any failure; commit user data and `_sqlodin_state.applied` together. Restore this watermark on opening the database. Reject gaps, unknown mutation kinds, and malformed lengths. Replayed applied slots are ignored idempotently. Use `FULL` synchronization for file-backed SQLite. Persist consensus promises and votes separately.

#diagram-card(caption: [Atomic Application Transaction & Applied Watermark Sequence])[
  #cetz.canvas({
    import cetz.draw: *

    let box-w = 3.6
    let box-h = 1.0

    // Step 1: Ingest Decided Batch
    rect((0, 2.2), (box-w, 2.2 + box-h), fill: rgb("#f1f5f9"), stroke: 0.8pt + rgb("#64748b"), radius: 0.12)
    content((box-w/2, 2.2 + box-h*0.65), text(weight: "bold", size: 8.5pt, fill: rgb("#0f172a"))[1. Decided Batch Ingest])
    content((box-w/2, 2.2 + box-h*0.3), text(size: 7pt, fill: rgb("#475569"))[Contiguous Slots $[s, s+k]$])

    // Step 2: Begin Immediate
    rect((4.2, 2.2), (4.2 + box-w, 2.2 + box-h), fill: rgb("#e6f4f6"), stroke: 0.8pt + rgb("#166777"), radius: 0.12)
    content((4.2 + box-w/2, 2.2 + box-h*0.65), text(weight: "bold", size: 8.5pt, fill: rgb("#0f172a"))[2. BEGIN IMMEDIATE])
    content((4.2 + box-w/2, 2.2 + box-h*0.3), text(size: 7pt, fill: rgb("#475569"))[Exclusive SQLite Write Lock])

    // Step 3: Apply User Mutations
    rect((8.4, 2.2), (8.4 + box-w, 2.2 + box-h), fill: rgb("#ede9fe"), stroke: 0.8pt + rgb("#7c3aed"), radius: 0.12)
    content((8.4 + box-w/2, 2.2 + box-h*0.65), text(weight: "bold", size: 8.5pt, fill: rgb("#0f172a"))[3. Execute DML Mutex])
    content((8.4 + box-w/2, 2.2 + box-h*0.3), text(size: 7pt, fill: rgb("#475569"))[Bind Cached Statements])

    // Step 4: Advance Watermark
    rect((2.1, 0.4), (2.1 + box-w, 0.4 + box-h), fill: rgb("#ecfdf5"), stroke: 0.8pt + rgb("#059669"), radius: 0.12)
    content((2.1 + box-w/2, 0.4 + box-h*0.65), text(weight: "bold", size: 8.5pt, fill: rgb("#0f172a"))[4. Advance Watermark])
    content((2.1 + box-w/2, 0.4 + box-h*0.3), text(size: 7pt, fill: rgb("#475569"))[`applied = s+k` in `_sqlodin_state`])

    // Step 5: Commit & Fsync
    rect((6.3, 0.4), (6.3 + box-w, 0.4 + box-h), fill: rgb("#fef3c7"), stroke: 0.8pt + rgb("#d97706"), radius: 0.12)
    content((6.3 + box-w/2, 0.4 + box-h*0.65), text(weight: "bold", size: 8.5pt, fill: rgb("#0f172a"))[5. COMMIT TRANSACTION])
    content((6.3 + box-w/2, 0.4 + box-h*0.3), text(size: 7pt, fill: rgb("#475569"))[Synchronous FULL Fsync])

    // Arrows
    line((box-w, 2.7), (4.2, 2.7), mark: (end: ">", fill: rgb("#64748b")), stroke: 0.8pt + rgb("#64748b"))
    line((4.2 + box-w, 2.7), (8.4, 2.7), mark: (end: ">", fill: rgb("#166777")), stroke: 0.8pt + rgb("#166777"))
    line((8.4 + box-w/2, 2.2), (8.4 + box-w/2, 1.8), (2.1 + box-w, 0.9), mark: (end: ">", fill: rgb("#7c3aed")), stroke: 0.8pt + rgb("#7c3aed"))
    line((2.1 + box-w, 0.9), (6.3, 0.9), mark: (end: ">", fill: rgb("#059669")), stroke: 0.8pt + rgb("#059669"))
  })
]

#invariant-box(title: "Invariant: Atomic Application Watermark")[
  Let $S = (m_1, m_2, dots, m_k)$ be a contiguous sequence of decided mutations spanning slots $[s, s+k-1]$. The host guarantees:
  $ "Applied"(S) and (text("_sqlodin_state.applied") = s+k-1) $
  are written within an atomic SQLite transaction. If crash or power failure occurs before commit completes, SQLite rollback restores the database to slot $s-1$, preventing dual-write state divergence.
]

Cache eight DML statements per engine. Borrow immutable text/vector payloads with explicit byte lengths; reset statements and clear bindings before returning. Match cached statements directly by bounded table/column metadata so a hit does not format SQL. Check bind, step, begin, and commit results. Implement updates and vector BLOB binding rather than silently ignoring them.

Raw SQL cannot control transactions, attach databases, issue state-changing PRAGMAs, or alter the internal watermark. The host still guarantees deterministic statements and schema behavior. A failed decided mutation blocks application. No automatic skipping or unvalidated exactly-once guarantee is introduced.

= Memory and Identifier Bounds

Use one shared fixed vector payload per mutation instead of reserving 384 floats in each column. The default total budget is 384 floats, configurable at compile time. This changes Mutation's in-memory layout; native struct bytes are not a versioned wire/storage format. A production codec must define its own stable format and bounds checks. Text, column names, and vector offsets are validated before slicing.

#invariant-box(title: "Invariant: Monotonic Snowflake Frontiers")[
  Engine node IDs generate monotonic 64-bit timestamps. On sequence counter overflow or local clock backward step:
  $ T_"logical" = max(T_"logical" + 1, T_"wall") $
  Out-of-range IDs and rollbacks beyond safe thresholds fail closed. A host must persist its issued logical frontier before restarting and reusing its identity.
]

= Validation and Acceptance Gates

Use the pinned upstream tests, SQLodin regression tests, and a bounded network simulator with copied payloads, drops, duplication, reorder, and ledger restoration. Compare actual applied data and decisions, not the number of result rows returned by `SELECT count(*)`. Example and benchmark errors are fatal.

Measure only successful replicated SQLite writes. Include every replica's SQL application and message payload copies. Report a matched single-leader workload, timing boundaries, payload/node sizes, and sample ranges.

= Remaining Production Work

The fixed-membership durable journal/codec, historical range service, and Linux disk-backed benchmarks are now active in the test harnesses. A production network service, certified snapshots, the complete deterministic-SQL contract, and a matched distributed service benchmark remain ongoing work. Format-2 transaction outcomes, bounded session deduplication, and a function policy are implemented.

= Linux Measurement Follow-up

The historical memory report built SQLite 3.50.4 and sqlite-vec 0.1.9 from verified source/header hashes on Linux. The current durable Linux build pins SQLite 3.51.3. Keep native artifacts under `build/native`, separately from the macOS archive. Run the full verification suite, then seven shuffled rounds of reference, shape-cache-only, and optimized builds, each comparing single-leader, multi-master, and local SQLite application. Record raw samples, latency percentiles, per-child CPU/RSS, compiler flags, system metadata, and source/binary digests as JSON.

These measurements are memory-only and single-threaded. They do not measure durable service, network, WAN, or multi-core performance, and cannot establish comparative service performance.

= Discussion Notes

#decision-box(title: "22 September 2026: Whole Upstream Paxos Submodule Integration")[
  Adopted the complete pinned `paxos-odin` upstream library as a submodule instead of maintaining a diverging protocol fork. Enforced explicit rotating ownership and strict type isolation.
]

#decision-box(title: "25 September 2026: Pre-Discussion Review & Architecture Realization")[
  Maintained as an active pre-discussion draft (SOD XXXXX). Integrated architectural diagrams, atomic watermark validation criteria, and invariant specifications for team review.
]

= References

- #link("0001-sod-process.typ")[SOD 0001: The SQLodin Discussion Process]
- #link("0002-sqlodin-architecture.typ")[SOD 0002: Architecture and Integration]
- #link("0003-mathematical-foundations-and-proofs.typ")[SOD 0003: Proof Obligations and Mathematical Foundations]
- #link("0004-production-sql-and-durable-throughput.typ")[SOD 0004: Durable Host and Qualification]
