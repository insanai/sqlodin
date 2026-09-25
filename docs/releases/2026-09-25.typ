#set document(title: "SQLodin release qualification", author: ("Vikrant Rathore", "Ronak Rathore"))
= SQLodin first production release: fixed completion contract
<sqlodin-first-production-release-fixed-completion-contract>
Owner: Vikrant Rathore, with assistance from Ronak Rathore. Frozen
baseline: 24 September 2026. Basis: accepted SOD 0004 and subsequent
user instructions.

#strong[Release decision, 25 September 2026: all 23 criteria are closed
for the stated three-fixed-voter production scope, incorporating the two
explicit user dispositions below.] The identified Linux binary is
`010338a4e2a8a8f9e4761d15b3d40b637a57b7a45f9d45ae7f73e3cbee5a1478`.
`benchmarks/results/verification-20260924/release-decision.json` binds
sources, artifacts and evidence. Throughput/p99 targets are future
improvement goals by owner approval. Large-capacity campaigns are not
required by the owner\'s subsequent instruction. Large-store startup
missed the original 60-second goal (114/137 seconds); capacity and
recovery guarantees beyond targeted checks are not claimed. Three
independent Linux instances were tested; independent physical
storage/failure domains were not established. Historical progress
paragraphs below retain their original status and failed samples; they
do not reopen or add release requirements.

This is the authoritative completion checklist for the first production
release. The older implementation ledger is historical evidence, not an
additional or expanding list of gates. There are exactly seven gates
below. All must close; passing unit tests alone does not close a gate.
No fixed number of hours, days or months is required. The book is
outside this work.

== Scope and change rule
<scope-and-change-rule>
Ship the native Odin SQL service and CLI, embedded library, and
`sqlodin` Python package with FTS/vector search and SQLAlchemy
transactions. Use the complete pinned paxos-odin library, static pinned
SQLite/FTS5, sqlite-vec and OpenSSL. The qualified distributed
deployment is three fixed voters on the authorized Linux instances
`.19`, `.20`, `.21`, accepting requests at every voter. Larger
workload/resource measurements run on `.18`\; local tests stay
lightweight. Record the actual virtualization/storage topology; do not
claim independent physical failure domains. Five-voter behavior remains
covered by core protocol tests, not advertised as a separately qualified
five-machine deployment.

Keep the current explicit SQL/API size limits unless a measured
requirement demands a versioned change. Production does not mean
unrestricted SQLite compatibility, unlimited transactions, or linear
throughput scaling with voters. Supported behavior must be usable
through the public CLI/API, not only through internal primitives.

Every defect discovered during implementation/testing must identify a
numbered criterion below, its reproducer and its fix. It does not create
another gate. New features and optional optimizations are deferred
unless needed to satisfy these criteria. A gate reopens only on a
concrete failing criterion, an affected dependency change, or invalid
evidence; preserve the original passing evidence. No numerical target,
SQL guarantee, fault assumption or gate may silently be weakened to
obtain a pass. Any proposed scope change must state the old and new
requirement and be an explicit user decision. This freezes requirements,
not a promise that testing can discover no further bugs.

== R1 --- SQL, transactions, reads and retry correctness
<r1--sql-transactions-reads-and-retry-correctness>
- ☒ R1.1 Freeze and enforce the supported SQL/schema/function/extension
  and ordering contract, including deterministic execution/resource
  handling. Replicas must not choose different outcomes because of local
  wall clocks, query plans or resource exhaustion. Unknown
  storage/execution failures fail closed. Version/fingerprint checks
  include the SQL policy and extension behavior.
- ☒ R1.2 Mixed SQL, constraints, triggers, FTS/vector operations, ORM
  commit/rollback/savepoints and conflicts agree with a serial
  reference. Grouped and reference commits have identical effects,
  rejection outcomes, request fences and restart behavior. No savepoint
  release acknowledges a write.
- ☒ R1.3 Unknown outcomes can be retried through another voter without
  duplicate effects. Session capacity/retirement remains bounded without
  reviving expired requests. Test full capacity and retirement/retry
  boundaries, not just fresh sessions.
- ☒ R1.4 Fresh quorum-backed reads and optimistic ORM transactions
  respect real-time order; minority/lagging voters cannot return
  successful stale linearizable reads. Check transaction and
  predicate-read histories, not just final balances or individual key
  values.

Existing evidence: transaction/group/retry/read regressions, ORM and
search integration suites, ReadFence model and stale-voter regression.
R1.2--R1.4 are complete as recorded below. R1.1\'s policy-9 schema
correction and compatibility checks are complete as recorded below.
Final-candidate qualification remains R7.

== R2 --- Multi-master progress and consensus reasoning
<r2--multi-master-progress-and-consensus-reasoning>
- ☒ R2.1 With each of the three voters absent in turn, both survivors
  continue durable writes and quorum reads. A minority cannot
  acknowledge either. Cover concurrent owners/revokers, owner skew,
  window exhaustion/reuse, message loss/reordering/duplication,
  pause/restart and reconnect.
- ☒ R2.2 Rejoining voters recover missed history or a certified snapshot
  without delaying the healthy quorum. No healthy-path write waits for
  the next 100 ms ownership tick. Failure detection remains distinct
  from immediate bounded local progress.
- ☒ R2.3 Complete the specified model/proof-to-code map for agreement,
  durability-before-visibility, application/outcome prefixes, grouped
  commits, fresh reads, trim and recovery. Include multi-slot
  rotating-owner progress under stated eventual-synchrony/fairness
  assumptions, negative controls, and executable regressions for
  counterexamples. Check inductive safety lemmas for unbounded history.

Existing evidence: published/pinned upstream progress fix, 81 upstream
tests, 1.8 million seeded fault steps, each-voter-absent implementation
checks, formal configurations and discharged abstract durable-history
obligations. The dated R2 completion record below adds the
rotating-window models, 36 prefix/recovery obligations, current-source
native checks and full composition/code map. The required refinement is
an explicit argument connecting actions/frontiers to code plus tests; a
machine-checked proof of the entire Odin compiler, SQLite, OS or
hardware is not an added gate.

== R3 --- Complete durable storage lifecycle
<r3--complete-durable-storage-lifecycle>
- ☒ R3.1 Implement the accepted format-5 application/consensus
  separation and offline format-4 migration into a new directory.
  Preserve source data, local identity, promises, votes, reserved IDs,
  chosen suffix, outcomes, retry fences and transaction revision. Refuse
  incompatible/missing state.
- ☒ R3.2 Wire the existing copy, logical verification, manifest, receipt
  and certificate primitives into one bounded live snapshot job.
  Authenticate voter receipts; choose a seal binding the complete
  certificate through the pinned Paxos library before authorizing
  retirement of history.
- ☒ R3.3 Publish/install recoverable generations, retain the required
  old generation, and preserve accepted/chosen suffix state and
  active-request/read fences. Crash at every write/sync/rename/
  publication/trim boundary: restart selects a valid old or new state
  and preserves acknowledged effects.
- ☒ R3.4 Enable safe trimming and snapshot catch-up beyond retained
  history. Exercise multiple snapshot/trim/restart cycles with growth, a
  slow voter and an offline voter. Default policy remains one job, 256
  MiB tail or 15 minutes dirty history, 1 MiB chunks, 32 MiB transfer
  buffers and an 8 GiB retained-history cap. Admission must protect
  reserves before exhaustion.

R3.1 evidence (24 September): separated stores are available through
`storage_format: 5` and `sqlodin migrate OLD-NODE.json NEW-DIRECTORY`.
Migration preserves source DB/WAL bytes, accepted votes, request
outcomes/fences, reserved IDs and chosen unapplied work. Completed
evidence in `benchmarks/results/verification-20260924/`:
`all-tests-separated-linux.json` (114 tests),
`migration-vote-linux.json` (additional accepted-vote regression),
`separated-local-final.json` (six focused tests), `migration-linux.json`
(four public CLI/service checks), `network-separated-linux.json` (14
service checks), and both `durability-separated-*.json` reports (22
crash cases each, grouped/reference). Source hashes:
`source-manifest-separated.json`. The local migration harness had a
corrected expected-row ordering failure; its prior reports remain.
Generation publication and trimming remain R3.3--R3.4; format-4 remains
the service default until then.

