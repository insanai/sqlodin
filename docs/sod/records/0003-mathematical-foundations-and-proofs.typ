#let sod-number = "0003"
#let sod-title = "Mathematical Foundations and Safety Proofs for Multi-Master Consensus"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "Conditional safety arguments, explicit invariants and performance boundaries"
#let sod-labels = ("consensus", "proofs", "mathematics", "safety", "liveness", "invariants")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Formal Specification & Theory"
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

This record states the mathematical obligations behind SQLodin's fixed-voter design. Agreement,
durable application, read order and recovery are separate claims. Their composition depends on
explicit host assumptions. Bounded model checking and inductive proofs support selected claims;
neither is a machine-checked proof of the entire executable.

*SOD* stands for *SQLODIN Discussions* — versioned engineering records for discussion on improvement, architecture, and mathematical foundations of SQLodin.

= Status and Implementation Boundary

*Committed; reviewed 25 September 2026.* The verification suite contains 59 bounded model
configurations, including required negative controls, and 48 discharged inductive obligations.
The release record binds the evidence. The models and proofs cover their declared abstractions;
they do not verify the compiler, SQLite, TLS, filesystem or hardware. This record remains editable
under the Committed lifecycle and does not claim a completed implementation-refinement proof.

= Introduction

Models explore adverse orderings; induction establishes invariants over arbitrary abstract steps.
Both depend on choosing the right state and connecting it to code. SQLodin therefore combines
explicit invariants, executable models, negative controls and implementation fault tests.

= Terminology and Scope

Let $N$ be the fixed number of voters and $q = floor(N/2) + 1$ the majority size. A ballot is
totally ordered. Each slot has at most one value per ballot. A chosen value has durable votes
from a majority. An applied prefix contains no gaps. "Safety" excludes a bad result in every
allowed execution; "liveness" requires progress under stated scheduling and availability assumptions.

= Problem Statement

A proof of quorum intersection alone does not prove a database correct. The host can release a
vote before sync, forget accepted values, apply nondeterministic SQL, acknowledge an uncommitted
outcome or delete recovery evidence too early. The proof boundary must name each such obligation.

= Goals and Non-Goals

== Goals

- Establish agreement, durable acknowledgement, deterministic prefix application, fresh reads, retry fencing and safe recovery publication.
- State the additional assumptions required for system liveness and progress.
- Keep every abstract action traceable to a host contract and targeted regression tests.

== Non-Goals

- No claim of Byzantine safety, asynchronous wait-free progress, arbitrary SQL determinism, physical device correctness or a mechanized refinement from Odin instructions to TLA+.

= Design Overview

The argument composes four distinct layers: quorum agreement fixes values; durable effects preserve the
voting evidence; deterministic application fixes outcomes; certified recovery preserves a prefix
and its suffix. A read or retry claim then refers to that same history. Performance is a separate
measurement, not a consequence of agreement.

