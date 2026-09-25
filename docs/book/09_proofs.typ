#import "theme.typ": callout
#import "figures.typ": steps, recovery-strip
#let formal = json("../../benchmarks/results/verification-20260924/formal-final-binding.json")
#assert(formal.complete and formal.missing.len() == 0)
= Formal verification
<proofs>

The previous chapters separated agreement, persistence, application order, reads and
recovery. That separation also structures verification. A small model can expose a
missing guard. An inductive proof can establish a property for arbitrary history lengths.
A code-level test can check that an actual crash follows the intended storage boundary.
None of these alone supplies all the others.

The retained evidence contains #formal.cases.len() model configurations, including
required negative controls, and 48 discharged inductive proof obligations. Those counts
identify completed work; they are not a measure of how much of the executable is proved.
The #link("../../specs/multimaster-refinement.typ")[composition argument] records the
connections between the claims and their implementation.

== Begin with a state and an invariant

A specification names the state variables and allowed transitions. An invariant $I$
is a property that every reachable state must satisfy. Induction has two obligations:

$ "Init"(s) => I(s), $
$ I(s) and "Next"(s,s') => I(s'). $

The first proves the initial state is safe. The second proves that each allowed step
preserves safety. Together they cover any finite sequence of steps, not merely a long
test run. A proof that omits a possible implementation transition does not cover that
transition; the mapping from code to model is therefore part of the argument.

#figure(steps((
  ([Initial state], [Establish the invariant before any operation.]),
  ([One step], [Show every permitted action preserves it.]),
  ([Any prefix], [Induction extends the result to arbitrary finite histories.]),
)), caption: [The number of executed test hours does not appear in an inductive safety argument.])

== Durable-history induction

`DurableHistoryProof.tla` distinguishes pending evidence, stable evidence, released
evidence, chosen slots, applied slots and acknowledged slots. The invariant includes:

$ "released" subset.eq "stable", $
$ "acknowledged" subset.eq "applied" subset.eq "chosen". $

It also requires every chosen slot to have a quorum whose evidence is stable. Here
released/stable elements identify a slot and voter; applied/chosen elements identify
slots. The different sets should not be confused with identical physical files.

The actions enforce the chain. `Stage` adds private evidence. `Sync` makes it stable.
`Send` requires stable evidence. `Choose` requires a quorum of released evidence.
`Apply` requires choice; `Ack` requires application. `Crash` removes pending evidence
but not stable facts. Checking each action preserves the invariant gives the induction.
TLAPS discharged 12 obligations for this abstraction.

This proof assumes one immutable value per chosen slot, correct quorum evidence and
atomic application. It does not establish Paxos agreement or SQL determinism itself.
Those premises come from @consensus, @storage and their model/code correspondence.

These proofs concern the abstractions, not the complete executable, compiler, OS or device.

#pagebreak()
== Prefix recovery with unbounded slots

`PrefixRecoveryProof.tla` adds the part a set of chosen slots cannot express: a
contiguous application prefix. Let $c$ be the certified image cut, $a$ the current
replay/application cursor, $k$ the durable committed prefix, $h$ the acknowledged
prefix, and $T$ the retained suffix. Its invariant includes

$ 0 <= c <= a <= k, quad 0 <= h <= k, $
$ (c,k] subset.eq T, quad "ready" => a = k. $

The interval contains integer slot numbers. Every slot through $k$ is chosen, and
retained tail entries are chosen. After a crash, the cursor returns to $c$ and readiness
is false. Replay advances it one slot at a time through retained evidence. Opening the
service requires $a=k$.

#figure(recovery-strip(), caption: [Trimming below a certified cut must leave the whole replay suffix above it.])

Publishing a new cut never moves beyond the committed prefix. Trimming removes only
entries covered by the cut. Each action preserves the inequalities and suffix inclusion.
TLAPS discharged 36 obligations for arbitrary natural-numbered slots.

The image is assumed to represent exactly its certified prefix. This proof does not
inspect SQLite pages or authenticate receipts. Snapshot identity, logical verification,
file durability and generation publication discharge those separate implementation
obligations. Keeping the premise explicit prevents a short proof from appearing to
prove more than it does.