R3.2 evidence (24 September): an ordered host-only checkpoint splits
application batches and pins the exact applied prefix; a separate worker
copies/verifies/syncs the image. Receipts are bound to authenticated
mTLS voters and the independent configuration/engine identity. A
matching quorum\'s full certificate is chosen through Paxos and
recovered from the journal. The native `snapshot` request and Python
`request_snapshot()` report admission separately from certification
status. `all-tests-snapshot-host-linux.json` passes 117 tests;
`snapshot-service-linux.json` passes four native cases with 240 writes
during capture, full restart, one absent voter and return/catch-up.
`migration-snapshot-linux.json` rechecks all four migration cases with
that binary. Local host and service reports, the initial failed
receipt-wire attempt, and `source-manifest-snapshot-host.json` are
retained. Capture is explicitly requested; automatic cadence and
retention quotas remain R3.4/R5. R3.3 now permits certified generation
publication; automatic retirement of retained files remains R3.4.

R3.3 evidence (24 September): `sqlodin compact NODE.json` installs a
certified application image plus the local accepted/chosen suffix into a
new generation. A FULL root-catalog transaction publishes the validated
generation; previous files remain. Generation-aware startup refuses a
corrupt selected generation and retained generation directories cannot
become independent store roots. `generation-crashes-linux-v3.json`
passes 15 SIGKILL boundaries, including the uncommitted catalog
transaction, preserving acknowledged data, accepted votes, global
promises, ID reservations and retries. `generation-service-linux.json`
passes five public CLI/native checks across two cycles on three `.18`
processes (60 writes per cycle), and the lightweight local equivalent
passes. `generation-fences-*` checks displaced read tickets and
idempotent retry after old slot evidence is retired. The optimized suite
passes 119 tests in `all-tests-generation-linux.json`, with the
additional fence regression recorded separately.
`formal-generation-local.json` covers 651 states and four required
negative controls; `specs/generation-catalog.typ` maps the argument to
code. Source and earlier reports remain labelled in the evidence
directory. Remote snapshot transfer, scheduling and file retention are
R3.4; compaction currently requires stopping that voter. This is not
final release qualification.

Existing evidence: application-only pinned copy, typed logical digest
including FTS/vector and retry state, durable candidate/receipt
retention and recovery, certificate validation/codec and publication
ordering models. These are tested primitives, not a working live storage
lifecycle. This is the largest remaining implementation block, not a
newly introduced requirement.

R3.4 progress (24 September, still open): authenticated 1 MiB chunk
transfer now installs a certified generation after two compaction
cycles, including a 128 KiB/s link and an interrupted connection.
`snapshot-catchup-packed-linux.json` and the lightweight local report
pass catch-up, continued quorum writes and full restart; earlier
unpacked failures remain. Full optimized tests passed 122 cases before
flow-control/packing changes; the later debug Linux suite passed 124.
The peer codec preserves complete values with the existing lossless
journal packing and requires wire version 2. Background compaction pins
a separate journal reader, builds privately, then copies bounded deltas
before catalog publication. `all-tests-live-compaction-linux.json`
passes 126 tests; `live-compaction-local.json` and
`live-compaction-scheduled-linux.json` pass two live cycles,
offline-voter return and full restart. The scheduling test explicitly
uses a three-second test build; defaults remain 256 MiB/15 minutes. New
local descriptor tests preserve the exact predecessor and reject
descriptor corruption. Those metadata changes also pass the 128-test
`all-tests-descriptor-linux.json` suite and
`live-compaction-descriptor-linux.json`. The later maintenance-failure
regression checks fail-closed behavior instead of repeated failed
staging jobs. Safe superseded-file retirement and the 8 GiB
retained-history admission cap remain unfinished; this evidence does not
close R3.4 or constitute release qualification.

R3.4 generation-retirement increment: directory creation now has a
durable ownership inventory; retirement preserves the active generation
and its exact predecessor, handles abandoned builds, and refuses unowned
paths or corrupt inventory. Held database locks cause backpressure.
`formal-retirement-local.json` passes 889 states and four required
negative controls. The Linux suite passes 131 tests in
`all-tests-retirement-linux.json`\; later focused local tests add
preexisting-path protection and held-lock behavior.
`retirement-crashes-linux-v2.json` passes all three
deletion/sync/inventory-commit SIGKILL boundaries; both earlier fixture
failures remain alongside the 15 passing publication boundaries.
`live-retirement-linux.json` passes three live cycles,
superseded-generation cleanup, offline-voter catch-up and full restart.
Snapshot images, original-root files and aggregate history admission
still require completion; R3.4 stays open.

== R4 --- Recovery, backup and operator lifecycle
<r4--recovery-backup-and-operator-lifecycle>
- ☒ R4.1 Provide public, tested CLI operations for consistent backup,
  verification, restore and catch-up. Restore cannot silently
  clone/reset an acceptor identity or advertise incomplete state.
- ☒ R4.2 Provide a tested fenced replacement procedure for a lost
  voter/disk. The old instance cannot rejoin under forgotten promises.
  Test the supported coordinated upgrade/migration and rollback/recovery
  procedure; retain the original source and correct old binary where
  required.
- ☒ R4.3 Test certificate expiry/rejection and a documented coordinated
  certificate renewal procedure, configuration/engine mismatches,
  startup readiness and actionable failure diagnostics.

R4 is complete; the dated completion record below identifies
backup/restore, fenced replacement, migration/rollback and certificate
lifecycle evidence. Automated enrollment, live resizing and rolling
upgrades remain deferred. Final-candidate reruns remain R7.

== R5 --- Bounded resources, overload and storage failures
<r5--bounded-resources-overload-and-storage-failures>
- ☒ R5.1 Bound admitted clients/handshakes, requests, results, queues,
  sessions, background work and retained files. Reserve service capacity
  for consensus/catch-up so client overload cannot exclude peers. Apply
  fair scheduling and return precise backpressure/unknown-outcome
  responses.
- ☒ R5.2 Demonstrate bounded memory/queue behavior at and above measured
  capacity, with slow readers, stalled peers, expensive permitted SQL
  and concurrent snapshots. Measure CPU and copying/allocation costs;
  eliminate unbounded accumulation and unintended busy loops.
- ☒ R5.3 Exercise disk-full/short-write/sync failure, interrupted files,
  corruption and process kills at actual persistence boundaries.
  Preserve acknowledged data and fail closed; recover after repair using
  the supported procedure. Distinguish injected failures from real
  power-loss certification.

Existing evidence: bounded frame/result/window limits, snapshot budgets,
SQL read limits and 22 historical crash cases. End-to-end peer
admission, growth/retention and storage-fault coverage remain.

== R6 --- Measured durable mixed-workload performance
<r6--measured-durable-mixed-workload-performance>
- ☒ R6.1 Use on-disk FULL durability and matched local SQLite
  references. Run 70/30 primary mixed transactions plus 50/50, 95/5 and
  pure-write profiles, 1/8/32/64 clients, 1--8 statements and 1--4 row
  changes, typical 256-byte values plus the separate 4 KiB profile.
  Include skew and all-voter entry. Record offered/completed rates,
  successful writes, rejections/timeouts, latency distributions,
  CPU/RSS, sync/byte amplification, lag and history growth. Retain
  failed samples.
- ☒ R6.2 Calibrate the SOD\'s provisional hardware-dependent targets
  against measured disk/RTT/SQLite capacity before tuning; preserve the
  original numbers and report any proposed change explicitly. Original
  goals: 3,000 mixed transactions/s (900 writes/s), 1,000 pure-write
  transactions/s, read/write p99 20/50 ms, and 25% of matched SQLite
  throughput. These are not achieved guarantees. Do not turn optional
  async I/O, a new consensus algorithm or compact transport into
  independent gates; select mechanisms by the measured bottleneck and
  accepted workload targets.
- ☒ R6.3 Check the existing SOD resource/recovery goals: 512 MiB voter
  RSS for the short-query profile, 8 GiB retained history, restart
  within 60 s for a local snapshot plus at most 1 GiB tail, and quorum
  service recovery within 5 s after one crash under the declared LAN
  conditions. Use targeted resource, snapshot/recovery and fault tests,
  with formal safety/progress evidence. By explicit user direction on 25
  September, large-capacity growth campaigns are not release
  requirements. Retain the original capacity and recovery observations,
  including unmet goals; do not claim that bounded tests establish
  unmeasured database sizes or recovery latencies.

