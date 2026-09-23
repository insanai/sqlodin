#import "theme.typ": callout

#let disk = json("../../benchmarks/results/linux-realworld.json")
#let crash = json("../../benchmarks/results/linux-durability.json")
#assert(disk.complete, message: "Durable benchmark run is incomplete")
#assert(disk.schema_version == 1)
#assert(crash.checks.all(c => c.passed))
#let med(values) = {
  let sorted = values.sorted()
  let n = sorted.len()
  if calc.odd(n) { sorted.at(calc.floor(n / 2)) }
  else { (sorted.at(n / 2 - 1) + sorted.at(n / 2)) / 2 }
}
#let num(value, digits: 1) = str(calc.round(value, digits: digits))
#let samples(system, data: disk.realworld) = data.filter(r => r.system == system)
#let healthy(system) = samples(system).map(r => if system == "sqlodin" { r }
  else { r.phases.find(p => p.name == "healthy") })
#let label(system) = (sqlodin: "SQLodin embedded", zaxonlite: "Zaxonlite", rqlite: "rqlite",
  cowsql: "cowsql demo").at(system)
#let latency(row) = if "all" in row.latency_ms { row.latency_ms.all } else { row.latency_ms }
#let rate-range(rows) = {
  let rates = rows.map(r => r.operations_per_second)
  [#num(calc.min(..rates), digits: 0)-#num(calc.max(..rates), digits: 0)]
}

= Durable Linux Workloads

== Durability Before Performance

This run followed disk-backed Paxos recovery verification. The host persists promises, votes and
decisions before releasing dependent messages, then atomically applies SQLite mutations and their
watermark. All #crash.checks.len() process-crash scenarios passed, including killing all three voters
at acknowledgement and recovering all 80 acknowledged writes. The full regression log accompanies
the JSON. These checks exercise process crashes and injected write failures, not physical power cuts.

Tables in this chapter load `benchmarks/results/linux-realworld.json` directly. The assembled comparison began on
#disk.started_utc.slice(0, 10), on the same Ryzen 7 5800H Linux host as the historical memory study.
Each system uses three voters on this one host. Data directories reside on ZFS. The host was not
reserved exclusively, and no multi-machine or WAN result is implied.

SQLodin uses the checked native SQLite #disk.native_dependencies.sqlite build. Zaxonlite uses
#link("https://github.com/insanai/zaxonlite/releases/tag/v0.7.0")[the official v0.7.0 Linux release]
with `--sync full`, verified against the published archive checksum. rqlite uses v10.2.7; the stock
go-cowsql v1.22.0 demo uses libcowsql v1.15.9 and C-raft v0.22.1. The report records versions, binary/source hashes,
build flags, filesystem metadata and every repetition.

#block[
#set text(size: 8pt)
#table(
  columns: (0.8fr, 1.7fr, 1.5fr),
  table.header([*System*], [*Persistence path*], [*Measured interface*]),
  [SQLodin], [On-disk SQLite application and Paxos journal; WAL FULL.],
    [Embedded host, copied in-process packets, local snapshot reads.],
  [Zaxonlite], [On-disk SQLite WAL NORMAL plus synchronized Paxos log.],
    [mTLS TCP; SQL and linearizable reads.],
  [rqlite], [On-disk SQLite plus persistent Raft log and snapshots.],
    [HTTP; SQL and linearizable reads.],
  [cowsql], [Memory SQLite image backed by disk Raft logs and snapshots.],
    [Stock HTTP PUT/GET demo only.],
)
]

#callout(title: "Interpret each execution boundary", kind: "warning")[
  SQLodin is an embedded-host measurement with one client, not a network server. Its local reads
  have a different consistency contract. cowsql's persisted Raft state is measured using its
  supported demo, without adding an SQL endpoint or changing its VFS. These results do not
  establish an overall product ranking or prove SQLodin is faster as a deployed database service.
]

