#let sod-number = "0004"
#let sod-title = "Production SQL and Durable Throughput"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "Durable host tradeoffs, mixed SQL and scoped qualification"
#let sod-labels = ("storage", "performance", "multi-master", "correctness")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Architecture and Implementation Plan"
#let sod-status = "Committed"
#let sod-last-updated = "2026-09-25"
#import "../../shared/sod.typ": sod-document
#show: doc => sod-document(
  sod-number, sod-title, doc, authors: sod-authors, state: sod-state,
  created: sod-created, discussion: sod-discussion, labels: sod-labels,
  category: sod-category, status: sod-status, last-updated: sod-last-updated,
)
#set heading(numbering: "1.1")
#set table(stroke: 0.4pt + rgb("cbd5e1"), inset: 5pt)
#show raw: set text(size: 8.5pt)
#let costs = json("../../../benchmarks/results/linux-durability-cost.json")
#assert(costs.complete and costs.samples.len() == 12)
#let median(xs) = xs.sorted().at(calc.floor(xs.len() / 2))
#let rows(mode) = costs.samples.filter(s => s.mode == mode)
#let number(x, digits: 2) = str(calc.round(x, digits: digits))
#let sync-fraction = median(rows("durable_3").map(s => s.sync.nanos / 1e9 / s.seconds))

= Abstract

Build the durable SQL host around the complete pinned paxos-odin library. Preserve agreement,
retry identity and SQL semantics while reducing synchronization and copying costs. The chosen
mechanisms are bounded group commit, concurrent replica I/O, deterministic transaction outcomes,
fresh read markers and certified recovery. This record explains their tradeoffs and the accepted
release scope. It does not claim that an efficient language makes durable replication inexpensive.

= Status and Implementation Boundary

*Committed; reviewed 25 September 2026.* Promoted on 22 September as the accepted design. The
fixed three-voter correctness qualification is complete under the owner's explicit acceptance
decisions. The 23 closure criteria, tested source and binaries are bound in
`docs/releases/2026-09-25.typ` and
`benchmarks/results/verification-20260924/release-decision.json`.
This record remains Committed, not frozen as Published. A qualified scope is not unrestricted
production suitability, a performance pass or evidence of physical failure-domain independence.

#table(columns: (1fr, 2.5fr), inset: 5pt,
  [*Design area*], [*Current disposition*],
  [P0: attribution], [Durable cost attribution and mixed-workload measurements retained.],
  [P1: SQL outcomes], [Policy 9, durable outcomes, retry epochs and optimistic validation implemented.],
  [P2: batching], [Bounded journal/application groups and fair owner service implemented.],
  [P3: representation], [Lossless journal/wire packing and statement reuse implemented; further copy reduction remains an optimization.],
  [P4: service], [Native mTLS, fresh reads, CLI, Python and SQLAlchemy implemented. Membership remains fixed.],
  [P5: recovery], [Format-5 generations, certified images, retention, backup/restore and offline migration implemented.],
  [P6: qualification], [Correctness scope accepted; throughput and latency shortfalls disclosed.],
)

= Introduction

The early disk-backed path achieved roughly 22 writes/s in its measured environment. The useful
question was how much durable work each acknowledged transaction required. Serial voter execution,
repeated sync barriers and large copied values explained costs that instruction-level tuning alone
could not remove. The historical attribution below records the basis for this design.

= Terminology and Scope

A transaction is a bounded SQL request with typed parameters and durable retry identity. Journal
durability, chosen progress, application progress and response delivery are distinct frontiers.
A timeout after admission can mean an unknown outcome. It does not cancel a chosen request.
The qualified scope uses three fixed authenticated voters with compatible Linux x86_64 builds.

= Problem Statement

Independent durable requests cannot simply be merged into one SQL transaction: deferred constraints
and rollback conflict actions can change their outcomes. Nor can a sync be removed because another
stage has completed. The host must amortize work while preserving the reference execution and
must keep recovery, peer service and client admission from starving one another.

