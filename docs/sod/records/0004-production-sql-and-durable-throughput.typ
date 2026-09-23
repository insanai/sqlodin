#let sod-number = "0004"
#let sod-title = "Production SQL and Durable Throughput"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "Measured storage costs, mixed SQL transactions and production acceptance gates"
#let sod-labels = ("storage", "performance", "multi-master", "correctness")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Architecture and Implementation Plan"
#let sod-status = "Committed; implementation in progress; release gates open"
#let sod-last-updated = "2026-09-23"
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

Keep the complete, pinned paxos-odin library as SQLodin's consensus foundation. Build a production
host around its batch, durability, recovery and trim interfaces. Prioritize mixed transactional
SQL workloads, including indexes, constraints, joins, short multi-statement transactions and
concurrent clients writing through any voter. Provisional targets below are engineering goals,
not achieved performance or a declaration of production readiness.

The measured bottleneck is primarily storage synchronization and amplification in the current
host. Faster generated machine code alone cannot remove repeated durable barriers. The proposed
sequence is: establish deterministic transaction outcomes; batch and pipeline real durable work;
make replica I/O concurrent; compact payloads; complete client/read and recovery contracts; then
validate long-running behavior. Protocol changes require evidence that the remaining bottleneck
is protocol-related, plus a refinement argument and executable fault tests.

= Status and Implementation Boundary

Promoted to SOD 0004 on 2026-09-22 as the accepted implementation plan. Committed status
records the design decision; production readiness requires the release gates below to pass.

The existing fixed-membership host persists Paxos promises, votes and decisions, replays retained
history and atomically stores SQLite mutations with an applied watermark. It uses the whole
paxos-odin submodule at `a3e1fd78ec8f0429e5024710189ef77fc31961af`. This proposal does not replace,
copy, fork piecemeal or modify that dependency. Upstream changes, if needed, must be separately
reviewed and consumed through a new complete, tested pin.

The pre-SOD snapshot had 43 SQLodin tests, 79 upstream tests and five Linux process-crash scenarios.
The readiness review reproduced a chosen uniqueness failure blocking reopening and raw `random()`
creating divergent replica values. Those concrete cases now have regression fixes: durable SQL
outcomes, session/sequence retry identity, an enforced function policy (including defaults) and
per-request rollback isolation. Maximum rowid writes are rejected before they can enable random
rowid allocation. These host changes preserve the whole upstream pin.

The format-3 / policy-4 baseline adds audited expression rejection, parser/value
limits and a persisted SQLite build fingerprint. P1 still needs a complete SQL/schema/ordering
contract, deterministic write execution quotas, compatibility negotiation, session retirement and
result handling. Local read budgets do not decide replicated write outcomes.

P2 now groups up to sixteen ordered application requests with savepoints and per-request deferred-FK
checks. A whole-transaction ROLLBACK falls back to the individual-commit reference path before any
acknowledgement. Leading no-op outcomes share the journal commit. Incoming transitions now share
bounded journal groups using owned effect copies and a checked durable sequence. This uses the
unchanged upstream `.Host_Managed` integration contract; the `.Enforced` per-transition path remains
a reference build. Asynchronous persistence and broader overload/refinement qualification remain open.
See `docs/journal-group-commit.md` for ownership bounds and the implementation review argument.

P3 losslessly packs zero runs in journal values, preserving all inactive fields and IEEE bits used
by upstream equality. Fixed-size in-memory/transport values remain. P4 adds fresh, single-use ordered
read barriers with durably reserved marker IDs, a native Odin mTLS SQL service, bounded typed
query results and a uv-managed Python API. Format 4 / policy 6 adds optimistic ORM
transactions: private rolled-back previews, revision-checked ordered commits, generated
keys, rollback and savepoints. Database-wide conflicts and repeated preview work are
explicit performance limits. Enrollment and live voter changes remain open. See `docs/implementation-status.md` for the exact contract.

