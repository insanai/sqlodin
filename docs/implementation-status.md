# Production SOD implementation status

Vikrant Rathore, with assistance from Ronak Rathore. Updated 2026-09-23.

**Implementation is in progress. SQLodin is not production-ready.** The committed [SOD 0004](sod/records/0004-production-sql-and-durable-throughput.typ) is an
engineering plan with release gates, not a claim that those gates have passed.

| Phase | Implemented now | Still required to close the phase |
| --- | --- | --- |
| P0 | Durable Linux cost attribution; mixed-SQL controller with three independent voter processes and fenced reads | Matched SQLite/comparator runs, calibrated latency/resource budgets, independent-machine qualification |
| P1 | Bounded SQL requests, durable outcomes/fences/retries, audited expression rejections, parser/value limits, local engine-build fingerprint, rollback isolation | Full SQL/schema/ordering contract, distributed compatibility negotiation, deterministic write execution quotas, session retirement, broader admission validation and compatibility migration |
| P2 | Upstream proposal batches, bounded journal groups for incoming transitions, application groups up to 16, no-op prefix folding, separate-process replica I/O | Bounded asynchronous persistence, coalescing/fairness and broader crash/refinement qualification |
| P3 | Lossless zero-run packed journals; eight-entry structured-DML statement cache | Compact in-memory/transport payloads, safe migration, journal statement reuse, allocation/copy counters and measured amplification improvements |
| P4 | Native Odin mTLS listener, authenticated fixed peer/client roles, versioned bounded typed results, CLI service/request commands, fresh ordered barriers, uv-managed Python API and durable retry identities | Enrollment, dynamic membership, full network history checking, certificate lifecycle, peer admission reservation and broader overload qualification |
| P5 | Checked complete-history recovery and catch-up | Certified snapshots, trimming, fenced replacement/restore, bounded recovery and storage |
| P6 | Unit, upstream, simulated-fault and Linux process-crash checks | Executable formal models, storage-fault campaign, network histories, 24-hour qualification and seven-day candidate soak |

## SQLodin qualification goals

The endurance and separate-machine requirements are SQLodin-specific release goals
adopted in SOD 0004, not a universal threshold for every database. An unrun gate
is missing qualification evidence; it is not by itself a demonstrated defect.
Assess implemented guarantees and known limitations separately from pending tests.

## Request and outcome contract

`mutation_make_transaction` submits an entire transaction body. The host owns BEGIN/COMMIT.
The initial bound is 4,096 SQL bytes, eight statements, sixteen typed parameters and 256 bytes per
text parameter. Each statement binds the prefix of the same parameter tuple (`?1` through `?16`).
This is a deliberately smaller initial limit than the SOD's provisional service budgets. SELECT
rows within the body are consumed. The separate `engine_query` and network `query` APIs return bounded typed results.

Every session uses a nonzero 128-bit identifier and one outstanding request. Sequence numbers
start at one. The client must retain its session, sequence and exact request content across an
uncertain result. Retry through any voter with that same identity. The canonical SHA-256 content
digest includes SQL and typed parameter values, excluding the receiving voter and unused tails.

- Same sequence and same content: return the original outcome without executing SQL again.
- Same sequence with different content: `Identity_Conflict`.
- Lower sequence: `Expired`; never execute it again.
- Sequence gap: durably consume that sequence as `Sequence_Gap`. Missing lower requests then
  expire; the rejected identity cannot later become a successful execution.
- Advancing the sequence evicts the previous result but retains the durable high-water mark.
- At most 65,536 sessions are admitted. Session fences are not evicted; there is no retirement
  protocol yet. A permanently full session table returns `Session_Limit` for new sessions.

`durable.outcome(host, slot, expected)` reports completed SQL rejection as well as success.
`durable.acknowledged` is true only for `Applied`. Both require the expected value to be chosen
and locally applied. A displaced proposal or timeout has an unknown outcome; it is not permission
to invent a new request identity. Legacy structured mutations and `Raw_SQL` have no retry identity.