= Goals and Non-Goals

== Goals

Preserve durable acknowledgement and serializable bounded transactions under retries and one-voter
loss. Bound queues and retained consensus history. Make recovery publication crash-safe. Measure
mixed transactional SQL against a matched durable SQLite baseline with verified outcomes.

== Non-Goals

No unrestricted SQL, dynamic voter changes, rolling mixed-version upgrade, cross-shard transaction,
Byzantine guarantee or arbitrary-query latency bound. Five-voter qualification and independent
physical failure domains are not inferred from the three-instance evidence.

== Performance objectives and acceptance decision

The original provisional objectives remain unchanged: 3,000 transactions/s for a 70/30 mix
(including 900 successful writes/s), 1,000 pure writes/s, p99 reads/writes of 20/50 ms and at least
25% of matched SQLite throughput. The short-query RSS objective is 512 MiB per voter, separately
from OS page cache. The recovery aspiration was 60 s with a local certified image and at most
1 GiB replay tail on qualified hardware; it is not a database-size-independent guarantee.

On 25 September the owner accepted release after correctness qualification with performance
shortfalls disclosed. Throughput and p99 objectives are future improvement goals, not first-release
blockers. Slow retained-store startup observations of 114/137 s remain disclosed. The owner also
removed large-capacity growth campaigns as requirements. The original 10/100 GiB aspirations
remain unclaimed. On 24 September mandatory soak durations were replaced by formal arguments
and targeted fault tests. These decisions waive neither durable acknowledgements nor correctness.

= Design Overview

#block(fill: rgb("f1f5f9"), inset: 10pt, breakable: false)[
  Bounded request → ordered proposal → owned pending effects \
  → journal durability frontier → eligible peer messages \
  → contiguous SQL group → data + outcome + applied frontier \
  → durable response
]

One owner serializes protocol state. Workers receive owned work and return checked completions;
they do not mutate consensus state concurrently. Replica processes can perform I/O independently.
A completion releases only the effects covered by its durable sequence. Backpressure applies
before admission where possible; accepted work retains its identity until its outcome is known.

= Detailed Design

== P1: deterministic outcomes and retries

SQL policy 9 constrains functions, schema behavior, row identifiers and extension use. Expected
constraint failures become durable request outcomes. Unknown storage or execution failures stop
application; inventing a rejection would allow replicas to diverge. Data, outcome, retry state
and applied watermark commit together. A session/sequence identifies immutable request content.
Explicit epoch retirement permits bounded outcome storage without permitting old effects to recur.
The default session capacity is 65,536. Full semantics live in `specs/sql-policy.typ` and
`specs/session-retirement.typ`.

== P2: grouping without changing transactions

Journal groups hold owned effect copies and release dependent work only after a checked durable
completion. Application groups contain at most 16 ordered requests. Savepoints isolate requests;
deferred foreign-key checks run at each logical boundary. A whole-transaction ROLLBACK takes the
individual-commit fallback before any response. The proof obligation is equality with the reference
state and outcome after every request, not merely equality of the final row count.

The owner services bounded batches and peer work fairly. The protocol window is 64 slots and peer
bursts are bounded to eight. Private generation catch-up applies at most one chosen SQL transaction
per owner turn, with journal-copy limits of 128 records and 1 MiB. These limits bound scheduled work;
they do not preempt a SQLite statement or blocked kernel I/O.

== P3: representation and CPU cost

Lossless zero-run packing reduces journal and peer payload bytes while preserving the complete
Paxos value, including unused fields and floating-point bits used by equality. Shared bounded vector
storage avoids reserving a full vector for every column. Statement reuse reduces preparation work.
Fixed-capacity storage still has a copy and cache cost. A new representation must preserve value
identity and pass codec/recovery tests before performance measurements can justify it.

== P4: service and client semantics