Local checks cover grouped and reference transaction execution. Linux checks include the unchanged
79-test upstream library, fault simulation, twenty-two targeted process-crash boundaries and separate
voter processes. The earlier campaign used one Linux instance with three voter processes.
A subsequent eight-hour SSH campaign across three authorized LXC instances stopped after
about 85 minutes on a verifier read budget. It did not pass; physical failure-domain
independence is unverified.
The 24-hour and seven-day campaigns remain deferred. See `docs/cluster-qualification.md`.
Native service checks now cover direct mTLS consensus, SQL results, durable retries and crash recovery;
see `docs/network-service.md`. The SSH soak does not qualify the newer service. These changes do not close the production qualification gates.
New evidence uses `linux-candidate-v3-*`. The initial `linux-production-p1-batches.json` measurement
remains historical. An early process smoke used tmpfs; its corrected report is correctness-only,
not disk performance evidence. Persistent-disk runs now record and validate their filesystem.

= Evidence: Where the 22 Writes per Second Go

== Controlled Linux Attribution

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

== Mechanism and Cost Model

`src/durable/host.odin:finish` synchronously persists each transition, applies its contiguous SQL
prefix in another transaction, then releases packets. In a healthy, three-voter, one-row path,
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

= Goals, Scope and Provisional Targets

== Workload and Reference Environment

Prioritize a 70% read-only / 30% read-write transaction mix; also measure 50/50, read-heavy 95/5,
and pure-write cases. A transaction contains 1-8 statements, typically 1-4 row changes, with
256-byte typical values and a separate 4 KiB profile. Include point lookups, indexed ranges,
joins, order/inventory/ledger transactions, uniqueness/FK constraints and conflicts. Count completed
transactions, changed rows and expected rejections separately. A rejected transaction is not a
successful write. This is an application workload, not a claimed TPC-C implementation.

Qualify targets on three separate Linux failure domains, each with at least four dedicated CPU
cores, 8 GiB RAM and local durable SSD/NVMe; LAN RTT at most 1 ms. Record measured sync distributions,
CPU, storage model, filesystem, kernel and cache policy. Start with a 10 GiB dataset per replica,
then test growth to 100 GiB. The current single-host ZFS results do not qualify this environment.
Benchmark one client, then 8/32/64 clients. Admission is spread across all three voters, including
one-owner hot spots and skewed keys. Keep all requested durability and read guarantees enabled.

== Provisional Acceptance Targets

#block[
#set text(size: 9pt)
#table(
  columns: (1.2fr, 2.7fr),
  table.header([*Dimension*], [*Provisional v1 target and qualification*]),
  [Mixed throughput], [At least 3,000 completed transactions/s at the 70/30 mix and 32 clients;
    at least 900 successful write transactions/s when the conflict-free workload admits them.],
  [Pure writes], [At least 1,000 durably completed transactions/s for the declared small-transaction
    workload, using bounded group commit; separately publish the one-client latency case.],
  [Latency], [Healthy p99 read-only at most 20 ms and read-write at most 50 ms, measured from the
    client's scheduled arrival through result receipt. Publish rejection and timeout rates.],
  [Relative efficiency], [At least 25% of matched local SQLite transaction throughput using identical
    schema, durability, workload and group-commit policy. Report the single-copy advantage explicitly.],
  [Memory], [At most 512 MiB database-process RSS per voter for the defined short-query profile;
    separately report OS page cache. All request, payload, result and queue budgets are explicit.],
  [Retention/recovery], [Bound post-snapshot retained consensus history to a configured 8 GiB per
    voter, with admission throttling when necessary. Restart within 60 s with an available local
    certified snapshot and at most 1 GiB replay tail on the qualified hardware.],
  [Faults and endurance], [Zero lost acknowledged writes or duplicate effects in fault campaigns;
    restore quorum service within 5 s after one crash on the declared LAN. Pass a 24-hour run at
    70% of measured sustainable capacity, then a 7-day candidate soak.],
)
]

These numbers are hypotheses to calibrate at phase P0. Record any infeasibility and revise the
proposal openly; do not change durability, reduce the dataset or hide failed requests to pass.
Targets apply to the defined workload, not arbitrary analytical scans or maximum-size transactions.
Database growth itself is not a memory leak or retained-log bound violation. Snapshot throughput
and free-space reserves must support the chosen admission rate.

The separate-machine, 24-hour and seven-day requirements are SQLodin-specific release goals,
not a universal database-readiness threshold. An unrun gate is missing qualification evidence,
not itself a demonstrated defect. Assess implemented guarantees and known limitations separately
from pending tests. Comparative claims require matched workloads, durability, topology and duration.

