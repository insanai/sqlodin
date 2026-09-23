# Linux benchmark

## Current campaign: native network service on .18

Use **`insan@10.175.52.18` for all new benchmark runs**. The three-instance
qualification hosts `.19`, `.20` and `.21` are reserved for functional/endurance
checks. Existing reports from earlier hosts remain historical evidence.

The current disk-backed comparison uses the native SQLodin mTLS service and the
existing mixed order-processing workload. The reference harness files already on
`.18` match `vendor/zaxonlite/` exactly. SQLodin, rqlite and Zaxonlite run the SQL
workload; cowsql uses only its stock demo's supported PUT/GET interface.

```sh
ssh insan@10.175.52.18
cd ~/projects/sqlodin
python3 tools/compare_native_workloads.py --operations 400 --warmup 100 \
  --concurrency 4 --repeats 3 --output benchmarks/results/linux18-native-next.json
```

Each product has three separate processes, persistent data directories, warmup,
retry-inclusive latency and correctness checks after voter loss and cluster restart.
The JSON records per-repetition throughput, latency, database-process CPU/RSS,
allocated disk, binary hashes and dependency versions. Cowsql's SQLite image is
memory-resident with disk-persisted Raft state; the book states that distinction.
This is not an interactive ORM benchmark or an offered-load capacity test.

Current results: `results/linux18-native-comparison-complete.json`. The earlier failed
`linux18-native-comparison.json` records a sequential helper that stopped on an
ambiguous setup response; the final adapter uses the reference retry-capable client
and idempotent keys. Its fully verified mixed samples are reused with provenance
and matching binary/workload/adapter checks. The later third mixed-workload attempt for Zaxonlite failed during setup; two
stopped replicas also failed read-only SQLite integrity checks. That failed sample
is retained in `linux18-native-failures.json` and the completed campaign report,
not replaced with a retry. Chart labels show the successful sample counts.
Repetitions are never invented or relabelled as fresh measurements.

Render the JSON-backed figures with `tools/plot_native_benchmarks.py`, then build
the book with `tools/build_docs.py book`. The following sections describe older
embedded measurements and retain their original boundaries.

After a run completes and its voters stop, run the read-only storage inspector on
`.18`, fetch the report, and render locally:

```sh
ssh insan@10.175.52.18 'cd ~/projects/sqlodin && python3 tools/inspect_native_benchmark.py benchmarks/results/linux18-native-next.json'
rsync -az insan@10.175.52.18:~/projects/sqlodin/benchmarks/results/linux18-native-next.json benchmarks/results/
python3 tools/plot_native_benchmarks.py benchmarks/results/linux18-native-next.json
python3 tools/build_docs.py book
```

The plotter requires matplotlib; its default output is `docs/book/plots/`.
Update the book chapter's JSON path when adopting a new run. Never overwrite a
failed report with a successful rerun, or merge results from different hosts.

## Historical embedded benchmark

The book imports [`results/linux-latest.json`](results/linux-latest.json) directly.
The [Linux verification log](results/linux-verification.log) records the prerequisite checks. This is a **single-thread, in-process**
replication and SQLite application benchmark, not a durable network database benchmark.
The `sqlite` mode measures SQLodin's local application engine (including its applied watermark),
not a bare `sqlite3_step` loop. The multi and single modes apply to all three replicas.

## Reproduce

```sh
# Run from a checkout on Linux with Odin, Python 3, a C compiler, ar, git and taskset.
git submodule update --init --recursive
python3 tools/build_native.py
make check
python3 tools/benchmark.py --cpu 2 --samples 7 --iterations 24000 --warmup 2400 \
  --output benchmarks/results/linux-latest.json
# From the repository root, including the JSON in Typst's allowed root:
typst compile --root . docs/book.typ docs/build/sqlodin-book.pdf
```

The native builder downloads official pinned amalgamations and verifies every compiled C source
and header against SHA-256. To reuse a cache, supply `--sqlite-source DIR --vec-source DIR`.
It builds under `build/native`, without system installation or modification of other repositories.
The committed macOS archive is not linked on Linux.

The recorded remote run is under `/home/insan/projects/sqlodin` on `agy01` (`10.175.52.19`).
Binaries, verification logs and build metadata remain in its `build` directory. The JSON retains
source and binary hashes, the Paxos pin, compiler versions/flags, hardware, affinity, cgroup limits,
load, raw per-process samples and summaries. The base revision identifies the original checkout;
**the source manifest identifies the uncommitted source snapshot actually measured**.

## Method

- Three builds: `reference` uses the former SQL-string cache lookup and a 256-packet initial queue;
  `shape_cache` uses direct DML metadata lookup with the same queue;
  `optimized` also starts the growing FIFO at 32 packets.