#diagram-card(caption: [Figure 1: Four-layer proof composition architecture from consensus core to certified recovery.])[
  #scale(78%, reflow: true)[#fletcher.diagram(
    node-stroke: 0.8pt,
    spacing: (1.5cm, 1.1cm),
    node((0,0), [Layer 1: $P_1$\ Quorum Agreement\ (POD Core)], fill: rgb("#e6f4f6"), stroke: 0.8pt + rgb("#166777"), corner-radius: 4pt, name: <p1>),
    node((1,0), [Layer 2: $P_2$\ Durable Effects\ ($R subset.eq S, H subset.eq A$)], fill: rgb("#ede9fe"), stroke: 0.8pt + rgb("#7c3aed"), corner-radius: 4pt, name: <p2>),
    node((2,0), [Layer 3: $P_3$\ Deterministic SQL\ (Policy 9 & Watermark)], fill: rgb("#ecfdf5"), stroke: 0.8pt + rgb("#059669"), corner-radius: 4pt, name: <p3>),
    node((3,0), [Layer 4: $P_4$\ Certified Recovery\ ($c <= a <= k$)], fill: rgb("#fef3c7"), stroke: 0.8pt + rgb("#d97706"), corner-radius: 4pt, name: <p4>),
    node((1.5,1), [Unified System Safety Invariant $S$\ $S = P_1 compose P_2 compose P_3 compose P_4$], fill: rgb("#f1f5f9"), stroke: 1.0pt + rgb("#182e3b"), corner-radius: 4pt, name: <safety>),

    edge(<p1>, <p2>, "->", label: text(size: 7.2pt)[stable votes], stroke: 0.7pt + rgb("#64748b")),
    edge(<p2>, <p3>, "->", label: text(size: 7.2pt)[chosen prefix], stroke: 0.7pt + rgb("#64748b")),
    edge(<p3>, <p4>, "->", label: text(size: 7.2pt)[sealed state], stroke: 0.7pt + rgb("#64748b")),
    edge(<p1>, <safety>, "->", stroke: 0.8pt + rgb("#166777")),
    edge(<p2>, <safety>, "->", stroke: 0.8pt + rgb("#7c3aed")),
    edge(<p3>, <safety>, "->", stroke: 0.8pt + rgb("#059669")),
    edge(<p4>, <safety>, "->", stroke: 0.8pt + rgb("#d97706")),
  )]
]

= Detailed Design

== Agreement and owner ballots

For majority quorums $Q_1$ and $Q_2$,
$ |Q_1 inter Q_2| >= |Q_1| + |Q_2| - N >= 2q - N > 0. $

Suppose value $v$ is chosen at ballot $b$. A higher ballot prepares through a quorum that
intersects the choosing quorum. Its witnesses report their highest accepted votes. The induction
on higher ballots requires those votes to preserve any previously chosen value. Adopting the
highest reported vote preserves that property; durable promises exclude subsequent lower-ballot
acceptance by the preparing quorum. Within one ballot, value stability prevents equivocation.
Intersection, adoption and persistent promises are all needed.

#diagram-card(caption: [Figure 2: Quorum intersection ($Q_1 inter Q_2 != emptyset$) and ballot adoption induction in a 3-voter cluster.])[
  #scale(82%, reflow: true)[#cetz.canvas({
    import cetz.draw: *

    // Circle Q1
    circle((3.0, 1.8), radius: 2.2, fill: rgb("#e6f4f6").transparentize(20%), stroke: 1.0pt + rgb("#166777"))
    content((1.8, 3.2), text(weight: "bold", size: 8.5pt, fill: rgb("#166777"))[Quorum $Q_1$ (Ballot $b$)])
    content((2.0, 1.8), text(size: 8.0pt, fill: rgb("#0f172a"))[Voter $V_1$\ (Accepts $v$ at $b$)])

    // Circle Q2
    circle((5.8, 1.8), radius: 2.2, fill: rgb("#ede9fe").transparentize(20%), stroke: 1.0pt + rgb("#7c3aed"))
    content((7.0, 3.2), text(weight: "bold", size: 8.5pt, fill: rgb("#7c3aed"))[Quorum $Q_2$ (Ballot $b' > b$)])
    content((6.8, 1.8), text(size: 8.0pt, fill: rgb("#0f172a"))[Voter $V_3$\ (Prepares $b'$)])

    // Intersection witness
    content((4.4, 2.2), text(weight: "bold", size: 8.2pt, fill: rgb("#b91c1c"))[Witness $V_2$])
    content((4.4, 1.5), text(size: 7.0pt, fill: rgb("#991b1b"))[$Q_1 inter Q_2$])
    content((4.4, 1.0), text(size: 6.8pt, fill: rgb("#475569"))[Reports $(b, v)$])

    // Summary box
    rect((0.2, -1.8), (8.6, -0.6), fill: rgb("#f8fafc"), stroke: 0.6pt + rgb("#cbd5e1"), radius: 0.1)
    content((4.4, -1.2), text(size: 7.8pt, fill: rgb("#1e293b"))[
      *Inductive Guarantee:* Since $|Q_1 inter Q_2| >= 1$, proposal $b' > b$ observes witness $V_2$ and must adopt $v$.
    ])
  })]
]

#invariant-box(title: "Quorum Intersection & Value Stability")[
  For any two majority quorums $Q_1$ and $Q_2$ over $N$ voters, $|Q_1 inter Q_2| >= 1$. If a value $v$ is chosen at ballot $b$, any subsequent proposal at ballot $b' > b$ that prepares through quorum $Q_2$ must encounter at least one voter that accepted $(b, v)$ and must adopt value $v$.
]

The initial owner ballot can omit prepare only because it is reserved for that slot's owner,
there is no valid earlier competing proposal, and restart cannot reuse the ballot for a different
value. A higher promise can reject it. Recovery then uses ordinary higher-ballot preparation.

== Durable history and application

Let $S$ be stable protocol records, $R$ released dependent effects, $K$ chosen slots, $A$ applied
slots and $H$ acknowledged slots. The durable-history abstraction requires:
$ R subset.eq S, quad H subset.eq A subset.eq K. $
Every chosen slot also has a durable voting quorum. Application commits user changes, the
request outcome and the applied watermark atomically. A crash before that boundary cannot
justify acknowledgement. A replay after it must not execute the effect twice.

#invariant-box(title: "Durable History Frontiers")[
  $ R subset.eq S quad "and" quad H subset.eq A subset.eq K $
  - $R subset.eq S$: No packet or effect is released to peers or clients before its prerequisite transitions are flushed to stable storage.
  - $H subset.eq A subset.eq K$: A request is acknowledged ($H$) only after it is applied locally ($A$), which in turn requires it to be chosen by a quorum ($K$).
]