Success, expected constraints, policy rejection, audited expression errors and prepare-time syntax/schema errors
are persisted atomically with the session record and application watermark. A rejected request
has no SQL changes. Application groups preserve individual request boundaries as described below. I/O, disk-full, OOM, corruption and unknown errors
still stop the host; they must not become successful or durable SQL-level rejections.
Audited expression diagnostics cover integer overflow, invalid JSON/path/object inputs, LIKE/ESCAPE
errors and trigger-depth limits. Datatype and fixed-length failures also reject the request. Unknown
execution errors still stop the host; adding an error to the classification requires a source audit.

The function allowlist is enforced both by SQLite's authorizer and by connection-level callbacks,
because the authorizer misses some default expressions. Maximum signed rowid writes are rejected
to prevent SQLite's random-rowid fallback. Temporary state, configuration PRAGMAs (except read-only data_version), virtual-table
creation other than built-in FTS5, recursive CTEs, direct `sqlite_sequence` writes and protected metadata access are denied
on the durable replicated path. The legacy
volatile engine has a different policy and remains a test/example interface.

Local snapshots use a separate read-only connection. Reads accept one statement, at most 4 KiB SQL,
65,536 result rows and approximately one million SQLite VM instructions, including preparation.
Value/row length is limited to 1 MiB; parser, trigger and parameter limits are versioned. The progress
budget applies only to reads, never to deciding a replicated write outcome. Partial reads return
`Query_Limit`; the writer remains usable. These are not aggregate RSS or deterministic write quotas.

`durable.begin_read` proposes a fresh no-op marker using a durably reserved ID after read invocation.
`poll_read` waits for that exact marker and the applied prefix, then opens a SQLite snapshot.
A host has one active ticket; completion, displacement, cancellation or restart retires it. Copying
an old ticket cannot reuse a fence. `Displaced` requires a new barrier. Continued message delivery
and ticks are required. The reference barrier API counts rows. The native service consumes its fresh barrier and
executes `engine_query` in the same serialized turn, returning owned typed values and names.
Value results have stricter limits of 4096 rows and a 256 KiB internal budget; an error returns
no partial result. `engine_read_snapshot` and `engine_query` alone remain local reads.
See [the native service contract](network-service.md). All host access remains serialized.

These controls do **not** establish arbitrary SQL determinism. Identical schemas, engine builds,
collations and deterministic ordering remain requirements. Privileged direct schema/function
changes can bypass the contract and are unsupported. Broader FTS commands, broad SQL admission,
resource limits and heterogeneous-engine compatibility need separate qualification.

## Batching and persistence boundary

`durable.propose_batch` validates all inputs before upstream admission. Journal effects commit
before packets are released. Leading no-op decisions record their outcomes/watermark in the same
journal commit, avoiding a separate application sync for those slots.

Up to sixteen contiguous requests may share one FULL application commit. Each runs inside a
savepoint. `SQLITE_DBSTATUS_DEFERRED_FKS` is checked at every request boundary: a later request
cannot rescue a deferred constraint that would have failed the earlier request's independent commit.
Expected rejections roll back to their savepoint and retain an independent durable outcome.
If a classified `ROLLBACK` aborts the entire outer transaction, the complete, unacknowledged group
is replayed through the individual-transaction reference path. Storage/unknown errors halt rather
than trigger semantic replay. SQL functions with external effects are outside the allowed profile.

No acknowledgement or in-memory applied-watermark advance occurs at savepoint release. SQL,
outcomes, fences and the watermark become durable together at the outer FULL commit. Compile
with `-define:SQLODIN_APPLICATION_GROUP_COMMIT=false` to retain the reference path. Recovery still
replays retained unapplied requests individually. `step_batch` now groups up to sixteen received
transitions behind a FULL journal commit using owned pending effects and a checked durable sequence.
The upstream `.Host_Managed` integration mode is used for grouping; compile with
`-define:SQLODIN_JOURNAL_GROUP_COMMIT=false` to retain the `.Enforced` reference. See the
[journal-group review](journal-group-commit.md). Asynchronous persistence and overload/fairness
contracts remain open; this is not a claim that all of P2 is complete.