== Finite models explore the dangerous interleavings

TLC exhausts reachable states within a model's declared bounds. Positive cases must
finish without the checked violation. A timeout is not success. Each negative control
removes a specific condition and must produce the expected counterexample, rather
than merely fail to parse or run out of resources.

#table(columns: (1.05fr, 1.55fr, 1.25fr),
  table.header([Model], [Property checked], [Negative control]),
  [`OwnedSlot`], [One value despite ownership and revocation ballots.], [Lose durable votes.],
  [`RotatingWindow`], [Prefix progress and safe ring reuse under fair actions.], [Remove skip, recovery or release; reuse a held slot.],
  [`RecoveryProgress`], [Repair advances through bounded history chunks.], [Remove probes or stop after one chunk.],
  [`DurableEffects`], [Evidence is durable before it is sent.], [Release before the durability gate.],
  [`ReadFence`], [Fresh marker is applied before the snapshot.], [Reuse a marker or read early.],
  [`ReadCohort`], [Every shared read belongs to its fresh barrier.], [Admit late readers or cancel another waiter's barrier.],
  [`SessionRetirement`], [Reclaimed sessions cannot replay old writes.], [Lose or omit the epoch fence.],
)

The rotating-window model explores independent delivery, learning and applied frontiers.
Fairness represents eventual service and successful retransmission. It does not prove a
millisecond deadline or progress during endless contention. The read models assume an
immutable ordered log; they examine the barrier boundary, not the entire network protocol.

#table(columns: (1.05fr, 1.55fr, 1.25fr),
  table.header([Model], [Property checked], [Negative control]),
  [`SnapshotIdentity`], [A certificate has a distinct matching durable quorum.], [Mix keys, count duplicates or issue volatile receipts.],
  [`ManifestDurability`], [Successful file publication survives modeled crashes.], [Omit file or directory sync.],
  [`SnapshotPublication`], [Trimming follows recoverable publication.], [Trim without its guard.],
  [`GenerationCatalog`], [Published state preserves promises, suffix and reserved IDs.], [Publish early or lose local facts.],
  [`GenerationRetirement`], [Delete only eligible owned generations.], [Delete current, predecessor or unowned paths.],
  [`ImageRetirement`], [Keep active and certificate-required images.], [Drop predecessor or successor protection.],
  [`RestoredGenesis`], [A new namespace opens one durable initial state.], [Reuse old identity, mix images or open early.],
)

== Connect the model to running code

A refinement map says which implementation event represents a model step. For example,
a successful FULL journal commit advances stable evidence; releasing the owned message
queue represents sending; the catalog commit selects the published generation. A failed
or incomplete operation must not be treated as that successful abstract step.

Implementation tests exercise these boundaries. The final candidate passes 43 targeted
SIGKILL cases for generation publication, retirement, backup and restore. Other retained
campaigns inject ENOSPC, actual short writes and synchronization errors at exact WAL paths.
They check that the affected voter does not acknowledge fabricated success, that survivors
resolve the original identity, and that repaired state converges.

Transaction-history tests go beyond final row counts. They record invocation and response
times, predicates and outcomes. A separate bounded reference model searches for a serial
execution respecting every real-time edge. Negative histories include stale predicates
and write skew. A final balance alone could miss both errors.

The final three-instance campaign also removes each voter in turn, writes through both
survivors, rejects minority reads/writes, rejoins the missing voter and restarts the whole
group. These tests connect protocol, storage and service code under actual process failure.
They do not turn a finite experiment into a universal liveness theorem.

== Reproduce the evidence

```sh
python3 tools/check_formal.py --jar /path/to/tla2tools.jar \
  --output build/formal/new-model-run.json
python3 tools/check_proofs.py --tools build/proof-tools \
  --output build/formal/new-proof-run.json
```

The runners check pinned tool hashes and require fresh evidence paths. The source-bound
#link("../../benchmarks/results/verification-20260924/formal-final-binding.json")[formal manifest]
reuses only unchanged successful specifications. It is labelled as evidence reuse, not a
new TLC or TLAPS execution. Exact commands and historical failures remain in the reports.