For database state $D_0$, ordered values $v_1, dots, v_k$ and admitted deterministic transition $T$,
$ D_k = T(T(dots T(D_0, v_1), dots), v_k). $
Equal starting state and equal values give equal logical state by induction on $k$. This claim
requires a compatible schema and SQLite build, the SQL policy, and matching parameter bytes.
Consensus does not supply those premises.

Grouped application has the additional obligation $G_i = R_i$: the observable state and outcome
after request $i$ match the individual-commit reference. Deferred constraints are checked at each
request boundary. A whole-transaction rollback uses the reference fallback before acknowledgement.

== Fresh reads and optimistic transactions

A fresh read joins its cohort before marker allocation. After the marker applies, the local
prefix includes writes that must precede the read. An old marker cannot justify a new invocation.
An optimistic transaction validates the database revision at its ordered commit. An unchanged
revision preserves the preview's reads, including predicates; a changed revision rejects the
commit. This is conservative and can reject nonconflicting work.

== Recovery and retirement

Let $c$ be the certified cut, $a$ the applied cursor, $k$ the chosen frontier and $h$ the highest
acknowledged position. Prefix recovery maintains:
$ c <= a <= k, quad h <= k, quad (c,k] subset.eq "retained tail". $
The abstraction resets the cursor to the certified cut on crash and replays the suffix. Readiness
requires the recovered prefix. A real host must also validate the certificate, seal and generation.

#invariant-box(title: "Certified Image Prefix Recovery Boundary")[
  $ c <= a <= k quad "with" quad (c, k] subset.eq "retained tail" $
  On restart, the storage engine mounts the certified image at cut $c$, verifies its seal, and replays exactly the uncompacted suffix $(c, k]$ up to the chosen watermark $k$. No uncommitted transaction is applied, and no chosen transaction is omitted.
]

Publication first makes a private generation durable, then changes the durable catalog pointer.
Retirement protects the active generation and its exact predecessor. Filesystem deletion becomes
durable before ownership inventory is forgotten. These ordering rules make interrupted work
recoverable without treating unrelated directories as disposable storage.

== Identifier and retry bounds