Existing evidence: sync attribution, matched grouping improvements and
bounded native workloads. Latest healthy mixed throughput improved, but
degraded throughput regressed. This gate is open; production correctness
does not imply the requested performance goal is met. No elapsed soak
gate.

== R7 --- One final release candidate and reproducible evidence
<r7--one-final-release-candidate-and-reproducible-evidence>
- ☒ R7.1 Run the affected regression checks while implementing R1--R6.
  Then qualify one identified final source/dependency/build combination:
  complete Odin/core/upstream checks, formal checks,
  storage/fault/history checks, native CLI, Python/FTS/vector/SQLAlchemy
  and static linkage/package tests. Retest a closed criterion when its
  implementation or dependencies change, not after unrelated edits.
- ☒ R7.2 Run bounded fault/workload checks on the three authorized Linux
  instances, targeted Linux tests on `.18`, and light local tests. Use
  event/work/data limits and watchdogs; no obligatory 8-hour, 24-hour,
  seven-day or month-long run. Preserve exact source hashes, seeds,
  environment, commands, raw results and failures. Older binaries\'
  evidence stays labelled as historical.
- ☒ R7.3 Record each criterion\'s evidence and supported deployment/API
  limits here; close the seven gates once. Publish an honest release
  decision without adding an eighth gate or starting another open-ended
  review. Concrete defects affecting this contract remain fixes under
  their existing IDs.

Latest primitive-level baseline: 109/109 optimized Odin tests on `.18`,
5/5 focused debug tests locally, style/vet checks;
`benchmarks/results/verification-20260924/` contains the reports and
`source-manifest-snapshot-retention.json`. This is not final R7
qualification.

== Execution order and reporting
<execution-order-and-reporting>
+ Finish R3 end to end, including the split-store atomicity/replay
  design and migration. Stop adding disconnected snapshot primitives.
  Exercise crash recovery before enabling deletion.
+ Complete R4 using that storage lifecycle; complete R1 and R5 on the
  resulting service.
+ Close R2\'s integrated reasoning/progress tests against those
  implementations.
+ Calibrate/optimize/measure R6, rerunning affected correctness checks
  for actual changes.
+ Run R7 once on the final candidate and record the release decision.

Progress reports name criterion IDs, completed behavior, passing
evidence and the remaining count. They do not introduce another roadmap.
R1.2--R1.4, R2.1--R2.3, R3.1--R3.4 and R4.1--R4.3 are complete; R2, R3
and R4 are closed. 9 of 23 acceptance criteria and four gates remain
open, with substantial existing evidence as listed above. Optimizations
and features outside this contract go to a later release: automated
dynamic membership/enrollment, rolling upgrades, sharding, new consensus
algorithms, general SQLite feature parity, and documentation/book
redesign.

R3.4 retention/quota increment: disposable per-slot outcomes are removed
in private replacement images while retry session results/fences and
transaction revisions remain intact. Image ownership is committed before
file creation; deletion protects the active image, exact predecessor and
any receipt without a chosen successor.
`formal-image-retirement-local.json` checks 6,373 states and three
required negative controls; `specs/image-retirement.typ` records the
argument and its limits. `all-tests-image-retirement-linux.json` passes
136 tests, `image-retirement-crashes-linux.json` passes three SIGKILL
boundaries, and `live-image-retirement-linux.json` passes three live
cycles, protected-path checks, offline catch-up and restart. Root
application cleanup passes the local regression and all three
`root-retirement-crashes-linux.json` boundaries; its earlier fixture
failure is preserved. The root consensus file remains the required
catalog and is included in accounting.

Aggregate history admission now counts root/retained/staged consensus
DB, WAL, rollback and shared memory files against 8 GiB. New writes and
fresh read barriers leave reserved capacity; every journal record and ID
reservation has a harder persistence guard. Detached generation writers
share the same accounting scope. Corrupt/missing ownership fails closed.
Free-space checks cover the separate snapshot destination as well as
live/staged stores. Local sparse-file tests check pressure rejection, no
state change on rejected admission, cleanup/re-admission and promise
recovery after hard rejection; sparse extents are not large-dataset
capacity evidence. `all-tests-history-space-linux.json` passes 140 tests
and `live-history-space-linux.json` passes integrated
cleanup/catch-up/restart. The later 142-test Linux suite passes in
`all-tests-history-final-linux.json`\; slow interrupted transfer and all
26 publication/retirement crash boundaries passed in
`snapshot-catchup-history-linux.json` and
`generation-retirement-history-crashes-linux.json`. The subsequent
codec-scaled reserve and format-5 service default passed focused local
tests and all three `storage-default-reserve-linux.json` checks.
`network-storage-lifecycle-linux.json` passes all 14 native
CLI/Python/authentication/quorum/retry/restart checks. Exact sources are
recorded in `source-manifest-storage-lifecycle-linux.json`, with earlier
increments separately identified. R3.4 and R3 are now closed.
R1/R2/R4/R5/R6/R7 are unchanged; this does not create an additional gate
or establish production readiness. Existing format-4 stores require
explicit `storage_format: 4` for source access/migration; omitted format
now selects 5. R5 fault/resource qualification and R6 physical
capacity/performance measurements remain under their existing criteria;
sparse quota fixtures do not substitute for those measurements.

R4 completion evidence (25 September): public `backup`, `verify-backup`
and fenced `restore --new-cluster` operations preserve the application
prefix and retry state without importing donor acceptor state.
`backup-service-linux.json` passes five native checks and
`backup-crashes-linux.json` passes nine process-crash boundaries.
`restore-service-linux.json` passes five recovery scenarios including a
lost directory, mismatched genesis, old-instance isolation, every-voter
writes, compaction and restart; `restore-crashes-linux.json` passes
eight publication boundaries. `all-tests-restore-linux.json` passes 146
tests; focused local empty/ nonempty restore checks and five
`formal-restored-genesis-local.json` configurations pass. Exact
pre-renewal source hashes are in `source-manifest-restore-linux.json`\;
native reports record their own source/binary hashes. Earlier fixture
failures remain preserved.

`certificate-lifecycle-linux.json` passes six expiry, mismatch,
readiness, coordinated CA/key/ leaf renewal and retry/restart checks.
`mtls-renewal-linux.json` passes 15 native TLS cases.
`migration-rollback-linux.json` passes five cases using the retained
storage-lifecycle binary for preactivation rollback, new acknowledged
source writes, fresh remigration and upgraded restart. Both binary
hashes are retained. The first primitive TLS launch lacked Odin on PATH;
no test ran in that attempt; the corrected invocation passed. Local
strict/vet and style checks pass. `specs/recovery-bootstrap.typ` is the
operator procedure and initial-state argument. Replacement requires a
globally unused namespace, fencing the old group and restoring every
voter from the identical backup. Rollback is allowed only before
new-voter activation; later recovery uses a forward fix or a verified
backup cut. Existing TLS sessions are closed by the coordinated renewal
procedure. These are the fixed supported procedures, not claims of live
membership changes, rolling upgrades or physical power-loss testing. R4
is closed; R1/R2/R5/ R6/R7 and final-candidate qualification remain
open. The book has not been touched.

R5.1 admission increment: native service now caps authenticated clients
at 24 per voter and bounds incoming handshake/rejection work to four
connections, leaving four slots for fixed peers. Excess authenticated
requests receive `Busy` before submission and close after the response
drains. `admission-local.json` passes the capacity boundary regression.
`admission-linux-v2.json` passes five cases: full client pools on all
voters, writes through all nodes, survivor progress with stalled
handshakes and one crash, peer reconnect/catch-up, and capacity reuse.
Two survivor writes took approximately 65 ms in this sample; this is not
an R6 throughput measurement. The initial harness incorrectly expected
the Python API to expose Busy directly despite its existing bounded
retry behavior; that failure is preserved.
`all-tests-admission-linux.json` passes 147 Odin tests and
`network-admission-linux.json` passes all 14 native service cases. These
checks address admitted-client overload, not resilience against
unlimited unauthenticated network floods. Broader R5 resource/fault
qualification remains open. No additional gate has been introduced.