== Non-Goals for the First Production Release

No Byzantine fault tolerance, unrestricted extensions, arbitrary nondeterministic SQL, transparent
WAN-latency guarantees or unlimited transaction size. No promise that additional replicas multiply
SQLite execution throughput. No cross-shard transactions or automatic live cluster resizing in v1;
provide a tested, fenced replacement procedure for the initial three/five-voter configurations.

= Design Overview: Use the Existing Consensus Foundation

Use one serialized consensus owner per node with a dedicated persistence worker and application
writer. Separate processes or independently scheduled nodes allow actual replica I/O concurrency;
calling the same Host concurrently is not permitted. SQLite still has one application writer per
replica. Read connections use bounded snapshots under an explicit consistency mode.

The proposed flow is:

#block(fill: rgb("f1f5f9"), inset: 10pt)[
  Request identity + typed SQL parameters + deterministic contract \
  → bounded admission and batch builder \
  → paxos-odin proposals / received messages → owned pending effects \
  → grouped durable journal barrier → eligible outbound messages \
  → ordered transaction execution + outcomes + deduplication + watermark \
  → grouped durable application barrier → client result
]

Every stage has a byte budget, depth limit and backpressure signal. Application progress, pending
journal durability and message availability are separate frontiers. A storage completion advances
only the frontier it actually covers. Replica lag does not require waiting for all replicas before
client completion, but acknowledged results must satisfy the quorum and local application contract.
Catch-up remains bounded and observable; requests above capacity receive a retryable admission
response before acceptance. A timeout after acceptance means *outcome unknown*, not cancellation.

= Detailed Design

== P1: Transaction Outcomes and Deterministic SQL

The initial implementation accepts 4 KiB SQL bodies, up to eight statements and sixteen parameters
using one shared tuple. It returns outcome kind, constraint code, change count and original slot;
SELECT result sets are not returned yet. Sessions have one outstanding sequence and at most 65,536
durable fences. A gap consumes its sequence as a rejection; older requests expire. Identical retries
return the original outcome; changed content under the same current identity is rejected. Session
retirement and the richer versioned service request below remain outstanding.

Introduce a versioned request containing cluster/configuration epoch, client/session ID, sequence,
transaction ID, canonical SQL/bound parameters, schema version and declared execution policy.
One replicated command is a complete bounded transaction. The first API submits an entire statement
batch; interactive transactions spanning arbitrary client round trips require a separate isolation
and timeout design. Queries inside a write transaction execute in its ordered state-machine turn.

Reject unsupported syntax/functions before admission, then validate again against the replicated
schema version at application time. Enforce an allowlist of deterministic SQL facilities and
functions, including triggers, CHECK constraints, generated columns and registered extensions.
Materialize time/randomness/IDs in the request. Do not trust a UDF merely because a flag declares it
deterministic. Control engine/extension versions, collations, floating-point behavior and query
ordering where results or writes depend on it. DDL is serialized and invalidates schema-keyed caches.
Policy 5 adds bounded FTS5/vector APIs with rollback, retry and recovery checks; broader
FTS admission and large-dataset resource qualification remain open.

Model execution as a total, deterministic transition on database state D, deduplication state U,
request r and applied position s:

$ (D', U', o) = F(D, U, r), quad a' = s. $

For an approved SQL-level rejection, the request has no database effects and produces a stable
error code/result. Store that outcome, deduplication entry and the advanced watermark atomically.
For a duplicate request, return its original outcome and do not execute it again. A reused ID with
different canonical content is an error, not a retry. Retain compact sequence/epoch fences after
result-body eviction; an expired retry must be rejected or report unavailable historical output,
never become a new execution. Bound sessions and outstanding sequence gaps explicitly.

Storage errors, corruption, OOM, unknown SQLite failures and broken internal invariants remain
fail-closed. A generic catch-and-skip of SQLite errors is prohibited. Error classification is a
versioned replicated contract. Local wall-clock cancellation during ordered application must not
create replica-specific outcomes; impose deterministic execution quotas where supported, otherwise
halt/recover without advancing the command. A deadline can reject before admission or time out
waiting for a result, but cannot undo an already chosen transaction.