Native mTLS authenticates fixed peer and client roles. The service rejects incompatible identities
and versions. Admission reserves peer capacity: at most 32 connections, 24 clients and four pending
handshakes. Queues hold at most 64 frames or 2 MiB. Client frames are bounded to 64 KiB; responses
to 1 MiB. Internal queries have separate row, byte and execution budgets.

Fresh reads use closed cohorts and ordered markers. Interactive transactions preview privately,
then validate a database-wide revision at ordered commit. This covers predicate conflicts but can
reject disjoint transactions and repeats some SQL work. CLI and Python expose conflict and unknown
outcome recovery. Retry with the same request identity after an uncertain response; a new identity
can execute a second transaction.

== P5: recovery and storage lifetime

Format 5 separates application state from voter-local consensus state. A certified image names an
agreed prefix; its seal and retained suffix connect it to later progress. A private generation becomes
durable before catalog publication. Retirement protects the active generation and its exact
predecessor, checks ownership, and synchronizes deletion before forgetting inventory.

Automatic maintenance starts at a 256 MiB tail or 15 minutes of dirty history. Transfer uses 1 MiB
chunks and a 32 MiB buffer budget. An 8 GiB retained-history cap and free-space checks exert
backpressure. These are resource policies, not a maximum database size. Snapshot and generation
work must keep up with admitted writes. The single maintenance worker has a 3,600 s budget.

Verified backups support fenced restore into a globally unused namespace. Offline migration
accepts the reviewed format-4 policies 6/7/8; sources are preserved. Coordinated certificate renewal
is supported. Hot reload, rolling upgrade and live voter enrollment are outside this qualification.

= Security & Correctness Considerations

SOD 0003 states the composition assumptions. Authentication is not Byzantine tolerance. Storage
must honor synchronization, identities must not be reused, and admitted SQL must execute under
compatible builds. Recovery must not silently create an empty voter when required state is absent.
Backups, migration and restore must preserve or deliberately fence retry namespaces.

= Operational Considerations

Keep peer service available under client overload and snapshot catch-up. Treat admission rejection
as distinct from an uncertain accepted request. Observe lag, retained bytes, free space, queue depth,
RSS and storage latency. A memory bound on one queue is not a bound on SQLite or the page cache.
Deployment procedures belong in the existing guides; precise resource and recovery contracts remain
in `specs/resource-contract.typ` and `specs/recovery-bootstrap.typ`.

= Validation and Acceptance Gates

Correctness qualification combines the 59 model configurations and 48 induction obligations with
163 tests in each of the Linux debug, optimized and individual-commit configurations. It includes
43 current-source crash boundaries, three live generation cycles, 38 native mTLS checks across
three Linux instances, local CLI checks and isolated Python wheel checks. Evidence and candidate
hashes are centralized in the release record rather than copied into each design section.

One-voter loss probes restored first-write service in 2.37, 1.24 and 2.48 s in the recorded run.
These samples are not an unconditional deadline. Storage-fault tests cover ENOSPC, short writes
and sync EIO. Process kills do not certify device power-loss behavior. Formal assumptions and
implementation fault boundaries define the scope; there is no new duration or capacity gate.

The Linux mixed-workload matrix completed 32 cases and 91,840 verified operations. At 32 clients,
256-byte values and a 70/30 mix, it measured 152.3 transactions/s and 46.4 writes/s against
2,971.8 SQLite transactions/s (5.13%). Read/write p99 was 397.1/471.8 ms. The pure-write case
measured 73.6 writes/s against 2,845 for SQLite, with p99 1,230.8 ms. This matrix predates the final
maintenance-budget and replay-turn correction; it is not a final-binary performance measurement.
It does not meet the objectives. A future performance claim requires a new matched measurement.

Use identical schema, durability, workload, concurrency and completion boundaries when comparing
systems. Count expected rejections separately from writes; treat timeouts as unknown outcomes.
Record filesystem, cache policy, versions, seeds and binary hashes. Unsupported comparator workloads
remain unsupported cells. Instrumented attribution and uninstrumented capacity measurements answer
different questions and must be labeled accordingly.