R5.2 worker increment: snapshot copying and physical/logical
verification now accept an atomic cancellation flag; shutdown requests
cancellation before joining the snapshot worker. Cancellation is checked
between bounded copy/hash chunks and in SQLite progress callbacks, and
cannot issue a receipt from an incomplete job. It cannot interrupt a
kernel call blocked on a failing device. The focused local cancellation
checks and all 148 Linux tests pass in
`all-tests-cancellation-linux.json`.
`live-compaction-cancellation-linux.json` passes three live cycles,
retention, offline catch-up and restart. Generation-worker cancellation
and the remaining load/resource campaign are still R5 work; this
increment does not close R5.2.

R5.3 storage-error increment: `storage-faults-linux.json` passes six
Linux cases injecting ENOSPC, a partial write followed by EIO, and sync
EIO against both consensus and application WALs. Each case proves the
injector reached its exact target, checks that the failed voter exits
without acknowledging the affected request, resolves the same pending
identity through a survivor, rejoins the repaired voter and restarts the
full cluster. Previously acknowledged values and exactly-once effects
survive. The injector is a test-only shared object, never linked into a
release binary; original injector/harness sources and report hashes are
retained. These are controlled syscall failures on the recorded
disk-backed filesystem, not physical disk-full or power-loss
certification. Existing corruption/crash evidence remains separately
labelled; broader R5/final-candidate coverage is still open.

The focused `storage-partial-write-linux-v2.json` rerun also records
actual partial-write byte counts for both WALs before EIO; both recovery
cases pass. This strengthens the injection evidence without changing the
production binary.

R1.3 completion (25 September): a replicated monotonic epoch now fences
reclaimed session identities. Explicit retirement atomically advances
the epoch and removes the bounded session rows; clients never relabel an
unresolved write. Python `session_epoch()`/`retire_sessions()` and CLI
`.session`/`.retire-sessions E --quiesced` provide the public lifecycle.
The CLI saves epochs with pending state and gives corrective Expired
diagnostics. Operators quiesce clients and resolve pending results
before retirement; new connections/state files are for new work.
Existing per-session sequencing and 65,536-session capacity remain
unchanged.

`all-tests-session-final-linux.json` passes 152 tests including actual
full capacity, reclamation, grouped/reference histories, restart and
canonical legacy metadata conversion. Focused local checks and all 30
Python unit tests pass (`python-session-local.xml`). The bounded model
checks 84 states and four required negative controls in
`formal-session-retirement-local-v3.json`\;
`specs/session-retirement.typ` gives the induction argument and code
map. Earlier unsupported TLC configuration and sandbox-listener failures
remain separately recorded.

`session-retirement-service-final-linux.json` passes four integrated
Python/CLI scenarios with an absent voter, stale retries, idempotent
retirement, compaction and backup/restore. It also verifies R1.2\'s
concrete active-generation preview fix after a post-publication revision
change. `session-retirement-crashes-linux.json` passes five
journal/application/acknowledgement SIGKILL boundaries.
`network-session-final-linux.json` passes 14 native cases;
`orm-session-final-linux.json` passes 26 native/ORM cases (its
hard-coded policy label is corrected by the separate immutable
report-hash-bound policy erratum). Minority-write setup now prepares its
request identity before isolation, so it still exercises uncertain
writes; unavailable epoch discovery is separately verified to leave no
submitted/pending write. Earlier fixture failures remain preserved.

Policy 7 and wire 3 require coordinated maintenance. Epoch-zero hashes
and legacy journal encoding remain recoverable. The retained policy-6
binary\'s rollback/remigration passes in
`migration-session-final-linux.json`\; its real format-5 backup
restores, deduplicates its original request, retires epoch zero and
restarts in `legacy-epoch-restore-linux.json`. Thus the affected R4
compatibility paths were rerun rather than assumed. Exact native
sources/binary and locked Python dependency provenance are in
`source-manifest-session-final-linux.json`. R1.3 is closed; R1.1, R1.2,
R1.4, R2, R5, R6 and R7 remain under their original criteria. No book
work or new gate.

R1.1/R1.2 SQL-policy increment (25 September): policy 8 rejects
mixed-case pragma virtual-table reads that previously allowed
connection-local data\_version to enter replicated writes. The original
two-row counterexample is preserved in `pragma-case-local.json`.
INSERT/UPDATE/DELETE RETURNING is now rejected before execution,
matching the write API\'s outcome-only contract. The catalog-rowid
boundary and grouped/reference FTS/vector/trigger inserts, updates,
deletes and row reuse pass focused local tests.
`all-tests-policy8-final-linux.json` passes 154 tests,
`orm-policy8-linux.json` passes 27 native/ORM checks, and
`restore-policy8-linux.json` passes legacy-backup retry/epoch conversion
and restart. The preceding policy-7 rollback/remigration also passes in
`migration-policy8-linux.json`. Exact sources and binary are in
`source-manifest-policy8-final-linux.json`\; locked Python dependency
provenance is retained in `python-qualification-wheels.json`. R1.1/R1.2
remain open for the other already-listed contract/history obligations;
no gate is added.

R5.2 generation-worker increment (25 September): shutdown now signals
cancellation before joining private generation work. Image verification,
bounded copy chunks, journal/application replay and SQLite VM progress
callbacks observe cancellation; callbacks are removed before a built
host transfers to the service owner. Cancellation cannot become a
replicated SQL rejection or publish an incomplete generation.
`generation-cancel-local.json` passes the seven-boundary
cancellation/lock-release regression and two background/restart checks.
`all-tests-generation-cancel-linux.json` passes 155 tests;
`live-generation-cancel-linux.json` passes three live cycles, retention,
absent-voter catch-up and full restart.
`generation-cancel-crashes-linux.json` passes 11 affected persistence
boundaries. Exact sources are retained in
`source-manifest-generation-cancel-linux.json`. Cooperative cancellation
cannot interrupt an operating-system call blocked on a failing device.
R5.2\'s load/resource campaign remains under its existing criterion.

R1.4 completion (25 September): `transaction-history-linux.json` and
`transaction-history-readonly-linux.json` each pass 16 concurrent
batches, comprising 144 recorded operations plus 15 rejoin/restart
reads. The two seeds cover every voter absent, both surviving entry
points, native fresh predicate reads, successful writing transactions
and read-only ORM transactions. An exhaustive independent set-state
model finds a serial witness respecting every response-before-invocation
edge and all successful before/after predicate observations. Raw
serialization aborts remain recorded (48 and 56 respectively);
unclassified failures would fail the campaign. Negative controls reject
stale predicates after a completed write and committed write skew. The
corresponding light local runs pass four batches each; the initial local
socket-permission failure is retained. The original first harness is
archived as `check_transaction_history_v1.py`\; the expanded report
hashes its own harness. `specs/transaction-order.typ` gives the
marker/revision/code argument and explicit assumptions. Existing
ReadFence model/negative controls, stale-ticket regressions, 27
native/ORM checks and minority rejection complement these histories.
Exact current source/build hashes are in
`source-manifest-sql-contract-linux.json`. R1.4 is closed;
final-candidate qualification remains R7. Fourteen criteria remain.

The R1.1 extension identity increment also passes
`extension-identity-local-v2.json` and `extension-identity-linux.json`:
a real engine opens the pinned archive and refuses an otherwise loadable
archive with a mismatched build stamp. Policy 8 fixes the hash of
sqlite-vec\'s verified source and compiler flags; the stamp is compiled
in that same translation unit. Registration failure now fails engine
startup. `all-tests-extension-identity-linux.json` passes 155 tests and
`python-extension-identity-linux.json` passes 22 native/search/API
checks. All 30 local Python tests pass. Initial minimal-probe vet and
missing-offline-cache failures are preserved; the successful Linux
rebuild uses hash-verified existing source files. R1.1\'s remaining
SQL/resource contract obligations are unchanged.