## Compatibility and evidence

Format 3 / SQL policy 4 preserves every logical mutation field and IEEE bit pattern, including
inactive tails, using bounded lossless zero-run encoding. It reduces journal bytes without changing
upstream equality or the fixed-size in-memory payload. The durable identity also fingerprints the
SQLite source ID and compile options, so a changed engine build cannot silently reopen a voter.
This local check does not negotiate compatibility with remote peers.

This format rejects earlier formats and prototypes. There is no automatic or rolling migration.
Retain the old binary, database and WAL; never relabel identity metadata to force an upgrade.
Snapshot certification, fenced replacement and operational migration remain release gates.

Local lightweight verification includes 85 SQLodin tests, the individual-transaction reference build
and a three-process fault smoke. The additional differential test compares 192 requests through
grouped and individual execution, including exact SQL state, all outcomes, retry fences and restarts. Linux verification additionally runs the pinned 79-test upstream
suite and 150,000 simulated fault steps. The crash suite now has twenty-two scenarios, including
five application-group boundaries and four journal-group promise/vote boundaries. New evidence is recorded under `linux-candidate-v3-*`; consult completed reports
for the exact source snapshot and checks that have actually passed.

The earlier completed Linux campaign used **one machine, three separate processes and directories**.
The controller routes bounded framed-pipe messages concurrently; it is not a production network
service. It checks mixed transfers, indexes, triggers, foreign keys, ordered read barriers, uncertain
and acknowledged retries, minority partitions, process kills and offline-voter catch-up.
Data defaults under project `build/`, and Linux disk runs reject tmpfs/ramfs and record `findmnt`.
The early `linux-policy3-process.json` used `/tmp` on tmpfs: it is explicitly corrected as process-crash
correctness evidence only, with no persistent-disk performance claim.

Historical reports retain their original workloads, source snapshots and boundaries. No existing
cross-product comparison is relabelled as current. Performance targets, exhaustive storage-fault
qualification, independent-machine failure domains and long endurance campaigns remain unverified.


The completed 2,400-operation ZFS process run is
[`linux-candidate-v3-process-2400-v2.json`](../benchmarks/results/linux-candidate-v3-process-2400-v2.json):
1,677 fenced reads, 723 timed writes, nine workload/fault checks and 745 exact verified transfers
including fault phases. Its 42.70 mixed operations/s, 98.26 ms read p99 and 193.46 ms write p99
are controller-inclusive observations, not production target achievement. The initial attempt
stopped at verification on `Query_Limit`; bounded exact-transfer/audit queries fix the verifier
without increasing the runtime work budget. Both attempt logs are retained.

The new [disk-cost report](../benchmarks/results/linux-candidate-v3-cost.json) has 24 samples with
matching runtime hashes and eighteen-case durability prerequisites. Within that run, one-voter
request batching raises the median from 111.16 to 1,165.26 writes/s; three serial voters rise from
24.96 to 30.19 writes/s. That snapshot predates the incoming-transition journal groups.
The book imports both new reports directly. Earlier comparison data remain historical.


The larger pre-journal-group run, `linux-candidate-v3-process-10000.json`, passed 10,000 mixed
operations plus all nine fault checks, with 3,071 transfers verified after final restart. It ran
for 242.31 timed seconds at 41.27 mixed operations/s; this is a short sustained check, not a soak.

The first grouped-journal run, `linux-journal-group-process.json`, passed the same 2,400-operation
workload and all nine checks at 57.39 mixed operations/s, with write p99 122.23 ms. Its matching
84-test unit and 22-case crash logs are retained. This single-run observation motivates a repeated
matched reference comparison; it is not a claim that shared-host variation has been eliminated.


The default-enabled journal build has passed the complete Linux verification pipeline:
84 SQLodin and 79 pinned-upstream tests in both profiles, the individual-journal/application
reference configuration, 22 disk crash scenarios, 150,000 simulated fault steps, mixed SQL,
the three-process campaign and build/CLI smoke checks. The subsequently added capacity-boundary
regression brings the suite to 85 and has also passed on Linux disk storage; that result is recorded
separately in `linux-journal-capacity-unit.log`.