- Seven repetitions of every build, mode, batch size (1 or 12) and text payload size (0 or 256 bytes).
  All 36 cases are shuffled within each round using the recorded seed. No samples are discarded.
- Each case runs in a fresh process pinned to the same logical CPU. The machine is not reserved:
  affinity reduces migration, but does not remove SMT sibling contention or other tenants.
- Warmup is excluded from throughput and latency. Measured writes use unique keys, an integer
  value and optional fixed text. The dataset grows through warmup and measurement; no deletion
  or compaction is timed. Prepared statements, mutations, all packets and every replica's SQL
  application are exercised.
- Multi-master cycles proposers 1, 2, 3. Batch 12 has four proposals per master in flight before
  message delivery; single-leader submits directly to the active leader. This measures pipelining
  in one event loop, not three CPUs executing simultaneously. Balanced admission avoids idle-owner
  holes; skewed traffic and failures are covered by correctness tests, not these timing cases.
- A batch completes after all replicas apply. Latency is batch completion latency, **not latency
  divided by batch size**. The direct SQLite baseline uses a single transaction per batch;
  replicated modes use each contiguous committed effect batch, so their transaction counts may differ.
- Every replica's final row count, all keys/integer values/text payloads and applied watermark are
  checked after timing. Any failed proposal/application/verification aborts the suite.
- The JSON reports each sample and median/min/max/MAD across repetitions. Latency percentiles use
  nearest rank within a sample; summaries are medians of sample percentiles, not pooled percentiles.
- `wait4` reports each child's CPU and peak RSS independently. These process-wide measurements
  include startup, warmup, verification and cleanup. CPU percent is relative to **one core**, not
  all 16 logical CPUs. Throughput's timing interval is narrower; do not divide these CPU seconds
  by just the measured operations and call it steady-state CPU cost.

No sockets, encoding, consensus journal, disk SQLite, fsync, client forwarding or WAN delay are
included. There is no multi-core scalability or representative vector/FTS search benchmark here.
The legacy `make bench` one-row search fixture remains a smoke example only.

## Interpreting the comparison

The matched comparison tests the cost of rotating ownership versus one leader in the same library
and host. A local multi-master throughput advantage is not guaranteed: both modes execute SQL on
all replicas, and rotating ownership introduces gap handling and additional protocol work.

The historical report has no durable cross-product measurements. It cannot be ranked against
network servers with persistent logs. The separate durable comparison below records the current
supported workloads and explicitly different interfaces and read guarantees.

## Durable workloads and official product releases

The durable comparison is a separate report: `results/linux-realworld.json`. Its prerequisite
crash report is `results/linux-durability.json`, with full checks in
`results/linux-durable-verification.log`. The memory report above remains historical; its
measurements cannot be relabeled as durable database throughput.

On the authorized Debian 13 x86_64 Linux host:

```sh
python3 tools/build_native.py
python3 tools/setup_comparison.py
python3 tools/fetch_zaxon_release.py
python3 tools/check.py
python3 tools/check_durability.py --output benchmarks/results/linux-durability.json
python3 tools/compare_realworld.py --operations 1200 --warmup 240 --repeats 3 \
  --output benchmarks/results/linux-realworld.json
python3 tools/inspect_benchmark_storage.py benchmarks/results/linux-realworld.json
```

Zaxonlite uses the official `insanai/zaxonlite` v0.7.0 Linux x86_64 musl executable. Its archive
SHA-256 is pinned and checked against the release's `SHA256SUMS`; the executable hash and release
URL travel with the report. rqlite uses its pinned v10.2.7 release. cowsql v1.15.9, C-raft v0.22.1 and the unmodified
go-cowsql v1.22.0 stock demo are built locally against extracted user-local dependencies. No system
packages or database implementations are patched for the benchmark.

The order-processing workload comes from Zaxonlite's benchmark: 1,000 customers, 500 products,
roughly 30% inserts and 70% inventory/history/dashboard reads, with indexes, JSON metadata and a
trigger updating inventory, order lines and the financial ledger. Final order counts, unique
operation IDs, units, revenue and nonnegative stock are verified. Zaxonlite and rqlite run three
network voters with four clients and linearizable reads, including follower failure, leader failure
and whole-cluster restart phases. Their per-phase data remain in JSON.

SQLodin runs three **file-backed** durable hosts in one process, with copied in-process packets and
one sequential client rotating admission across masters. It uses local snapshot reads and verifies
all copies before and after reopen. It is an embedded-host measurement, not a network-server
substitute. Separate durability tests exercise concurrent admission, missing-owner recovery,
long-history catch-up and SIGKILL at acknowledgement.