== Order Processing, Inventory and Ledger

The shared Zaxonlite workload seeds 1,000 customers and 500 products. Approximately 30% of operations
place orders; the other 70% query inventory, customer history and a sales dashboard. Indexes, JSON
metadata, joins and a trigger fan out each order into stock, order-line and financial-ledger changes.
Unique operation IDs and INSERT OR IGNORE make retries idempotent for this workload.

Each repetition excludes #disk.workload.warmup warmup operations and times
#disk.workload.operations operations per phase. There are #disk.workload.repeats fresh-directory
repetitions and shared seeds. The SQL-system samples retain their completed, shuffled run;
cowsql was measured afterward when the comparison set changed. Original timestamps and manifests
are retained under `reused_sql_run`; these are not interleaved four-product repetitions. Rates are medians with sample ranges;
latencies are medians of per-repetition percentiles. No failed operation counts as completed work.

Zaxonlite and rqlite use #disk.workload.network_concurrency concurrent network clients and
linearizable reads. SQLodin uses one client rotating proposals across all three masters and local
snapshot reads after draining its in-process transport. Correct order/line/ledger counts, distinct
requests, units, revenue and nonnegative inventory are verified on all SQL replicas.

#block[
#set text(size: 8pt)
#table(
  columns: (1.25fr, 0.55fr, 0.8fr, 1fr, 0.75fr, 0.75fr),
  table.header([*Healthy workload*], [*Clients*], [*Ops/s*], [*Range/s*], [*p50 ms*], [*p99 ms*]),
  ..("sqlodin", "zaxonlite", "rqlite").map(system => {
    let rows = healthy(system)
    (label(system), if system == "sqlodin" { [1 local] } else { [4 TCP] },
      num(med(rows.map(r => r.operations_per_second)), digits: 0), rate-range(rows),
      num(med(rows.map(r => latency(r).p50)), digits: 2),
      num(med(rows.map(r => latency(r).p99)), digits: 2))
  }).flatten(),
)
]

== Network Failure Phases

The two SQL network servers also execute a full workload phase after killing a follower, then
after killing the leader. Latencies include retries and election delay. The killed replica restarts
with the same identity and data directory; all replicas must converge before continuing. Finally,
all three processes are killed and restarted, then every local copy and integrity report is checked.

#block[
#set text(size: 8pt)
#table(
  columns: (1fr, 1.3fr, 0.8fr, 0.85fr, 0.75fr),
  table.header([*System*], [*Phase*], [*Ops/s*], [*p99 ms*], [*Retries*]),
  ..("zaxonlite", "rqlite").map(system => ("one_follower_crashed", "leader_crashed").map(phase => {
    let rows = samples(system).map(r => r.phases.find(p => p.name == phase))
    (label(system), if phase == "leader_crashed" { [Leader down] } else { [Follower down] },
      num(med(rows.map(r => r.operations_per_second)), digits: 0),
      num(med(rows.map(r => r.latency_ms.all.p99)), digits: 2),
      str(med(rows.map(r => r.retry_attempts))))
  }).flatten()).flatten(),
)
]

Median whole-cluster restart and verification time: Zaxonlite
#num(med(samples("zaxonlite").map(r => r.total_cluster_restart.recovery_ms))) ms; rqlite
#num(med(samples("rqlite").map(r => r.total_cluster_restart.recovery_ms))) ms.
SQLodin's workload performs a clean close/reopen check; its separate SIGKILL campaign supplies
crash evidence. Those recovery measurements are different and are not compared as failover speed.

== Sequential Persisted Writes

All four systems run one client, one row per operation, with a 256-byte payload. SQL systems use
INSERT; cowsql uses its supported PUT endpoint. cowsql is omitted from the order-processing table
because the unmodified demo does not expose that SQL API. Its three persisted voter assignments are
checked before timing and all timed payloads must verify before restart. A separate optional check
attempts whole-cluster SIGKILL/restart and rechecks payloads through all three demo endpoints.
Routed endpoint reads do not independently inspect all replica images.