`linux-journal-final-cost.json` contains 24 completed samples with exact matching runtime hashes.
Three serial voters measured 35.30 writes/s at proposal batch one and 250.12 writes/s at batch
sixteen; median syncs/request fell from 5.396 to 0.604. One-voter batch sixteen measured 1,187.26
writes/s. The SQLite FULL 32-row reference measured 5,562.01 rows/s but has a different transaction
contract. These figures do not establish the SOD's mixed-workload production targets.


The completed matched process comparison,
[`linux-journal-matched-process.json`](../benchmarks/results/linux-journal-matched-process.json),
has three shuffled repetitions per mode with identical source, workload seeds, fenced reads and
controller scheduling. Both current journal modes first passed their own 22-case disk crash suite.
All six process samples passed nine workload/fault checks. Median mixed throughput was 39.05 ops/s
for individual journal commits and 51.17 ops/s for grouped commits; median per-run write p99 fell
from 200.77 to 128.59 ms. Timed voter CPU fell from 22.19 to 18.80 seconds, while the median largest
per-voter peak RSS rose from 10.46 to 10.98 MiB. The book loads this JSON directly.

This closes the current one-machine measurement campaign, not SOD 0004 or production qualification.
No multi-machine, large-dataset, 24-hour or seven-day qualification claim is made. The release
blockers in the phase ledger remain open.

## Three-instance endurance campaign stopped

The user subsequently authorized `.19`, `.20` and `.21` for a bounded eight-hour
campaign. All three report LXC virtualization; their physical failure domains are
unverified. The nine-case remote smoke and 125-second, 10,140-operation pilot passed,
including final restart and identical streamed application/session hashes.
The eight-hour workload started at 2026-09-22 17:06:06 UTC and failed at
18:32:01 UTC on a verifier `Query_Limit`, after about 85 minutes. It did not pass.
See [the campaign record](cluster-qualification.md)
for exact scope, resource guards and result locations. No 24-hour or seven-day run
has been started.

Separately, `transport/mtls` supplies an experimental nonblocking Odin/OpenSSL 3
primitive with mutual certificate and exact SAN identity verification. Fifteen
positive/negative integration cases pass locally and on Linux. The initial
negative-test harness accepted SIGPIPE exits; that first report is explicitly
invalidated, and the corrected suite requires normal error exits. The package is
now connected to the native fixed-membership SQL service. Enrollment and dynamic membership
remain open. Local/Linux and three-host network checks cover the initial service;
see the JSON-backed native-service chapter for the current counts.
See [the mTLS implementation boundary](mtls.md). The stopped soak source remains frozen
and does not include or exercise this separate native TLS work.


## Initial Python search and SQLAlchemy (policy 5; superseded below)

Python 0.2.0 now exposes immutable float32 vectors, atomic FTS/content maintenance,
exact vector scans and single-query reciprocal-rank fusion. The optional SQLAlchemy
Core dialect provides explicit AUTOCOMMIT, typed VectorType bindings, declared tables
and bounded atomic executemany. At that baseline ORM transactions and general reflection
were unsupported. Trigger-inclusive change counts are not advertised as matched rows.

SQL policy 5 enables FTS5, defensive shadow-table protection and primary FTS constraint
outcomes. Format remains 3; policy-4 databases and peer fingerprints fail closed.
There is no rolling or automatic migration. Historical policy-4 evidence is retained
with its original scope; it does not qualify the new feature paths. See the Python
client guide and new feature reports for current checks.

## Self-contained dependencies

macOS and Linux now use project-built static SQLite 3.51.3 (FTS5), sqlite-vec 0.1.9
and OpenSSL 3.5.8. The CLI builder checks dynamic linkage and emits a binary/dependency
manifest plus license notices. Embedded imports use only SQLite/vector archives.
The generated executable still uses normal OS runtime libraries. Runtime checks,
three-instance service/search recovery and source/cache rejection evidence are
summarized in [the build guide](building.md). The book loads the corresponding JSON.