The common sequential workload writes one row with a 256-byte payload per operation. Zaxonlite
and rqlite use SQL; the stock cowsql demo supports PUT/GET only. cowsql's SQLite materialization is
in memory, backed by persistent Raft logs/snapshots: it is not an in-memory-only durability setting
and is not an on-disk SQLite comparison. Its three persisted voter assignments are checked before
timing. A separate optional restart check attempts to recheck payloads after killing/restarting
the full cluster through each demo endpoint; any failure is reported as `restart_verified=false`
with diagnostic logs, not treated as successful recovery. These endpoints can route requests; this is not direct inspection of every replica image.

Warmup and verification are excluded from throughput. Three fresh-directory repetitions use the
same seeds; product order is shuffled within each repetition. Latency percentiles are per operation.
CPU counters and aggregate RSS are sampled every 10 ms for database child processes across the
whole lifecycle (including setup/recovery). The embedded SQLodin process also includes its driver.
These sampled resource numbers are approximate, have different lifecycle work totals, and must not
be divided by just timed operations to infer steady-state CPU cost. File logical/allocated sizes
are captured after shutdown. Run directories are retained on Linux; generated private TLS keys are
not copied into book data. No claim of globally optimal CPU/memory use or cross-product superiority
follows from these differing execution and read-consistency boundaries.


The published comparison replaces the earlier dqlite demo with cowsql at the user's request.
SQLodin, Zaxonlite and rqlite samples were retained from the completed run; cowsql was measured
later with the same operation counts and host. `reused_sql_run` records the original timestamps,
source and binary hashes. `--reuse-sql-results PATH` verifies a complete matching SQL workload,
unchanged measured sources and binaries before measuring only cowsql. Fresh runs omit that option
and shuffle all four systems across repetitions. Earlier diagnostics remain on the Linux host;
no dqlite measurements appear in the published comparison tables.

Later implementations keep that published report unchanged. Fresh runs default to
`linux-realworld-current.json`, require a current matching `linux-candidate-v3-durability.json`,
and refuse to overwrite an existing comparison report. Use `REALWORLD_REPORT=path.json` with
`make bench-durable-linux` for another run. `make check-durability DURABILITY_REPORT=new-report.json` writes fresh crash evidence
without overwriting an existing report. The original five-case format-1 report remains historical. The separate
`linux-production-p1-mixed-smoke.json` checks the existing order/ledger/stock workload after the
SQL policy changes; its 60 operations are correctness evidence, not a capacity measurement.

## Durable storage cost attribution

`results/linux-durability-cost.json` is a separate instrumented diagnostic, loaded by the book and
production SOD. It compares the pinned SQLite build at one and 32 rows per FULL transaction with
one-voter and three-voter SQLodin. Three-voter execution is serial in one process. The 32-row case
changes transaction granularity; it is not independent-client group commit or a product ranking.

```sh
# Linux, after building the pinned native dependencies:
python3 tools/check_durability.py --output new-crash.json
python3 tools/profile_durability_cost.py --durability-report new-crash.json
# Add independent request batches, writing a new named report:
python3 tools/profile_durability_cost.py --transaction-batches \
  --durability-report new-crash.json --output results-new.json
```

The driver builds `bench/durability_cost/main.odin` and its C syscall interposer. The interposer
forwards every fsync, fdatasync and pwrite call unchanged. Three shuffled repetitions each measure
480 rows after 96 warmup rows; setup, verification and shutdown are excluded from timed counters.
All rows and payloads must verify. File-write byte counts are not physical device traffic or ZFS
allocation, and single-threaded instrumentation is not suitable for concurrent production profiling.
Source and binary hashes identify the measured snapshot. Mixed-SQL target calibration remains planned.

The profiler now defaults to a timestamped report and refuses to overwrite existing evidence.
`results/linux-production-p1-batches.json` measures the initial format-2 implementation. Its extra
four modes compare one and three voters with proposal batches of one and sixteen. Every row is
still a separate retry-safe transaction with a distinct session and a 256-byte bound value; SQL
application commits remain per request. All three hosts execute serially on the same Linux machine.
Reusable batch storage is allocated before warmup and timing. These cases diagnose the effect of
proposal batching; they are not mixed-workload, network-service, resource-soak or production targets.
Do not attribute differences from historical samples solely to batching: outcomes, payload format
and shared-host conditions also changed. Compare batch sizes within the same new run.


## Format-3 candidate and separate voter processes

`results/linux-candidate-v3-cost.json` records 24 disk-cost samples for application groups,
packed journals and no-op prefix folding. The book reads it directly. That snapshot
required eighteen passing crash cases on an identified persistent filesystem. One-voter batches
share a FULL application commit; three-voter consensus transitions still commit individually.
These remain serial-replica diagnostic samples, not production service throughput.

The separate process controller uses one Linux host, **three OS processes and three data
directories** under project `build/`. It rejects tmpfs/ramfs for disk runs and records the
filesystem. Its default reads use fresh ordered barriers; `--read-mode local` is explicitly a
weaker consistency mode. Neither pipe transport nor these closed-loop waves are a network server.