R1.2 completion (25 September): `group-both-formats-local.json` and
`group-both-formats-linux.json` pass grouped/individual comparison of
192 mixed requests per storage format, including periodic reopen, all
outcomes, data/trigger rows, generated keys, session fences, revision
and epoch. The same reports include 32 FTS/vector/trigger transactions
and complete logical snapshot equality.
`durability-policy8-group-linux.json` and
`durability-policy8-reference-linux.json` each pass all 22 process-kill
cases on separated storage, covering successful and rejected
transactions, application groups, journal groups and acknowledgement
boundaries. `orm-policy8-linux.json`, the search suite, session-epoch
regressions and R1.4 histories supply the public API, conflict,
savepoint and retry evidence. `specs/grouped-sql.typ` maps the
savepoint/reference-fallback argument to the code and its explicit
assumptions. R1.2 is closed. Thirteen of 23 criteria remain open across
the same five gates; R1.1, R2, R5, R6 and R7 are unchanged.
Final-candidate reruns remain R7, with no book work or elapsed soak
requirement.

R2 completion (25 September): `majority-policy8-linux.json` passes 90
native operations with each voter absent, alternating both survivor
entry points, exceeding the 64-slot window, rejoining the missing voter
and restarting all three. The first survivor write after each crash
completes in 0.89, 2.35 and 1.96 seconds in this sample; these are fault
checks, not throughput claims. `progress-policy8-local.json` and
`progress-policy8-linux.json` pass the zero-tick healthy-owner
regression; the Linux report also passes multi-window catch-up without
new client traffic. Current policy-8 live-generation evidence supplies
certified-snapshot recovery with continuing quorum writes. Earlier
slow/interrupted-transfer evidence stays separately labelled.

`consensus-policy8-linux-v3.json` passes all 81 pinned upstream tests
and 180,000 seeded SQLodin fault steps across one, three and five nodes
(18 runs). It records source/simulator hashes and verifies the Git-free
remote dependency copy against `paxos-qualification-source-pin.json`,
generated from the clean published pin. The initial Git-metadata
assumption and missing-simulator checkout failures remain in the v1/v2
reports. These simulations test transport ordering/loss/duplicates and
restart; the separate durable crash matrices test actual storage
boundaries.

`formal-rotating-linux-v3.json` passes concurrent producers (737,901
states), repeated window reuse, every absent voter, and four required
skip/revocation/release/reuse negative controls. The small local cases
also pass. Earlier complete-state timeouts remain failures, not passes.
For the all-producers/no-failure configuration only, normalizing the
unused highest-seen field removes observationally equivalent states; no
vote, quorum, window, application action or liveness property was
weakened. The unreduced source is archived with the failed reports.
Skewed/failed-owner cases retain independent observation order. The
initial negative-control precedence error in the model is likewise
preserved and corrected.

`formal-prefix-proof-linux-v3.json` discharges all 36 unbounded
prefix/trim/replay induction obligations. Combined with the existing 12
durable-history obligations, per-decree quorum-intersection argument,
storage/publication models, grouped SQL, read/retry arguments and
executable counterexample regressions, this completes the specified
composition/code map in `specs/multimaster-refinement.typ`. Initial
proof failures remain; no omitted proof steps are used. Liveness
explicitly assumes a surviving majority, eventual successful
retransmission, fair admitted work, and an eventually non-preempted
exchange fitting the configured LAN election interval. It does not
assert wait-free progress under endless interference or prove arbitrary
SQL determinism; R1.1/R5/R6 retain their separate obligations. R2 is
closed. Ten criteria across R1, R5, R6 and R7 remain; final
three-machine qualification is R7.

R5.3 completion (25 September): `storage-errors-policy8-linux.json`
reruns all six exact-WAL ENOSPC, partial-write/EIO and sync-EIO cases on
the current candidate. Every injector reaches its target, the failed
voter cannot acknowledge, survivor retry has one effect, repair/rejoin
succeeds, and full restart preserves acknowledged data. The byte-counted
partial-write evidence remains in the earlier v2 report. Together with
the 44 current separated-store transaction/group crash cases, the
backup/restore/publication/retirement crash matrices, and current
corruption and incomplete-state regressions, this closes R5.3.
`specs/resource-contract.typ` states the fault boundary and supported
recovery assumptions. These are process and injected syscall tests, not
physical power-loss certification. Nine criteria remain; R5.1/R5.2
resource qualification and final-candidate reruns retain their original
scope.

R1.1 completion (25 September): `specs/sql-policy.typ` freezes the
supported schema/function/extension, ordering and resource-failure
contract. Its refinement argument ties identical ordered
SQL/schema/parameters to the pinned engine\'s planner inputs, logical
B-tree ordering, function/collation behavior and blocked
local-state/random dependencies. The qualified deployment uses one Linux
x86-64 release build; local macOS tests do not qualify
mixed-architecture floating-point replication. Unknown
execution/resource failures withhold acknowledgement and require
repair/replay; local timeouts cannot become divergent committed
rejections. Arbitrary SQL has no constant-latency guarantee. These are
explicit execution and fault assumptions, not additional release gates
or a proof of SQLite/compiler code.

`sql-ordering-reopen-local.json` and `sql-ordering-reopen-linux.json`
pass ten query-sensitive writes across stores with different page
layout/cache residency and connection reopen schedules, comparing every
outcome and complete logical image digests. Indexed/unordered/ordered
selection, subqueries, grouping, joins, UNION, trigger order and
generated keys are covered. `sql-ordering-local.json` retains the
preceding layout-only check; `sql-ordering-source.json` binds sources.
The policy-8 pragma counterexample/fix, extension identity negative
control, R1.2 grouped/reference/FTS histories and R1.4 transaction
histories supply the remaining contract evidence. R1 is closed; R5, R6
and final-candidate R7 remain.

Resource-evidence correction: the first resource harness omitted
`timeout_ms` from pipelined slow-reader queries. Thus
`resource-load-policy8-linux.json`, `resource-load-extended-linux.json`
and `resource-profile-linux-v2.json` establish admission, mixed work,
snapshot, memory and allocation observations but do not establish
large-response slow-reader backpressure. Their raw evidence remains. The
corrected harness validates a 120,000-byte result on each slow
connection before pipelining valid requests. The zero-allocation v1
profile also remains a failed instrumentation check; allocator contexts
must be installed in the service procedure, not only in a helper\'s
local context. These are R5 harness corrections; no new gate or
production SQL change is introduced.

R5.1/R5.2 completion (25 September): the corrected ordinary campaign
`resource-load-slow-readers-linux-v3.json` passes 3,840 operations with
full 72-client admission (60 active plus 12 slow readers), twelve
authenticated excess rejections, stalled handshakes, expensive limited
reads, a permitted aggregate write, and concurrent snapshot/generation
work. Each slow connection first verifies a 120 KB result. Peak voter
RSS is 29--35 MiB; later sampling quarters remain below the initial
peak. Every acknowledged update agrees and all three voters publish the
snapshot generation. Existing absent-voter/full-pool admission and
slow/interrupted catch-up checks cover reserved peer progress.

`resource-profile-slow-readers-linux-v3.json` passes the same bounded
workload with functioning Odin heap/temporary trackers, explicit
frame-copy counters and SQLite heap peaks: approximately 37--41 thousand
heap allocations, 15.1 MB tracked heap peak, 15.2 MB SQLite heap peak
and 20 MB frame copying per voter. Counters have explicit coverage;
instrumented timing is not used as production throughput. The earlier
ordinary idle samples show at most about 1% of one core. Bounded
framing/nesting, client/handshake/queue pools, sessions, transition
windows, maintenance jobs/inventories/history quotas, cancellation and
fail-closed storage handling supply the code argument in
`specs/resource-contract.typ`. The Linux JSON-depth/service checks and
local strict/vet/style checks pass. The old harness versions and
corrected failures remain labelled. R5 is closed; only R6 and R7 remain,
six criteria under the same fixed contract. Mixed-workload performance,
large-dataset capacity and final-candidate qualification are not implied
by R5.

R6 calibration/implementation increment (25 September):
`mixed-calibration-linux.json` records eight bounded on-disk FULL cases
using the exact pinned SQLite archive and an optimized native binary. It
covers 1/8/32/64 clients with 70/30 and pure-write profiles, verifying
acknowledged increments on every voter. Native rates range from 20 to
332 transactions/s; the 32-client samples regress to 48 mixed and 30
pure-write transactions/s. This is one-statement calibration, not the
complete R6 matrix, open-loop p99 qualification, matched group-commit
baseline or large-data qualification. The original targets are unchanged
and are not met by these samples.