#let cowsql-restarts = samples("cowsql", data: disk.sequential_writes)
The stock cowsql demo's restart check succeeded in
#cowsql-restarts.filter(r => r.restart_verified).len() of #cowsql-restarts.len() repetitions.
#if cowsql-restarts.any(r => not r.restart_verified) [
  *Recovery was not verified in every repetition.* Failure messages and process logs are retained
  in JSON. This is a limitation observed at the stock demo boundary, not a diagnosis of the core
  cowsql algorithm. The table reports its verified pre-restart PUT/GET workload only.
]

#block[
#set text(size: 8pt)
#table(
  columns: (1.25fr, 0.85fr, 1.2fr, 0.85fr, 0.85fr),
  table.header([*System*], [*Writes/s*], [*Range/s*], [*p50 ms*], [*p99 ms*]),
  ..("sqlodin", "zaxonlite", "rqlite", "cowsql").map(system => {
    let rows = samples(system, data: disk.sequential_writes)
    (label(system), num(med(rows.map(r => r.operations_per_second)), digits: 0), rate-range(rows),
      num(med(rows.map(r => r.latency_ms.p50)), digits: 2),
      num(med(rows.map(r => r.latency_ms.p99)), digits: 2))
  }).flatten(),
)
]

== Resource Costs and Remaining Work

The following medians cover the sequential-write run's entire lifecycle, including startup, warmup
and verification. CPU and aggregate RSS are sampled every 10 ms. Network client processes are
excluded; SQLodin's embedded process includes its driver. Startup/recovery work differs, so these
are approximate resource footprints rather than normalized per-operation CPU costs.

#block[
#set text(size: 8pt)
#table(
  columns: (1.2fr, 0.7fr, 0.9fr, 1fr, 1fr),
  table.header([*System*], [*CPU s*], [*Peak RSS MiB*], [*Logical disk MiB*], [*Allocated MiB*]),
  ..("sqlodin", "zaxonlite", "rqlite", "cowsql").map(system => {
    let rows = samples(system, data: disk.sequential_writes)
    (label(system), num(med(rows.map(r => r.resources.sampled_database_cpu_seconds)), digits: 2),
      num(med(rows.map(r => r.resources.sampled_peak_aggregate_rss_bytes)) / 1048576),
      num(med(rows.map(r => r.disk.logical_bytes)) / 1048576),
      num(med(rows.map(r => r.disk.allocated_bytes)) / 1048576))
  }).flatten(),
)
]

Disk figures include persistent node data, logs and snapshots after shutdown, excluding controller
manifests, diagnostics and TLS keys. Sparse files and ZFS allocation/compression can make logical
and allocated sizes very different; neither number is bytes written to the device.

Read-only inspection after shutdown confirmed on-disk SQLite images for all three SQLodin,
Zaxonlite and rqlite replicas. The serial order-processing harness rotates by operation index;
uneven write admission leaves ownership gaps that require decided skips. At SQLodin's first node,
the median retained prefix contains
#num(med(samples("sqlodin").map(r => r.journal_inspection.first().chosen_slots)), digits: 0)
chosen slots, including
#num(med(samples("sqlodin").map(r => r.journal_inspection.first().skip_slots)), digits: 0)
skips, across setup, warmup and measurement. These consume protocol and persistence work without
adding SQL rows. This is evidence of workload-dependent multi-master overhead.

The durable SQLodin host retains complete history and full logical mutation values. This makes
recovery and old-range service explicit, but disk usage and startup work grow with the log. Safe
compaction requires certified snapshots. The fixed-capacity protocol layout and bounded admission
queue constrain live memory; they do not establish optimal memory/CPU use or multicore scalability.
A future matched server comparison requires transport, the transaction request protocol and distributed read
barriers, without weakening the persistence contract to improve a benchmark.
