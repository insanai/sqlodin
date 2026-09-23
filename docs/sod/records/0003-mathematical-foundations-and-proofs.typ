#let sod-number = "0003"
#let sod-title = "Mathematical Foundations and Safety Proofs for Multi-Master Consensus"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "Conditional safety arguments, explicit invariants and performance boundaries"
#let sod-labels = ("consensus", "proofs", "mathematics", "safety", "liveness", "invariants")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Formal Specification & Theory"
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

The statements below depend on their axioms; they are not a verification of the full SQLodin host.
SQLodin now imports the complete pinned paxos-odin library. Snowflake injectivity requires no reuse
of the node/timestamp/sequence tuple, including after process restart. Arbitrary raw SQL is not made
deterministic by total ordering. One RTT describes healthy slot choice, not end-to-end durable SQL
latency. CPU instruction latency and comparative performance require measurement on the target host.
See the upstream integration SOD draft and the dated implementation review for the tested boundary.

= Abstract

This record sketches conditional safety arguments for the multi-master design. It is not a
mechanized proof or a refinement proof of the Odin host. The claims depend on the following
assumptions, which implementation and fault tests must establish:

1. *Agreement (Safety):* At most one mutation is ever chosen for any given log slot.
2. *One-RTT Healthy Fast Path:* Healthy local slot owners choose a value in one quorum RTT with zero leader-forwarding hops without violating Lamport's Synod invariant $B_3(b)$.
3. *Conflict-Free Primary Key Injectivity:* Snowflake keys provide a mathematically provable injective mapping that avoids key collisions only while identities and timestamp/sequence tuples are never reused.
4. *Contiguous Convergence:* Identical initial state and deterministic execution of an identical log yield convergence.
5. *Bounded Kernel Storage:* Zero heap allocations during consensus execution with hardware bitset operations (`POPCNT`, `CTZ`).

= Formal Axiomatic System

The execution of the SQLodin protocol is governed by five fundamental distributed computing axioms:

- *Axiom A1 (Processes & Durability):* The cluster consists of a finite set $cal(N) = {1, dots, N}$ of fail-stop/restart processes. Volatile state is wiped on crash; durable state in `Ledger` is recovered sequentially from stable storage.
- *Axiom A2 (Asynchronous Network):* Channels are asynchronous and may delay, reorder, duplicate, or drop packets, but never forge or corrupt payload bytes.
- *Axiom A3 (Quorum Intersection):* Phase-one and phase-two quorums are majorities.
  Every phase-one quorum intersects every phase-two quorum; membership remains fixed.
- *Axiom A4 (Ordered Durability Gate):* A transition generating writes $W$, network messages $M$, and committed records $C$ persists and syncs $W$ prior to transmitting $M$ or releasing $C$.
- *Axiom A5 (Deterministic SQLite Transition):* State machine application $T(D B, v) |-> D B'$ is pure and deterministic for all replicas.

= Core Definitions

== Definition D1: Ballot Ordering
A ballot $b in cal(B)$ encodes the triple $("round", "priority", "node") in NN_0 times NN_0 times cal(N)$ as a 64-bit word:
$ b = ("round" << 24) | ("priority" << 16) | "node" $
The relation $b_1 prec b_2$ is a total ordering equivalent to the lexicographical ordering of the triple.

== Definition D2: Static Log Partitioning
Slots $cal(S) = {1, 2, 3, dots}$ are partitioned across members via the ownership function:
$ "Owner"(s) = ((s - 1) mod N) + 1 $
Each node $i$ owns a partition $cal(S)_i$ such that $cal(S)_i inter cal(S)_j = emptyset$ for $i != j$, and $union.big cal(S)_i = cal(S)$.

== Definition D3: Chosen Mutation
Mutation $v$ is chosen in slot $s$ with ballot $b$ iff a write quorum $Q_w$ has durably cast votes for $(b, v)$ in slot $s$:
$ "Chosen"(s, b, v) <==> exists Q_w subset.eq cal(N), |Q_w| >= floor(N/2) + 1, forall a in Q_w : "Voted"_a (s, b, v) $