The service now uses the existing durable batch-proposal wrapper for at
most sixteen already-received writes, with no batching timer or extra
queue. It shrinks atomically rejected batches on window pressure and
rotates admission priority. Acknowledgement still requires the durable
application outcome. The initial integration passes 158 Odin tests and
15 native service checks. The first local window fixture expected a
different halving sequence; its failure is retained, and the corrected
regression passes. Round-robin window/fairness checks pass locally and
the window check passes on Linux. Final round-robin integration
histories, workload comparison and affected qualification checks remain
pending; prior closed-gate evidence is not claimed to qualify this new
candidate. The code argument is `specs/service-batching.typ`\; R6/R7
remain open without new criteria.

R1.1 closure correction: `schema-snapshot-counterexample-local.json` is
a concrete failure of the existing SQL/schema contract. Policy 8
acknowledged a rowid table shadowing all three hidden-rowid aliases; the
snapshot verifier then correctly refused to certify it. The earlier R1.1
closure was premature for this edge case. R1.1 is reopened under the
fixed contract\'s concrete-counterexample rule, not a new criterion.
Policy 9 now validates the final schema inside the request\'s
transaction/savepoint and on startup/migration, rejecting incompatible
DDL and its accompanying DML atomically. Unknown validation errors fail
closed.

The expanded regression also exposed catalog checks rejecting ordinary
DROP. Policy 9 permits SQLite\'s internal DROP/ALTER catalog reads only
within that prepared maintenance statement, excluding trigger/view
expressions and resetting permission before the next statement.
`schema-snapshot-policy9-mixed-local-v4.json` passes individual/grouped
schema histories, rollback, WITHOUT ROWID, DROP/index maintenance and
catalog-leak negative controls; earlier failed variants remain. The
extension contract is unchanged, but the semantic policy is bumped to
prevent mixed-policy replication. Runtime status now reports the actual
policy; affected qualification tools no longer hard-code policy 8. Linux
unit/integration and retained-policy upgrade/restore qualification are
in progress before reclosure.

R1.1 policy-9 reclosure (25 September): `all-tests-policy9-linux.json`
passes 160 tests, with the additional legacy-schema repair regression
passing separately. `network-schema-policy9-linux-v2.json` passes 16
public checks, including atomic rejection of incompatible DDL plus DML
and reporting actual policy 9. The prior report\'s missing Python status
field remains a failed integration sample; the client now exposes the
server policy. `orm-policy9-linux.json` passes 27 checks but predates
that status filter fix, so its null policy field is not rewritten.
`migration-policy9-linux.json` passes five retained-policy-8
upgrade/rollback checks; `restore-policy9-linux.json` verifies policy-8
backup restore and original request deduplication under policy 9. This
particular restore source is policy 8, not a pre-epoch source; earlier
genuine policy-6 restore evidence remains separate.
`resource-io-policy9-linux.json` passes the corrected
slow-reader/resource campaign. The pre-cohort candidate is bound by
`source-manifest-policy9-pre-cohort-linux.json`. R1.1 is closed again on
this concrete correction; six criteria in R6/R7 remain. The read-cohort
optimization receives affected regression checks before release.

R6 read-cohort increment (25 September): a closed cohort of already
accepted reads shares one newly proposed quorum marker; later arrivals
require another marker. Cancellation preserves other waiters, and no
application transition interleaves marker validation and member
snapshots. `specs/transaction-order.typ` maps this to the existing read
proof. `formal-read-cohort-local.json` checks 180,443 states and all
three required negative controls; `read-cohort-local.json` passes
concrete quorum/cancellation and completed-write/later-read regressions.
`all-tests-read-cohort-linux.json` passes 163 tests. Public service,
ORM, exhaustive predicate histories with each voter absent, and
corrected resource/snapshot/I/O campaigns pass in the corresponding
`*-read-cohort-linux.json` reports. Throughput calibration and final
identified-candidate qualification remain R6/R7.

R6 calibration evidence (25 September): the optimized read-cohort
candidate\'s small samples range from 132 to 1,585 mixed transactions/s
and 103 to 925 pure writes/s. A separate seed/reference-grouping run is
also highly variable. These peaks do not establish sustained
performance. The 25,600-operation-per-profile
`mixed-calibration-read-cohort-extended-linux.json` measures 219.5 mixed
and 125.2 pure-write transactions/s, against 2,520.5 and 2,319.4 for the
pinned FULL SQLite reference with at most sixteen already-waiting
requests per commit. Native sync calls average 9.0 ms mixed and 9.8 ms
pure-write; their summed duration per voter is approximately 78--83% of
measured elapsed time (whole-process counters also include
startup/validation/shutdown). The forwarding profiler reports no errors.
The original throughput, p99 and relative goals are unmet by this
sample. Disk wait and insufficient amortization remain measured R6
issues, not new gates. The fixture is small; these results do not
substitute for capacity qualification.

R6.3 capacity increment: the 16 MiB public-API harness fixture passes
snapshot publication and full restart (1.28 s); the separate 10 GiB run
uses the preceding read-cohort binary and remains distinct evidence.
Preparing the planned larger profile identified an arithmetic limit: 100
GiB of 4 KiB rows requires 26,214,400 rows, exceeding the old
verifier\'s ten-million-row budget. The local worker budgets now permit
32 million rows, 4 GiB disk scratch, eight billion VM steps and 3,600 s
per verification pass, with unchanged 128 GiB image and 2/8 MiB cache
limits. Digest encoding and publication authority are unchanged. Five
focused logical-budget, page-layout, extension and cancellation tests
pass locally in `capacity-budget-local.json`\; Linux qualification of
this limit change is pending. These are work ceilings, not new
elapsed-soak gates or evidence of tested capacity.

R6.3 10 GiB evidence: `capacity-10gib-linux.json` passes 2,621,440
public-API inserted 4 KiB payload rows, row-count and sampled-content
checks on all voters, certified generation publication, 90 further
indexed write/read pairs, full restart and post-restart verification.
Payload is 10 GiB; measured aggregate allocated files grow from 36.33 GB
before capture to 108.82 GB after publication across the three voters
and their retained/staged lifecycle. It is not a sparse file or memory
database. Snapshot publication takes 378.3 s; restart takes 14.89 s.
Peak RSS is approximately 35--36 MiB per voter. `check_capacity_v1.py`
archives the exact passing harness. This run uses the
pre-budget-increase read-cohort binary; the current candidate separately
passes all 163 Linux tests and static linkage. The larger growth run
will identify its own actual capacity and recovery times.

R7 packaging increment: the rebuilt local pinned SQLite/FTS5, sqlite-vec
and OpenSSL dependencies pass all fifteen mTLS checks in
`mtls-rebuilt-local.json`. `python-wheel-local.json` and its JUnit XML
record an actual uv-built wheel, installed into a separate environment
with hash-locked test dependencies, passing all thirty
Python/API/vector/SQLAlchemy tests. The import path is asserted to be
inside the wheel environment, not the editable checkout. Both native
candidates pass static SQLite/extension/TLS linkage inspection; OS
runtimes may remain dynamic. These increments do not close R7 before the
remaining identified-candidate checks.

R7 current-source binding: `formal-current-source-binding-v2.json`
verifies all 59 required model configurations against byte-identical
current TLA/configuration sources, pinned TLC output and each named
negative control. It also binds the 12 durable-history and 36
prefix/recovery TLAPS obligations to unchanged source and the pinned
proof distribution. This reuses valid unchanged proofs; it does not
claim a fresh checker execution or a compiler/OS proof. The first
collector report missed the older proof report\'s absent model-name
metadata; the v2 collector identifies it by its exact source hash and
records no missing cases. The earlier collector report remains.
`cli-capacity-final-local.json` passes all 28 actual
CLI/local-shell/network-shell cases, including lost-response and
state-file tests.

R6.1 completion (25 September): `workload-matrix-linux.json` and its 32
hashed per-case reports verify 91,840 operations against the pinned FULL
SQLite reference. The finite coverage matrix includes all four client
counts and read/write ratios, 256-byte and 4 KiB values, one/four/eight
statements, one/two/four changed rows, hot-key skew, all-voter entry,
repeated seeds, and scheduled 3,000 mixed/1,000 pure-write arrivals. Raw
invocation/scheduled/completion timestamps, failures, CPU/RSS, process
I/O, forwarding sync/write counters, frontiers and history sizes are
retained. No unknown outcomes or operation errors occurred in these
samples. This is coverage, not an exhaustive Cartesian product or
sustained-rate guarantee.