```sh
python3 tools/check_process_cluster.py --operations 2400 \
  --work-dir build/process-new-run --output results-new-process.json
```

Transfers update balances and exercise foreign keys, an index and a two-entry audit trigger.
The controller verifies exact IDs, amounts, endpoints, payloads, audit pairs, balances and durable
retry outcomes. Its fault phases include uncertain retries after whole-cluster SIGKILL, minority
isolation, writes with one voter stopped, fenced reads on a stale restarted voter and final recovery.
Read and write latency, timed voter CPU and Linux per-voter peak RSS are recorded separately.
Warmup consists of schema and initial accounts; these small datasets do not calibrate 10 GiB targets.

The first 2,400-operation attempt reached verification but its correlated audit query exhausted
SQLodin's local read-work budget (`Query_Limit`). The preserved database reopened successfully;
the verifier now checks audit groups and exact transfer batches within the unchanged read limits.
The failed attempt is retained as a failure, not counted as a successful benchmark.
The earlier `linux-policy3-process.json` used Linux `/tmp` on tmpfs and is explicitly annotated as
process-crash evidence only. It must not be cited as disk performance.


## Incoming-transition journal groups

The current host uses `step_batch` to group up to sixteen received Paxos transitions behind a
FULL journal commit. Its owned pending effects and durable-frontier checks are reviewed in
[`docs/journal-group-commit.md`](../docs/journal-group-commit.md). The complete pinned upstream
library is unchanged. The reference path remains available:

```sh
python3 tools/check_durability.py --output new-group-crash.json
python3 tools/check_process_cluster.py --operations 2400 --output new-group-process.json
python3 tools/check_process_cluster.py --individual-journal --operations 2400 \
  --output new-reference-process.json
python3 tools/profile_durability_cost.py --transaction-batches \
  --durability-report new-group-crash.json --output new-group-cost.json
```

The profiler now requires 22 passing crash cases for the exact runtime source and journal-group
configuration. It still executes replicas serially and forwards every FULL sync unchanged.
Incoming packets are buffered by destination in reusable sixteen-packet buffers before delivery;
this scheduling also applies to the reference build, which commits each packet individually.
Proposal batch size, application grouping and journal grouping are separate contracts. The JSON
records the journal-group configuration; never infer it from a historical source filename.

The first grouped process run, `linux-journal-group-process.json`, passed all nine checks and
measured 57.39 mixed operations/s. It is a single-run observation. The larger preceding run,
`linux-candidate-v3-process-10000.json`, passed 10,000 operations and final recovery, but predates
journal grouping. Neither is a 24-hour or seven-day soak.


For the matched process experiment, first obtain current 22-case crash reports for both modes,
then run the paired driver. It builds each binary once, verifies unchanged sources, shuffles
mode order and uses the same seed within each pair. Every sample must pass all nine workload/fault
checks. It refuses to overwrite prior evidence and leaves incomplete reports marked incomplete.

```sh
python3 tools/check_durability.py --individual-journal --output new-reference-crash.json
python3 tools/compare_process_journal.py --group-durability new-group-crash.json \
  --reference-durability new-reference-crash.json --output new-matched-process.json
```

The timed reads check one hot account balance. Each transfer uses a distinct session. Long-lived
client sequence reuse, range-heavy queries, offered-load saturation and large datasets remain
separate P0 calibration cases. CPU excludes the controller while end-to-end latency includes it;
resource counters and their time boundaries are described in the book.


The recorded paired result is `results/linux-journal-matched-process.json`: six completed samples,
three per mode, with all checks passing. `results/linux-journal-final-cost.json` contains the
24-sample serial cost diagnostic. Both are imported by the current book. Their exact source hashes
match the implemented journal-group snapshot; older candidate reports remain unchanged.

## Eight-hour, three-instance campaign

`results/linux-three-host-20260922T165016Z/` contains the completed remote smoke and
pilot plus fetched snapshots of the running eight-hour SSH campaign. It uses one
durable voter per LXC instance on `.19`, `.20` and `.21`, twelve long-lived transfer
sessions, periodic exact checks, bounded resource monitoring and scheduled process
crashes. The source and binary are frozen for the run. See
[`docs/cluster-qualification.md`](../docs/cluster-qualification.md) for duration,
limits, transport and physical-failure-domain caveats, and the collection command.
Never import a running or failed `soak.json` as a successful benchmark. Completion
requires `complete: true`, `status: passed` and matching final offline audits.

The separate `local-mtls-final.json` and campaign `linux-mtls.json` reports cover
the native TLS primitive only. They do not qualify a SQL network service. The
earlier `local-mtls-first.json` has an explicit qualification correction and must
not be counted as a passing test report.