== P2: Durable Batching and Pipelining

First expose a durable wrapper around upstream `node_propose_batch`; sweep batch sizes 1/8/16 and
then larger tested capacities. This groups proposals but does not automatically group acceptor
flushes or application commits. Each request retains independent identity and outcome.

The upstream `.Enforced` effect gate forbids another transition from resetting unconfirmed writes.
Do not call its confirmation hook early or merely retain borrowed pointers to bypass that rule.
For cross-transition group commit, use upstream's existing `.Host_Managed` integration mode only
inside an audited host wrapper with owned copies, durability sequence numbers and equivalent
runtime assertions. Alternatively, propose an upstream multi-event/epoch gate and update the full
pin. The initial synchronous `.Enforced` path remains the reference implementation.

Copy pending writes/messages/committed values before the next transition. Append a whole ordered
journal group, synchronize it, and mark its highest durable sequence only on success. Release a
message only if *all* its causal journal dependencies are at or below that frontier. Buffered
application entries wait for durable decisions. A crash discards unflushed effects and recovers
from disk. Never transmit owner round-zero Accept messages before the owner's vote barrier;
upstream's limited pre-durable campaign-message facility does not authorize that shortcut.

Group independent, ordered application transactions under one outer durable commit. Isolate each
request with an internal savepoint, and store its result/deduplication metadata after its SQL-level
success or rejection. Do not acknowledge an inner RELEASE; only the outer commit establishes the
batch's durable application frontier. Isolation must be equivalent to serial individual requests.

Start with batch byte/count limits and a 0.25/1/2 ms maximum coalescing-delay sweep. Flush when a
limit or timer fires, and immediately when low-load latency policy requires it. Bound each queue;
size the active window from measured throughput and decision/application latency rather than
blindly increasing it. Fair scheduling must prevent hot owners and bulk requests starving others.

*Application grouping refinement:* check `SQLITE_DBSTATUS_DEFERRED_FKS` after each request,
before the next request can repair its foreign-key violations. A rejected request rolls back its
savepoint; its metadata is then staged with the successful prefix. A classified `ON CONFLICT
ROLLBACK` or trigger `RAISE(ROLLBACK)` can erase the whole outer transaction. In that case replay the
complete unacknowledged group through the individual-transaction reference path. Do not replay on
storage, OOM or unknown errors. No result or in-memory watermark is published before the outer
FULL commit. This relies on the restricted function profile excluding externally visible UDFs.
Test deferred constraints, all rollback actions, retries within a group, mixed outcomes and every
commit boundary. The reference path remains buildable for differential checks.

Prepared journal inserts/head updates and chosen lookups should be reused. Cache application
statements by canonical SQL, schema epoch and binding shape. Record actual allocation/copy savings.
Checkpoint scheduling must be bounded and measured against tail latency, not simply disabled.

== P3: Compact Values and Storage Amplification

Preserve upstream's generic comparable-value interface and data-oriented slot arrays. Replace the
fixed-size in-memory mutation representation with either bounded inline canonical data
or a small comparable descriptor containing immutable payload identity, format and length. Store
only active SQL/parameter fields; encode no process pointers, native padding or unused tails.
Canonicalization is an explicit format migration because upstream compares all logical fields.
The current format-3 journal instead uses a reversible zero-run codec: no fields are dropped,
and decoding reproduces every original bit. This is an interim disk-space improvement, not a
compact descriptor or a reduction in in-memory message size.

A descriptor is not evidence that a payload exists. Before voting for it, a voter must durably
possess the complete verified bytes with a recovery mapping; synchronize payload and vote together
where possible. Missing payloads block voting/application. Validate lengths before allocation and
verify content on fetch; assume collision resistance only where a content hash is used as identity.
Keep payloads until the snapshot/trim and outstanding-reference rules permit collection.

Use bounded slabs/arenas for immutable payload ownership and small descriptors in queues. Separate
hot slot metadata from variable payload bytes. Encode once per canonical request and avoid copies
only when lifetime/reference accounting is proven across async I/O, retransmission and window reuse.
Benchmark application SQL, encoding, hashing, memcpy, allocations, journal bytes and checkpoint bytes.
Do not remove checksums or barriers to obtain a speedup.