`workload-matrix-analysis-linux.json` derives observations from
hash-checked raw samples: peak voter RSS 21,434,368 bytes, aggregate
native CPU 0.087--0.572 cores, and whole-process mean sync latency
5.5--21.2 ms. The single-copy reference has no TLS/replication overhead;
both use the same pinned engine, FULL durability and at most sixteen
already-waiting requests per commit. Sync/pwrite counters include setup
and validation; process CPU/I/O differences bracket the workload
interval. The original throughput, relative-throughput and p99 targets
remain unmet. R6.1 closes measurement coverage only; R6.2/R6.3 and R7
remain open.

R7 retained failures: the first current-candidate three-host campaign
passed 33 SQL/search/ORM checks and the absent-voter-1 case, then timed
out on operation 64 with voter 2 absent. Its first post-crash write had
completed in 1.33 seconds; the run lasted under three minutes, before
the five-minute supervisor watchdog. The second attempt encountered an
unopened node-3 listener during initial setup. Both JSON reports and
remote data directories remain. The harness now waits for listener
readiness separately from unchanged five-second majority-operation
deadlines, and records operation timings and survivor status on failure.
`host-pressure-three-host-failures.json` records closely matching system
I/O pressure counters on `.18` and `.21`, suggesting shared resources,
while `.19` and `.20` were quiet. This is diagnostic evidence, not proof
of the timeout cause or a replacement for a passing three-host
qualification.

R7 three-host completion increment:
`network-capacity-final-three-host-v3.json` passes all 38 native
SQL/search/ORM, minority, retry, each-voter-absent, rejoin, snapshot
publication and full-restart checks with the identified Linux binary
`1299f4531c8e9daa4d60c71a3d513d0aad253e984854dc4012ecca9664f70a3e`. Both
survivors complete 90 operations for each missing voter; first
post-crash writes take 1.35, 1.35 and 2.37 seconds, within the unchanged
five-second goal. Maximum individual operation durations in those cases
are 1.18, 2.06 and 2.09 seconds. Listener readiness is established
before operations, with a separate bounded startup deadline. The earlier
timeout remains a failed latency sample; the successful rerun does not
prove its cause or guarantee progress within five seconds during
arbitrary storage stalls. All three instances use ZFS-backed container
roots. Physical failure-domain independence has not been established.

R6.3 failed growth sample and correction: `capacity-64gib-linux.json`
stops after the last recorded 20 GiB payload checkpoint; all voters
report a fatal durable failure around the first automatic maintenance
cycle. Its generic old shutdown diagnostic does not identify the exact
failing stage. Inspection found the host still passed `image_begin` its
default 60-second copy/hash deadline, despite the new 3,600-second
verification budget. The last resource sample is 986 seconds after
loading started, consistent with the fifteen-minute automatic trigger
plus the old copy limit; this timing is supporting evidence, not a
captured error code. The host now explicitly uses the same bounded
3,600-second copy/hash budget, and shutdown reports the maintenance
error. No receipt/publication/durability rule changes. Seven focused
local copy/host/cancellation tests pass in
`snapshot-copy-budget-local.json`. Large-data requalification remains
necessary. The failed harness cleaned its temporary data; its
report/logs remain. The corrected harness retains failed data
directories and records /proc sampling failures instead of silently
losing its monitoring thread. This is a fix under R6.3, not a new gate.

R7 bounded regression completion increment:
`core-capacity-final-linux-v4.json` passes 163 SQLodin tests in debug,
optimized and individual-commit configurations, 81 upstream tests in
both debug and optimized builds, 150,000 seeded fault steps across
one/three/five nodes, compile-fail/durability contracts, mixed SQL and
independent-process checks, the vector/FTS example, six benchmark smoke
profiles, static linkage and CLI subprocess-error propagation. Its three
earlier setup failures remain.
`storage-faults-capacity-final-linux.json` passes all six exact-WAL
error cases, and `history-capacity-final-linux.json` passes serial
predicate histories with each voter absent and after full restart. These
reports identify the preceding candidate. Compared with their runtime
sources, the copy-budget candidate changes only
`src/durable/snapshot_worker.odin` (explicit copy deadline) and
`service/server.odin` (maintenance shutdown diagnostic).

The correction\'s exact Linux binary is
`3bf2374eb7d4d7833fa6f5df26e7c27f36b856b201783d3b01af5ed494f67d9a`.
`network-copy-budget-three-host.json` passes all 38 checks, with first
post-crash writes at 2.49/1.56/2.36 seconds.
`cli-copy-budget-local-v2.json` passes 28 checks with that correction\'s
local client and server. The preceding local CLI invocation accidentally
selected the old default server; its failure is separately retained.
Both corrected native artifacts pass static linkage inspection. The
corrected Linux debug suite passes 163 tests on tmpfs; it is unit
evidence, not a new disk-durability claim. Optimized/reference checks
use disk-backed temporary storage. The copy-budget capacity rerun
remains open. No unchanged consensus/formal check is presented as a
fresh run against altered source.

R7 build correction: the observed missing-ZIP shell build now accepts a
retained extracted `shell.c` only after checking its pinned SHA-256. Six
local native-builder checks pass, including legitimate extracted source
and a tampered-source negative case
(`native-builder-source-cache-local.json`). No system library fallback
is added.

`all-tests-copy-budget-optimized-linux.json` and
`all-tests-copy-budget-reference-linux.json` each pass all 163 tests
with the corrected source on disk-backed temporary storage. The latter
disables both journal and application group commit. The unchanged pinned
upstream, compiler contracts, simulator, formal sources and
storage-fault code retain their source-bound evidence above. The pending
large-data run, performance disposition and final record/cleanup remain
within R6/R7; no elapsed-duration requirement is added.

R6.3 maintenance correction (25 September): the copy-budget-only growth
run sealed its first large image but stopped with `Compaction_Failed`.
Retained private generation files show the next copy rolled back at its
separate 300-second default. `compaction-budget-failure-files.json`
preserves the filesystem evidence;
`capacity-64gib-copy-budget-linux.json` preserves the failed campaign.
All private maintenance copy/hash/verification paths now share the
existing finite 3,600-second capacity policy, including generation
construction, backup, restore and migration. SQL deadlines, quorum
failover and the 60-second recovery target are unchanged. This
correction changes nine runtime files relative to the original full
regression, bound by
`build/release-candidate/manifest-maintenance-budget.json`. Its Linux
binary is
`9f2d2fae81e239b8ac13d77f319dd7925fe849aeab0f60df29e55d993aa73510`.

`maintenance-budget-local.json` passes twelve affected
maintenance/cancellation tests;
`all-tests-maintenance-budget-linux.json` passes all 163 debug tests on
disk-backed temporary storage. Local and Linux native linkage checks
pass. A deliberate interruption fixture validates the capacity
harness\'s explicit retained-directory resume: the linked continuation
verifies existing rows, grows 16 to 32 MiB, snapshots and restarts
successfully. The large continuation preserves its prior report hashes
and does not represent a fresh run. Its first all-voter startup missed
60 seconds; that failed sample remains. A bounded singleton diagnostic
opened in 27 seconds, including 26 seconds of integrity checking, and
the next three-voter continuation opened in 31.97 seconds. This does not
erase the earlier miss or qualify final large-data recovery. The 64 GiB
continuation and final recovery remain in progress.

`cli-maintenance-budget-local.json` passes all 28 public CLI checks
using the current candidate as both client and server.
`source-manifest-maintenance-budget.json` binds its 127 runtime source
files and native/Python artifact hashes in the retained qualification
directory. `bundle-maintenance-budget.json` identifies the
self-contained Linux candidate archive and bundled licenses. It remains
explicitly a candidate, not a production approval; no release or package
has been published.

`all-tests-maintenance-budget-optimized-linux.json` passes all 163
optimized tests on disk-backed Linux temporary storage with the current
runtime sources. The individual-commit configuration remains in
progress. The capacity continuation has reached 24 GiB of payload; final
generation publication/restart is not yet qualified. Original
throughput/latency targets and their measured misses are consolidated in
`specs/service-batching.typ`\; no acceptance threshold is changed.