For bounded fields, $f(t,i,s) = t dot 2^22 + i dot 2^12 + s$ is injective: division and remainders
recover each component. This does not prevent reusing the same tuple. Unique voter identities,
validated ranges and durable reservation frontiers supply the missing condition. Retry epochs
similarly require a durable fence before old outcome entries can be discarded.

= Security & Correctness Considerations

Assume non-Byzantine authenticated voters, fixed identities and membership, intact checked
messages, compatible deterministic execution, and storage that honors successful sync. Loss,
duplication, reorder, process crashes and partitions are allowed. An unknown storage or execution
error fails closed. Checksums detect accidental corruption; they do not prove a voter honest.

= Operational Considerations

Safety does not need a responsive majority. Progress does: a majority must eventually communicate,
storage operations must finish, service must be fair, and some recovery exchange must eventually
avoid continual preemption. Bounded demand prevents unbounded idle-slot chasing. It does not
prove a wall-clock deadline. One failed voter in a three-voter configuration leaves a majority;
recovery must preserve the prefix while that majority continues service.

= Validation and Acceptance Gates

`specs/multimaster-refinement.typ` maps protocol and host actions to the implementation. TLC checks
bounded state spaces and required counterexamples when protections are removed. TLAPS discharges
12 durable-history and 36 prefix-recovery obligations. The wider model suite covers ownership,
read order, retries, grouping, generation publication, retirement and bounded scheduling.

Targeted implementation checks kill processes at durability boundaries, inject storage failures,
exercise one-voter loss, and compare grouped execution with the reference. Passing models are
necessary evidence for their claims, not a substitute for those checks. A changed protocol or
host contract must revisit the affected model, proof premises and corresponding regression.
No elapsed soak duration or arbitrary database-size campaign is an additional gate.

= Alternatives Considered

#table(
  columns: (1.2fr, 1.4fr, 1.8fr),
  inset: 6pt,
  stroke: 0.5pt + rgb("#cbd5e1"),
  table.header([*Validation Approach*], [*Scope*], [*Primary Disqualification*]),
  [Soak-Only Stress Testing], [Runtime observation], [Cannot systematically exercise rare reordering and split-brain states],
  [Single Protocol Proof], [Paxos core], [Ignores filesystem sync, SQLite execution, and crash recovery boundaries],
  [End-to-End Mechanized Refinement], [Full executable stack], [Tractable for verified microkernels, intractable for SQLite C runtime],
)

= Open Questions

Mechanized refinement of the complete host and stronger liveness proofs remain possible future
work. They are disclosed limits of the current evidence, not claims already established or newly
introduced release blockers. Membership changes require their own quorum-transition argument.

= Discussion and Revision Notes

#decision-box(title: "22 September 2026: Mathematical Seam Definitions")[
  The original record contained conditional Paxos and identifier proof sketches. The review corrected the assumption that quorum intersection alone proves agreement and the assumption that an injective ID encoding prevents tuple reuse after restart.
]

#decision-box(title: "24 September 2026: Verification-First Qualification")[
  A failed cluster campaign motivated verification-first qualification. A timed-out read and a lagging returning voter were distinguished from loss of majority service. Mandatory 8-hour, 24-hour and seven-day durations were removed as approval criteria. Counterexamples became targeted regressions.
]

#decision-box(title: "25 September 2026: Scoped Release Decision")[
  Bounded ownership, durable-history, prefix-recovery and host-seam evidence now support the scoped release decision. Historical failures and tool output remain in the evidence reports.
]

= References

- SOD 0002: Architecture; SOD 0004: Host decisions.
- `specs/multimaster-refinement.typ`: The code map and refinement obligations.
- `DurableHistoryProof.tla` and `PrefixRecoveryProof.tla`: Induction proofs.
- `tools/check_formal.py` and `tools/check_proofs.py`: Formal evidence reproduction.
- `docs/releases/2026-09-25.typ`: Implementation qualification record.