Retain SQLite as the initial journal backend while measuring these changes. A segmented append-only
journal is a later alternative if B-tree/page amplification remains dominant. It needs length framing,
checksums, durable LSNs, torn-tail recovery, directory synchronization, segment GC and migration tests.
Fusing a chosen record and application commit is also a later experiment: it requires a revised
atomicity/refinement argument and may not relax promise/vote persistence or release messages early.

== P4: Network Service, Read Consistency and Client Semantics

Every voter remains a direct proposal endpoint. Add authenticated, versioned framing with cluster,
epoch and member identity, size limits, bounded reconnect/retransmit buffers and per-client quotas.
Transport authenticates a cluster; the existing protocol envelope alone does not do so. Separate
peer identity from client authorization. Return distinct admission, unknown-outcome, deterministic
rejection, expired-result and storage-failure responses.

Provide explicit local snapshot, read-your-writes and linearizable read modes. The first correct
linearizable reference path uses a fresh uniquely identified ordered barrier for reads that have
already arrived, waits for its applied prefix, then starts a SQLite snapshot. Batch waiting reads
behind one fresh barrier where the proof permits. Do not reuse an old barrier for a later invocation
without a separate lease/fence proof. The client must retry a displaced proposal by identity, not
treat its original slot number as completion.

Prove that a completed earlier write cannot lie after a newly chosen unique read barrier: the write's
acknowledged contiguous prefix would already have decided that earlier position. Include replica
lag, resubmission, snapshot installation and membership epochs in this argument. A more efficient
quorum read-index path is a separate refinement for multiple concurrent owners; a leader-based Raft
read-index recipe or an applied watermark alone is insufficient. Avoid clock leases in initial v1.

== P5: Snapshots, Retention and Replacement

A snapshot binds the application image, schema/engine format, applied prefix, outcomes/dedup fences
and configuration epoch to a checked manifest. Never copy a donor's node-local promise/vote/ID
identity over another acceptor. Separate exportable application state from local consensus recovery
state. For the eventual snapshot format, prefer distinct application and consensus stores; the exact
SQLite-journal versus segmented-journal backend is selected after P3 evidence.

Create a consistent SQLite image, persist and verify its manifest, then obtain a chosen trim anchor
through upstream's `node_install_chosen_trim` integration contract. The certificate must establish
that a quorum durably retains a usable snapshot at the same prefix and matching logical state,
and that obsolete slots cannot be reopened. Preserve current promises and all accepted/chosen state
above the trim prefix. A local checkpoint or a hash from one donor is not a quorum certificate.

Install using staging files/generation manifests with explicit file and directory synchronization;
crashes must select a complete old or complete new generation. Retain the old recoverable generation
until publication is durable. Backup consistency must pin the actual copied prefix, which can move
during an incremental backup; validate the final watermark and manifest rather than assuming the
initially requested prefix. Do not treat a live DB file copy without its WAL as a backup.

For replacement, fence the old identity and follow a certified learner/catch-up/membership procedure;
never recreate a missing acceptor under the same ID with empty promises. Coordinate new epochs via
the upstream replicated-log reconfiguration/stop-sign facilities when required. Fixed membership is
acceptable for v1 only with a tested operational replacement path. Halt admission before retention
or free-space reserves are exhausted. A slow/offline replica must not force unlimited retained history;
it recovers from a certified snapshot when its range is no longer retained.

= Mathematical Model and Proof Obligations

== Safety and Refinement

Use a crash-recovery, non-Byzantine model with authenticated membership, durable barriers that honor
the platform contract, and eventual synchrony only for progress. Model volatile state separately
from stable journal, payload, snapshot and application state. No finite availability bound applies
to an indefinitely asynchronous or minority partition.

The following are obligations to prove and model-check, not completed proofs:

#enum(
  [*Agreement:* two chosen values at a slot are identical under the versioned value identity.],
  [*Durability before visibility:* every released promise/vote-dependent message has a durable
    journal/payload dependency; no crash can contradict that released evidence.],
  [*Prefix and outcomes:* application state and deduplication equal the deterministic fold of
    chosen requests through the durable applied watermark, including rejected and duplicate requests.],
  [*Acknowledgement:* a successful response implies a chosen request, replayable payload and durable
    local outcome/application; any allowed recovery preserves its effect and result identity.],
  [*Group-commit refinement:* discarding a volatile group after any injected crash is observationally
    equivalent to some prefix of the reference durable execution; no inner savepoint is acknowledged.],
  [*Read real-time order:* linearizable snapshots include every write completed before read invocation;
    retries, barriers and routing preserve that relation.],
  [*Trim safety:* deleting history below a certified prefix preserves agreement, recovery and outcome
    deduplication; old epochs cannot revive a retired voter or forgotten request.],
)

Create bounded TLA+/PlusCal models for durable effects, grouped transaction outcomes, read barriers
and snapshot-generation publication. Explore small memberships, concurrent owners, reordered and
duplicated packets, unknown commit outcomes, crashes between append/sync/apply/ack/trim, and full
queues. Check invariants and counterexamples with TLC; add refinement/proof arguments for the
unbounded case. Translate every counterexample into a deterministic executable host regression.
Model checking finite bounds does not establish universal safety or production readiness.

== Throughput, Queueing and Resource Bounds

For batch size b, k durable barrier stages, representative barrier time f, outstanding transaction
capacity c and completion latency l, a first-order capacity bound is:

$ X <= min(X_"SQL", X_"journal", b / (k f), c / l, X_"network"). $

The terms must be estimated for the actual parallel schedule and workload; summing barriers across
three serialized replicas is not a distributed latency lower bound. Every replica still applies the
full SQL stream. Replication improves availability and placement, not write sharding.

Use Little's law $N = lambda L$ to size average outstanding work, then add measured burst and tail
headroom. Stable queues require admitted rate below service capacity; an overloaded system must
throttle rather than accumulate unlimited work. Count slots separately from transactions when a
command contains multiple requests or gaps require skips. Let W cover the target slot rate times
its measured outstanding interval; bytes, not only slot count, constrain payload memory.

Track syncs per committed transaction, file bytes per logical changed byte, non-noop/skip ratios,
SQL time, durability queue delay, replica lag, retransmissions and CPU instructions per transaction.
Evaluate batch timers against p99 latency at both low and high load. Report offered and achieved
rates, backlog and timeouts; avoid coordinated omission by timing from scheduled arrival.

= Algorithm Alternatives and Decision Rules

#block[
#set text(size: 8.5pt)
#table(
  columns: (1fr, 1.85fr, 2fr),
  table.header([*Mechanism*], [*Potential benefit*], [*Decision / required evidence*]),
  [Pinned rotating Paxos], [Direct owner admission; existing bounded protocol, durability and recovery
    interfaces.], [Selected foundation. Optimize its host integration and retain a matched leader-mode
    baseline without removing multi-master support.],
  [Mencius skip techniques], [Reduce idle-owner/gap work under uneven admission.], [Research only if skips
    remain material after batching. Current quorum-chosen no-ops are not Mencius's optimized simple
    consensus; no unilateral skips without an upstream proof and recovery model.],
  [EPaxos / generalized ordering], [Avoid ordering independent commands and some slow-owner delays.],
    [Only for a proven conflict model. SQL ranges, predicates, triggers, constraints and joins make
    conflict detection harder than comparing primary keys. False-negative conflicts violate safety.],
  [Flexible quorums], [Trade replication quorum size against recovery quorum size.], [Separate upstream
    protocol study. Require cross-phase intersection and failure-envelope proof; not a way to remove
    durable votes or a substitute for fixing serialized fsync.],
  [Independent Paxos groups], [Scale SQL execution by tenant/keyspace across multiple SQLite writers.],
    [Later sharding SOD. Cross-group transactions and global queries need explicit semantics and a
    durable coordination/recovery protocol; excluded from initial v1.],
  [Speculative SQL/write sets], [Move work off the ordered apply path or replicate concrete effects.],
    [Not selected for v1. Requires serializable validation of reads, predicates and constraints;
    conflicting masters cannot safely merge arbitrary SQLite page updates.],
)
]