= Safety Proofs

== Lemma 1: Quorum Intersection Witness
*Statement:* For any two majority quorums $Q_1, Q_2 subset.eq cal(N)$, $Q_1 inter Q_2 != emptyset$.
*Proof:* $|Q_1| + |Q_2| >= 2(floor(N/2) + 1) >= N + 1$. By the Pigeonhole Principle, $|Q_1 inter Q_2| >= 1$. $qed$

== Lemma 2: Fast-Path Phase 1 Elimination
*Statement:* A node $i$ proposing into its owned slot $s in cal(S)_i$ using round 0 ballot $b_0(i)$ satisfies Lamport's Synod condition $B_3(b_0(i))$ without Phase 1 exchange.
*Proof outline:* The acceptor admits a round-zero proposal only from this slot's configured
owner; no valid lower-ballot owner proposal exists. An owner may never reuse a slot/ballot for
another value, including after restart. A later durable promise can reject the owner fast path,
requiring higher-ballot recovery. Unique numeric ballots alone do not supply these premises.

#block(breakable: false)[
== Lemma 3: Conflict-Free Snowflake Injectivity
*Statement:* The mapping $f(t, i, "seq") = (t << 22) | (i << 12) | "seq"$ is injective for $0 <= t < 2^(42)$, $0 <= i < 2^(10)$ and $0 <= "seq" < 2^(12)$.
*Proof:* The projections $pi_t(K) = floor(K / 2^(22))$, $pi_i(K) = floor(K / 2^(12)) mod 2^(10)$, and $pi_"seq"(K) = K mod 2^(12)$ map distinct tuples to distinct 64-bit keys. Therefore, concurrent insertions on distinct nodes $i_1 != i_2$ never collide on primary keys. $qed$
]

== Theorem 1: Consensus Agreement
*Statement:* For every slot $s in cal(S)$, at most one mutation can ever be chosen:
$ "Chosen"(s, b_1, v_1) and "Chosen"(s, b_2, v_2) ==> v_1 = v_2 $
*Proof outline:* Within a ballot and slot, the proposer must never issue two values. Across
ballots, phase one reads each witness's highest accepted vote, which need not be the vote at
$b_1$. The Paxos induction requires every higher accepted vote to preserve an already chosen
value. Durable promises exclude new lower-ballot votes after the intersecting phase-one quorum
promises; choosing the highest reported vote preserves the induction. Owner fast paths need the
reserved-ballot premise and must still obey later promises. Quorum intersection alone is not a
complete proof: persistent promises, vote selection and same-ballot value stability are required.
The executable host refinement and crash model remain production-SOD work.

== Theorem 2: Replica State Machine Convergence
*Statement:* Replicas applying chosen mutations in log order $s = 1, 2, 3, dots$ reach identical SQLite database states.
*Proof:* Follows directly from Theorem 1 (unique slot decree) and Axiom A5 (deterministic SQLite transition function). $qed$

= Mechanical Sympathy & Performance Bounds

The fixed-capacity data layout bounds protocol storage. CPU and cache costs still require measurement:

1. *Zero Dynamic Memory:* The consensus kernel uses capacity-bounded arrays without transition-time heap allocation.
   SQLite, journal preparation and transport queues still allocate.
2. *Bitwise Slot Arithmetic:* Ring indexing uses bounded arithmetic: `cell = (s - 1) & (W - 1)`.
3. *Bitset Quorum Logic:* Quorum sizes and bitset memberships evaluate via `intrinsics.count_ones` (`POPCNT`) and `intrinsics.count_trailing_zeros` (`CTZ`).
4. *SIMD Vector Search:* Instruction selection depends on the extension build and target CPU.
   No NEON or AVX-512 speedup is established by this specification.