= Alternatives Considered

Disabling sync was rejected because it changes the acknowledgement contract. Replacing Paxos before
profiling was rejected because the measured host serialized durable work. Mencius-style skip
optimizations require an upstream recovery proof; no unilateral skips are permitted. EPaxos or
generalized ordering would require sound conflict detection for SQL predicates, triggers and joins.
Flexible quorums change the failure envelope and require cross-phase intersection. Independent
Paxos groups could add writers, but sharding and cross-group transactions need another design.

A no-log read fence may reduce log work, but the ordered marker gives a simpler reference contract.
Row-only optimistic validation was rejected because it misses predicate dependencies. Background
recovery was selected over blocking all service; its per-turn limits preserve owner scheduling
without claiming that arbitrary SQL can be preempted.

= Open Questions

Further performance work should identify the current saturation point before choosing a mechanism:
SQL execution, sync barriers, payload copies, contention or maintenance interference. Finer conflict
validation and smaller in-memory values remain candidates. No alternate consensus algorithm is
approved by this record. Dynamic membership and rolling upgrades require separate designs. These
are future scope, not reopened conditions for the accepted fixed-voter correctness release.

= Discussion and Revision Notes

== 22 September: correctness before speed

The first review reproduced a chosen uniqueness error blocking later application and raw
`random()` producing divergent replica values. The response was durable per-request outcomes,
rollback isolation and an enforced SQL policy. The dependency decision retained the complete
upstream library. Early application and journal reviews supplied the durability-before-release
and group/reference obligations now stated above.

== 23 September: service and recovery boundary

The initial durable embedding host became a native authenticated SQL service with fresh reads,
bounded results, Python and optimistic ORM transactions. TLS used the pinned OpenSSL integration;
an installed Odin core TLS package was not assumed. Early snapshots were primitives, not permission
to trim. Certified seals, generation publication and fenced recovery completed that boundary later.

An eight-hour SSH campaign across three instances stopped after about 85 minutes on a verifier
read budget. It did not pass. Earlier tmpfs smoke results are correctness-only, not disk performance
evidence. Historical measurements and failed reports retain their original attribution.

== 24 September: progress and verification

The failed native campaign had completed five surviving-quorum probes before a read timed out;
the returning voter was still behind. That observation did not alone prove loss of majority service.
The accepted response was to model bounded ownership progress and recovery, retain counterexamples,
and add targeted regressions. The complete upstream dependency advanced to the tested pin
`c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c`. Formal reasoning and implementation tests replaced
mandatory soak durations as approval requirements.

== 25 September: closure and disclosed limits

Certified generations, image retirement, aggregate retention and final replay scheduling were
qualified. The old multi-transaction replay loop fails its retained negative regression; the bounded
loop passes. A 64 MiB current fixture restarted in 1.32 s. A preceding 10 GiB fixture passed with
14.89 s restart; larger retained-state startup also produced the disclosed 114/137 s observations.
The interrupted larger-capacity campaign is not a capacity pass. The owner accepted the performance
shortfalls and removed large-growth campaigns from release requirements. These dispositions close
the agreed scope without asserting arbitrary capacity or sustained throughput.

The former standalone durability, readiness, implementation, mTLS, snapshot, grouping and campaign
notes are consolidated here and in SODs 0002/0003. Their obsolete pending-work statements do not
define the current stage. Raw evidence remains in `benchmarks/results/`; detailed protocol and
storage contracts remain in `specs/`.

== Historical cost attribution supporting the batching decision

The following diagnostic describes the early serial host, not the current service. It is retained
because it explains why the design prioritized barriers and amplification over language changes.

=== Controlled Linux Attribution