The interrupted SSH soak was diagnosed using the exact pinned SQLite build: its
verification join scanned retained ledger history. An explicit ledger ID range now
uses the existing index, reducing the reproduced check from over one million VM
instructions to about 3,000. The old report remains failed; no endurance rerun or
production qualification is inferred from this repair.


## ORM transactions (format 4 / policy 6)

Python 0.3 now defaults SQLAlchemy to optimistic SERIALIZABLE transactions. Private,
rolled-back previews support generated keys, relationships and read-after-flush;
only the guarded Paxos commit publishes writes. Rollback, close, pool reset and nested
savepoints operate on staged work. A persisted database-wide revision detects lost
updates, write skew and changed reads; conflicts require whole-transaction retries.
The revision is encoded and hashed, so unknown commits retain safe identity recovery.
See [the ORM contract](orm-transactions.md). Explicit RETURNING, general reflection
and XA remain unsupported; transaction sizes and global-conflict/replay costs are
explicit. Format-3 stores are incompatible and require a separately validated migration.

The ORM voter-loss regression exposed a service routing defect: phase-one packets
addressed to the local acceptor were dropped. The service now delivers them through
the durable host before routing subsequent packets. This preserves the upstream
Paxos implementation and its persistence boundary.

Current ORM validation: 26 service/ORM checks on macOS, 26 on Linux, and 24 across
the three authorized Linux hosts; 21 search checks on each local/Linux platform;
27 Python unit tests; 94 Odin tests on each platform; 22 Linux process-crash cases.
The final service reports and build manifests share matching binary hashes.
These are bounded correctness checks, not endurance or throughput qualification.
An optional Linux build with application/journal grouping disabled was stopped
after over fifteen minutes of compilation; no reference-configuration pass is claimed.

## Native endurance rerun and benchmark evaluation (23 September)

A fresh eight-hour native mTLS campaign is running on `10.175.52.19`, `.20` and
`.21`. Its workload started at 02:04 UTC on 23 September and is scheduled to end
at 10:04 UTC, followed by restart and offline integrity/hash checks. The 02:54 UTC
snapshot records 104,512 operations and 31,224 verified transfers with status
`running`; this is not an endurance pass. The earlier SSH campaign remains failed.
See [the qualification record](cluster-qualification.md) for the live result path.

The native-service benchmark campaign completed on the designated benchmark host
`10.175.52.18`: 20 successful samples and one retained failed comparison sample.
All successful samples passed storage inspection. SQLodin's median healthy mixed
throughput was 24.13 operations/s and sequential throughput was 8.47 writes/s.
These short measurements do not establish maximum capacity or optimal CPU use.
The book now includes three figures generated from the completed JSON, repetition
counts, failure evidence, resource costs and product persistence differences.
See [benchmark methods and source data](../benchmarks/README.md). All benchmark
processes have stopped; the separate endurance campaign remains running.


## Interactive and scriptable CLI

`sqlodin connect` now provides the native Odin SQL shell with multi-line input,
history/completion, transactions/savepoints, typed output, scripts, catalog and
cluster inspection. `sqlodin local` embeds the pinned SQLite shell with FTS5/vector
support. Elm-style diagnostics include correction hints and terminal-aware ANSI
styling. Durable client state binds pending request identities to the loaded client
certificate; a lost response can be retried through another voter without reapplying
the write. The service status response now exposes configured voters, not a health
or dynamic-membership claim.

The matched optimized local/Linux builds passed 28 CLI checks and 14 native-service
regression checks per platform, plus static database/TLS linkage checks. Linux
validation ran in an isolated workspace on `.18`; the three-host soak was not
upgraded or restarted. See [CLI usage and limits](cli.md) and the
[JSON evidence](../benchmarks/results/cli-validation.json). Remote cluster-wide
backup/restore, bulk dump/import and live membership changes remain unimplemented.