R6.3/R7 retained contention sample: the maintenance-budget continuation
stopped after its saved 25 GiB checkpoint with an unresolved write after
bounded retries. All three processes were still alive before harness
cleanup and had no new fatal maintenance diagnostic. Peak voter RSS was
34--35 MiB. The reference suite run simultaneously with 32 test threads
passed 146/163; seventeen failures originated at snapshot
setup/certification waits. `maintenance-reference-contention-linux.json`
records over 60 percent recent I/O pressure. This is evidence of
contention, not proof of the full timeout cause. Both reports and
retained capacity data remain. The unchanged reference suite is
rerunning separately before any large-data restart.

R3.4/R6.3 correction: live generation catch-up previously applied up to
32 SQL transactions on the service owner per poll. Small journal records
in this capacity profile each expand 16 MiB, so this work-count bound
could monopolize the owner across a substantial disk replay. Catch-up
now yields after one application transaction, retaining the journal
chunk bound and every durability/publication check. This does not
preempt a single SQLite call or guarantee kernel I/O latency. The
strengthened local regression verifies the per-turn replay bound and
preserves 140 tail writes, future accepted votes, promises, IDs and
restart state. `generation-replay-turn-local-v2.json` records the final
focused local pass.

`all-tests-maintenance-budget-reference-linux-v2.json` passes all 163
unchanged individual-commit tests with 32 threads once the capacity
workload has stopped (17.9 seconds). Its earlier concurrent run passed
146/163 in 226.7 seconds. No test watchdog, thread count or production
target was relaxed for this rerun. The separate replay-turn correction
still requires its own affected checks.

Replay-turn candidate binding: `source-manifest-replay-turn.json`
identifies Linux
`010338a4e2a8a8f9e4761d15b3d40b637a57b7a45f9d45ae7f73e3cbee5a1478` and
local
`f6351acbaeaf24f9e538e0cd2ed821f4f9361652a317224f3a59b068bb179e4d`. It
changes only `src/durable/generation_delta.odin` relative to the
maintenance-budget runtime. `all-tests-replay-turn-linux.json` passes
all 163 debug tests on disk-backed storage. The focused Linux replay
regression also passes, and both artifacts pass static linkage checks.
`generation-replay-turn-regression-binding.json` records the passing
local regression and the expected failure when the old 32-transaction
loop is restored in a temporary copy. It is a scheduling regression, not
a capacity latency pass. Optimized/reference, three-host and capacity
checks remain underway.

`network-replay-turn-three-host.json` passes all 38 native mTLS
SQL/search/ORM, minority/retry, each-voter-absent, rejoin, generation
publication and full-restart checks on `.19/.20/.21`. First post-crash
writes take 2.37/1.24/2.48 seconds, within the unchanged five-second
goal. `cli-replay-turn-local.json` passes all 28 checks using the new
local candidate as both client and server. The new capacity continuation
is sequenced after successful optimized/reference reports so these
regressions do not compete with large-data I/O. Prior failed samples
remain.

`all-tests-replay-turn-optimized-linux.json` and
`all-tests-replay-turn-reference-linux.json` each pass all 163 tests on
disk-backed Linux storage with the replay-turn correction. The latter
disables both journal and application group commit. The final test
source has only a style-required line wrap relative to the executed
test; exact earlier text and whitespace equivalence are retained in
`generation-replay-turn-style-binding.json`. Runtime sources remain
unchanged. The retained 64 GiB continuation started only after both
reports passed.

The first replay-turn continuation reopened all three retained voters in
137.09 seconds, missing the original 60-second startup target. Recorded
integrity phases were 133.8--135.2 seconds; journal/application recovery
took under half a second per voter. It then failed before resumed growth
while executing unqualified `SELECT count(*) FROM capacity`. All
processes were alive before cleanup, with no new fatal diagnostic.
`capacity-64gib-replay-turn-linux.json` preserves this sample; it
neither validates nor disproves the later generation replay correction.

The capacity verifier now counts all rows through disjoint 16,384-ID
primary-key ranges, checking minimum/maximum IDs and the exact total on
every voter, followed by the same deterministic payload samples. This
preserves complete key coverage and the 64 GiB target while using
bounded indexed queries rather than a single large-table scan. SQLite\'s
optimized count scans B-tree pages within one VM opcode; VM callback
counts alone do not bound its disk work. The original verifier is
retained as `check_capacity_resume_v6.py`. No SQL guarantee, runtime
budget, recovery threshold or failed sample is changed by this harness
correction.

R6.2 explicit user disposition (25 September): the user approved “Allow
release after correctness qualification, with performance shortfalls
disclosed” in response to the question naming 3,000 mixed/s, 1,000 pure
writes/s, read/write p99 20/50 ms and 25 percent of matched SQLite
throughput. These original numbers remain unchanged as future
improvement goals and are not blockers for the first
correctness-qualified release. The mixed-profile 900 successful writes/s
component remains part of the original mixed-throughput improvement
goal. No measured result is relabelled a performance pass. R6.2 closes
calibration and target disposition on that explicit authorization.
Capacity/resource/recovery evidence and final candidate qualification
remain R6.3/R7; no unmeasured correctness or durability property is
waived.

R6.3/R7.2 explicit scope correction (25 September): the user directed
that large capacity campaigns must not be release requirements and
requested mathematics/proofs and targeted tests instead. This replaces
the original R6.3 sentence requiring a 10 GiB dataset and growth toward
100 GiB, and the R7.2 larger-capacity campaign. The 64 GiB continuation
was stopped with SIGINT at the last saved 32 GiB checkpoint;
`capacity-64gib-replay-turn-linux-v2.json` records `KeyboardInterrupt()`
and retains its data. All three processes were alive before controlled
cleanup; sampled peak RSS was 45,416,448 / 46,706,688 / 47,063,040
bytes. This is interrupted evidence, not completed capacity, snapshot or
recovery qualification. Prior 114/137-second large-store startup
measurements remain disclosed against the original 60-second goal. No
100--200 GiB capacity claim or elapsed soak gate is required for this
release. The current candidate\'s 64 MiB fixture completed snapshot
publication, full restart in 1.32 seconds and exact key-count
verification on every voter. The earlier 10 GiB report remains
explicitly tied to its earlier candidate. Final targeted checks and the
release decision remain R7, with no added gate.

R6.3/R7 final closure (25 September): the current candidate passes the
64 MiB on-disk snapshot/restart fixture (1.32 seconds), 43
generation/retirement/backup/restore crash boundaries, three live
generation cycles with writes, protected-predecessor retirement,
offline-voter snapshot catch-up and acknowledged-data preservation after
full restart. All 38 checks across \.19/.20/.21 pass, including first
writes after each crash at 2.37/1.24/2.48 seconds. RSS remains below the
512 MiB short-query goal in the retained resource and current candidate
observations; the 8 GiB history admission/retirement contract is
exercised by its targeted quota, fault and lifecycle regressions.
Large-capacity timing misses remain disclosed and are not evidence of a
60-second recovery guarantee for arbitrary database sizes.

Current Linux debug, optimized and individual-commit configurations each
pass 163 tests; local CLI passes 28 checks. Current-source crash
evidence matches every hashed source. The complete earlier core run
supplies unchanged upstream checks (81 per configuration), 150,000
seeded fault steps, compile/style checks and embedded/search examples.
Its ten changed runtime files are covered by the current tests,
maintenance regressions and 43 crash checks; evidence reuse is explicit
in release-decision.json. The unchanged Python wheel passes its 30
isolated tests; static native linkage passes on both platforms. Formal
binding verifies 59 source-identical model cases including negative
controls, and 48 discharged induction obligations. This is a
compositional argument with tested implementation boundaries, not a
proof of the compiler, OS or physical storage.

The initial final-crash invocation could not find Odin on PATH; its
report is retained. The corrected invocation uses the installed
toolchain and passes all 43 checks. The interrupted capacity report and
all earlier failed samples remain available. No runtime source changed
during final qualification. All seven gates close once under the
explicit release scope; optional optimization, dynamic enrollment,
rolling upgrades, large-capacity guarantees and book work are not
additional gates.