`tools/profile_durability_cost.py` runs the same pinned SQLite build on the same ZFS-backed Linux
host. Each of three shuffled repetitions inserts 480 timed rows after 96 warmup rows, with a
256-byte payload. All resulting row counts and payloads are checked. Setup, warmup, verification
and shutdown are outside the measured region. A single-threaded C interposer times real
`fsync`/`fdatasync` and `pwrite` calls while forwarding every call unchanged. FULL durability is
never disabled. Results come directly from `benchmarks/results/linux-durability-cost.json`.

#block[
#set text(size: 8.5pt)
#table(
  columns: (1.7fr, 0.8fr, 0.8fr, 0.85fr, 0.9fr),
  table.header([*Measured path*], [*Rows/s*], [*Syncs/row*], [*Time in sync*], [*pwrite KiB/row*]),
  ..(("sqlite_full_1", "SQLite FULL, 1 row/tx"),
     ("sqlite_full_32", "SQLite FULL, 32 rows/tx"),
     ("durable_1", "SQLodin, 1 voter"),
     ("durable_3", "SQLodin, 3 serial voters")).map(item => {
    let rs = rows(item.at(0))
    (item.at(1), number(median(rs.map(s => s.rows_per_second))),
     number(median(rs.map(s => s.sync.calls / s.rows)), digits: 3),
     [#number(100 * median(rs.map(s => s.sync.nanos / 1e9 / s.seconds)))%],
     number(median(rs.map(s => s.sync.bytes / s.rows / 1024))))
  }).flatten(),
)
]

These are instrumented small-write diagnostics, not mixed-SQL capacity results. The 32-row case
changes transaction granularity; it illustrates amortization and is not a claim that independent
client transactions already share commits. Aggregate pwrite bytes are bytes submitted to file
writes across the measured process, not physical-device bytes, ZFS allocation or user payload size.
Minor excess syncs include checkpoint/WAL lifecycle work. Short repetitions do not establish
long-run distributions. The interposer adds measurement overhead, which must be quantified before
using it for close CPU comparisons.

=== Mechanism and Cost Model

The historical `src/durable/host.odin:finish` path synchronously persisted each transition, applied its contiguous SQL
prefix in another transaction, then released packets. In a healthy, three-voter, one-row path,
each replica commonly flushes its vote, its chosen record and its application watermark separately:
roughly nine process-wide barriers. The harness executes all replicas serially and drains them
before the next request. This is more work than one local SQLite transaction, and it also hides
the opportunity for independent disks and protocol stages to overlap.

The measured snapshot's fixed 7,800-byte mutation was copied and journaled in full, even for small
requests. Later format 2 adds request identity; format 3 packs journal zero runs. This historical profile
also exposes large file-write amplification. Journal SQL is prepared/finalized per record; journal
lookups, hashing, application SQL preparation and payload copies add further cost. Their relative
contributions need stage counters, allocation measurements and profiles before tuning.

For the measured serial path, a useful attribution is:

$ T approx T_"sync" + T_"file writes" + T_"other". $

If sync duration and frequency remain unchanged, eliminating *all* non-sync work gives an optimistic
speedup bound of $1 / p_"sync"$, about
#number(1 / sync-fraction) times here. This is an Amdahl-style bound for this measurement, not a
universal device limit. Reducing barriers, write amplification or serialized waiting changes the
bound. The language is valuable for predictable memory and CPU cost; architecture determines how
much durable work must be performed.


= References

- SOD 0002: architecture; SOD 0003: agreement and composition assumptions.
- `specs/grouped-sql.typ`, `specs/service-batching.typ`, `specs/resource-contract.typ`.
- `specs/generation-catalog.typ`, `specs/image-retirement.typ`, `specs/recovery-bootstrap.typ`.
- `docs/releases/2026-09-25.typ`: accepted scope and source-bound evidence.
- `benchmarks/results/verification-20260924/workload-matrix-linux.json` and
  `benchmarks/results/verification-20260924/workload-matrix-analysis-linux.json`.
- `benchmarks/results/linux-durability-cost.json`, `bench/durability_cost/`,
  `tools/profile_durability_cost.py`: historical sync attribution.
