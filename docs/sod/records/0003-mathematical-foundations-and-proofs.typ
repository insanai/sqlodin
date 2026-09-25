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

This record states the mathematical obligations behind SQLodin's fixed-voter design. Agreement,
durable application, read order and recovery are separate claims. Their composition depends on
explicit host assumptions. Bounded model checking and inductive proofs support selected claims;
neither is a machine-checked proof of the entire executable.

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
from a majority. An applied prefix contains no gaps. “Safety” excludes a bad result in every
allowed execution; “liveness” requires progress under stated scheduling and availability assumptions.

= Problem Statement

A proof of quorum intersection alone does not prove a database correct. The host can release a
vote before sync, forget accepted values, apply nondeterministic SQL, acknowledge an uncommitted
outcome or delete recovery evidence too early. The proof boundary must name each such obligation.

= Goals and Non-Goals

== Goals

Establish agreement, durable acknowledgement, deterministic prefix application, fresh reads,
retry fencing and safe recovery publication. State the additional assumptions for progress.
Keep every abstract action traceable to a host contract and targeted tests.

== Non-Goals

No claim of Byzantine safety, asynchronous wait-free progress, arbitrary SQL determinism,
physical device correctness or a mechanized refinement from Odin instructions to TLA+.

= Design Overview

The argument composes four layers: quorum agreement fixes values; durable effects preserve the
voting evidence; deterministic application fixes outcomes; certified recovery preserves a prefix
and its suffix. A read or retry claim then refers to that same history. Performance is a separate
measurement, not a consequence of agreement.

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

The initial owner ballot can omit prepare only because it is reserved for that slot's owner,
there is no valid earlier competing proposal, and restart cannot reuse the ballot for a different
value. A higher promise can reject it. Recovery then uses ordinary higher-ballot preparation.

== Durable history and application

Let $S$ be stable protocol records, $R$ released dependent effects, $K$ chosen slots, $A$ applied
slots and $H$ acknowledged slots. The durable-history abstraction requires
$ R subset.eq S, quad H subset.eq A subset.eq K. $
Every chosen slot also has a durable voting quorum. Application commits user changes, the
request outcome and the applied watermark atomically. A crash before that boundary cannot
justify acknowledgement. A replay after it must not execute the effect twice.

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
acknowledged position. Prefix recovery maintains
$ c <= a <= k, quad h <= k, quad (c,k] subset.eq "retained tail". $
The abstraction resets the cursor to the certified cut on crash and replays the suffix. Readiness
requires the recovered prefix. A real host must also validate the certificate, seal and generation.

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

Soak-only qualification was rejected because it cannot systematically enumerate rare orderings.
A single protocol proof was rejected as a database-wide argument because SQL and filesystem
boundaries remain outside it. Full executable refinement would give stronger assurance but is
not available; the accepted approach states its compositional assumptions and tests their seams.
Bounded checks alone cannot establish unbounded progress, so fairness assumptions remain explicit.

= Open Questions

Mechanized refinement of the complete host and stronger liveness proofs remain possible future
work. They are disclosed limits of the current evidence, not claims already established or newly
introduced release blockers. Membership changes require their own quorum-transition argument.

= Discussion and Revision Notes

*22 September:* The original record contained conditional Paxos and identifier proof sketches.
The review corrected the assumption that quorum intersection alone proves agreement and the
assumption that an injective ID encoding prevents tuple reuse after restart.

*24 September:* A failed cluster campaign motivated verification-first qualification. A timed-out
read and a lagging returning voter were distinguished from loss of majority service. Mandatory
8-hour, 24-hour and seven-day durations were removed as approval criteria. Counterexamples were
to become targeted regressions rather than another request for a longer soak.

*25 September:* Bounded ownership, durable-history, prefix-recovery and host-seam evidence now
support the scoped release decision. Earlier “proofs remain work” notes are superseded. Historical
failures and tool output remain in the evidence reports; successful later runs do not rewrite them.

*Earlier model boundaries.* OwnedSlot originally checked one slot with bounded ballots, not multi-slot progress.
RecoveryProgress assumed a stable authenticated donor and fair service; convergence did not imply
a deadline. These limits motivated the later ownership and composition work.

ReadFence exposed stale marker reuse and premature snapshots. The regression
`test_stale_voter_cannot_reuse_read_fence_after_remote_write` connects the counterexample to host
behavior. SnapshotIdentity distinguished certificate matching from image durability;
ManifestDurability distinguished file sync from directory sync. Generation publication had to
satisfy both before retirement. Current reproduction instructions remain in `specs/README.md`.

= References

SOD 0002 defines the architecture; SOD 0004 records the host decisions. The code map is in
`specs/multimaster-refinement.typ`. The SQL, grouping, read, generation and retirement contracts
are indexed in `specs/README.md`. `DurableHistoryProof.tla` and `PrefixRecoveryProof.tla` contain
the induction proofs. `tools/check_formal.py` and `tools/check_proofs.py` reproduce formal evidence;
`docs/releases/2026-09-25.typ` binds implementation qualification.