For a protocol experiment, hold payload format, durability, schema, hardware, concurrency and client
completion constant. Require a material improvement in the diagnosed bottleneck, no safety or
recovery regressions and a documented complexity/resource cost. If SQL execution saturates a core
per replica after storage costs are amortized, changing consensus alone cannot raise that ceiling.
Prefer the smallest mechanism that meets the measured target.

= Implementation Plan and Acceptance Gates

#block[
#set text(size: 8.5pt)
#table(
  columns: (0.45fr, 1.9fr, 2.2fr),
  table.header([*Phase*], [*Deliverables and dependencies*], [*Exit gate*]),
  [P0], [This SOD, cost profiler, mixed-workload schema/driver and matched baselines. No dependency.],
    [Reproduce sync/byte attribution; establish one-client and offered-load curves; qualify hardware
    and calibrate provisional targets without changing their durability semantics.],
  [P1], [Request/transaction v2, deterministic SQL policy, outcomes and durable deduplication. Requires P0.],
    [Unique/FK failures reject only their request; valid later writes/reopen work. Random/time/UDF
    violations rejected. Retry and conflicting-ID tests preserve exactly-once effects within the contract.],
  [P2], [Owned async effects, journal/application group commit, fair queues and parallel-node harness.
    Requires P1.], [Reference refinement checks and every append/sync/apply/ack crash boundary pass;
    savepoint/rollback semantics preserved; finite queue budgets hold under overload.],
  [P3], [Compact canonical payloads, statement reuse, buffer lifetime accounting and optional journal
    experiment. Requires P2.], [Payload availability and corruption tests pass; report bytes/syncs/copies
    per transaction and a controlled before/after improvement with repeated samples.],
  [P4], [Authenticated service, client protocol, result handling and proved read barriers. Requires P1/P2.],
    [Multi-machine all-owner workload plus history checking; strict serializable transactions and
    declared read modes survive retries, partitions, pauses, lag and reconnection.],
  [P5], [Certified snapshots, bounded retention, backup/restore, migration and fenced replacement.
    Requires final v2 storage/value contract.], [Crash every publication step; recover acknowledged
    data and request fences; offline replicas catch up; log/disk budgets remain bounded under growth.],
  [P6], [Release candidate, resource/latency curves, runbooks and upgrade/rollback compatibility matrix.
    Requires P1-P5.], [Meet qualified performance targets, 24-hour and 7-day endurance gates,
    storage-fault campaign, recovery RTO/RPO and operational replacement exercises.],
)
]

P3 profiling can inform P5 design while P2 is implemented; production release cannot bypass any
correctness gate. Each phase is a small reviewable implementation series with JSON evidence and
new tests, not a single rewrite. Runtime changes remain proposals until their phase is implemented
and verified. Track phase completion in `docs/implementation-status.md`; promotion does not
close any implementation or qualification gate.

= Validation Matrix and Reproducibility

Measure local SQLite with one FULL transaction per request, matched group-commit SQLite, SQLodin
one-voter, three-voter serial reference and three independent network voters. Include upstream
leader and rotating modes under identical conditions to isolate ownership overhead. Compare
SQLodin and comparison databases only where supported interfaces and durability semantics match;
label unsupported workload cells instead of modifying other database implementations.

For mixed SQL, include success and deterministic rejection, hot-key contention, range predicates,
trigger fan-out, DDL cache invalidation, unique/FK conflicts and bounded large-result queries.
Check every transaction's expected effects and outcome, all replica logical digests after convergence,
and sampled histories against a serial specification. Treat timeouts as unknown outcomes in the
checker, with deduplication resolving retries. Linearizability checks must model transactions and
predicate reads, not only individual key/value operations.

Run increasing offered-load sweeps to find the saturation knee, then steady loads below it. Report
per-operation/transaction histograms, p50/p95/p99/p99.9, replication/application lag, CPU and allocation
profiles, RSS, page cache, journal/tail growth, logical/physical storage measures and recovery work.
Use warm and cold-cache profiles with stated cache budgets; report snapshot/checkpoint interference.
Retain raw samples, seeds, versions, pins, checksums, hardware and failures. Separate profiler runs
from uninstrumented performance runs and quantify profiler overhead before attributing small changes.

The new cost experiment is reproducible on the authorized Linux host with:

```sh
python3 tools/build_native.py
python3 tools/check_durability.py --output new-crash.json
python3 tools/profile_durability_cost.py --transaction-batches \
  --durability-report new-crash.json --output new-cost.json
# Compile SOD 0004 from the repository root:
typst compile --root . \
  docs/sod/records/0004-production-sql-and-durable-throughput.typ \
  docs/build/sod-0004-production-sql-and-durable-throughput.pdf
```

= Migration, Security and Open Decisions

Format 4 / SQL policy 6 rejects format-3 databases and earlier prototypes and has no automatic or rolling migration.
The identity fingerprints SQLite source and compile options; peer negotiation is still required.
Do not relabel an existing file to bypass the identity check. The service still needs version negotiation, maximum sizes,
canonical request identity, deterministic SQL/extension versions and forward/backward compatibility.
Reject incompatible peers. Start with an explicit coordinated migration and verified backups;
rolling upgrade support requires its own mixed-version proof and test matrix. Never fall back to
creating an empty voter when old state is missing or unreadable.

Set bounded provisional request/SQL/result budgets during P0 (candidate maxima: 64 KiB SQL,
1 MiB total parameters, 4 MiB aggregate batch, 1 MiB returned result per request). These are limits,
not the workload sizes used to claim target throughput. Large result pagination needs stable snapshot
semantics and retention quotas. Peer/client authentication, authorization, resource quotas and malformed
frame/SQL handling belong in the service, while the embedding API remains trusted.

Resolve during phase reviews: exact SQL subset and deferred-constraint behavior; session retirement
and retry retention; result-size policy; final journal/store boundary; batching delay/count/byte limits;
qualified hardware; snapshot cadence and catch-up bandwidth; reference multi-owner read-fence proof;
and release ownership/on-call runbooks. No unmeasured absolute throughput claim is approved here.

= References and Source Map

- #link("https://www.sqlite.org/c3ref/c_dbstatus_options.html")[SQLite deferred-FK status] and
  #link("https://www.sqlite.org/lang_savepoint.html")[savepoint semantics] support the per-request group boundary.

- Current host and journal: `src/durable/host.odin`, `journal.odin`, `codec.odin`, `storage.odin`.
- Upstream integration mechanisms: `deps/paxos-odin/src/consensus.odin` (`node_propose_batch`),
  `effects.odin` (gates, barrier classification and restricted pre-durable messages), `node.odin`
  (restore/floor/trim) and `replicated_log.odin` (learners and reconfiguration). The pin is authoritative.
- Review and data: `docs/production-readiness.md`, `benchmarks/results/linux-realworld.json`,
  `benchmarks/results/linux-durability-cost.json`, `bench/durability_cost/`.
- #link("https://lamport.azurewebsites.net/pubs/paxos-simple.pdf")[Lamport, Paxos Made Simple (2001)].
  Consensus agreement and durable acceptor obligations; the host still supplies the state machine.
- #link("https://static.usenix.org/events/osdi08/tech/full_papers/mao/mao_html/index.html")[Mao, Junqueira
  and Marzullo, Mencius (OSDI 2008)]. Rotating ownership and specialized skip optimizations.
- #link("https://www.pdl.cmu.edu/PDL-FTP/associated/epaxos-sosp2013.pdf")[Moraru, Andersen and Kaminsky,
  There Is More Consensus in Egalitarian Parliaments (SOSP 2013)]. Dependency-based ordering alternative.
- #link("https://arxiv.org/abs/1608.06696")[Howard, Malkhi and Spiegelman, Flexible Paxos (2016)].
  Cross-phase quorum intersection, not permission to omit durability or recovery requirements.
- #link("https://raft.github.io/raft.pdf")[Ongaro and Ousterhout, Raft extended paper (2014)].
  Client serial numbers, snapshots and read safety are useful reference contracts, not a proposed
  replacement for paxos-odin.
- #link("https://sqlite.org/pragma.html#pragma_synchronous")[SQLite synchronous documentation],
  #link("https://www.sqlite.org/lang_savepoint.html")[savepoints],
  #link("https://www.sqlite.org/deterministic.html")[deterministic functions], and
  #link("https://www.sqlite.org/backup.html")[online backup]. FULL barriers, outer-commit semantics,
  function restrictions and consistent image creation underpin the proposed host contracts.
