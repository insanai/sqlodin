#import "theme.typ": callout
#let costs = json("../../benchmarks/results/linux-journal-final-cost.json")
#let matched = json("../../benchmarks/results/linux-journal-matched-process.json")
#assert(costs.complete and costs.samples.len() == 24)
#assert(matched.complete and matched.samples.len() == 6 and matched.repeats == 3)
#let median(xs) = xs.sorted().at(calc.floor(xs.len() / 2))
#let num(x, digits: 2) = str(calc.round(x, digits: digits))
#let cost-rows(mode) = costs.samples.filter(r => r.mode == mode)
#let runs(mode) = matched.samples.filter(r => r.mode == mode).map(r => r.sample)
#let rates(mode) = runs(mode).map(r => r.operations_per_second)

#pagebreak()
= Grouped Paxos Journal Transitions

The next P2 change groups already-received Paxos transitions behind one durable journal commit.
`durable.step_batch` accepts at most sixteen packets. It immediately encodes pending writes and
copies borrowed values into bounded owned storage before calling the upstream library again.
A subgroup commits before that storage fills. User SQL and outgoing packets wait for the successful
FULL journal barrier; the applied watermark and request outcomes retain their application boundary.

The grouped build uses the complete pinned paxos-odin library's `Host_Managed` integration contract.
A durable sequence frontier guards release. Compile with `SQLODIN_JOURNAL_GROUP_COMMIT=false` for
the `Enforced` per-transition reference. This is synchronous grouping, not asynchronous persistence.
The journal remains format 3 / SQL policy 4. See `docs/journal-group-commit.md` for the ownership
bounds, failure behavior and refinement argument.

== Repeated disk-cost attribution

This table loads `linux-journal-final-cost.json`: three shuffled repetitions of eight modes,
480 timed rows and 96 warmup rows per sample, with the same 256-byte payload and pinned SQLite.
Incoming delivery uses reusable sixteen-packet buffers by destination. Replicas still execute
serially in one process. Every FULL sync is forwarded unchanged and every stored row is checked.

#table(columns: (1.65fr, 0.65fr, 0.8fr, 0.9fr),
  table.header([*Path*], [*Proposal batch*], [*Writes/s*], [*Syncs/request*]),
  ..(("sqlite_full_1", "SQLite FULL", "1 row"),
     ("sqlite_full_32", "SQLite FULL", "32 rows"),
     ("transaction_1", "SQLodin / 1 voter", "1"),
     ("transaction_1_batch16", "SQLodin / 1 voter", "16"),
     ("transaction_3", "SQLodin / 3 serial voters", "1"),
     ("transaction_3_batch16", "SQLodin / 3 serial voters", "16")).map(item => {
    let rs = cost-rows(item.at(0))
    (item.at(1), item.at(2), num(median(rs.map(r => r.rows_per_second))),
      num(median(rs.map(r => r.sync.calls / r.rows)), digits: 3))
  }).flatten(),
)

The SQLite 32-row case retains a different transaction contract. SQLodin's batches contain
independently identified requests with independent outcomes. Changes from earlier chapters also
include delivery scheduling and shared-host conditions; those historical tables are not controlled
single-variable comparisons. The next experiment supplies the matched journal-group comparison.

#callout(title: "Crash prerequisites and bounded ownership")[
  The profiler requires twenty-two passing disk crash cases for this exact runtime snapshot and
  journal-group configuration. New cases preserve a promise and fifteen votes across journal and
  response-release boundaries. Tests also overwrite a borrowed ledger value and exceed the pending
  reply buffer, checking that copied replies and recovery remain correct. These are process-crash
  and regression checks, not physical power-loss certification or a completed formal proof.
]

#pagebreak()
== Matched three-process mixed workload

`linux-journal-matched-process.json` contains three repetitions of each mode. Both use identical
source, optimized build settings, fresh on-disk directories, three voters on the authorized Linux
host and the same framed-pipe controller. The journal-group flag is the sole build difference.
Mode order is shuffled within each repetition; each pair shares its seed. Each sample executes
#matched.operations operations with the 70% read / 30% transfer generator and fresh ordered reads,
then must pass the complete nine-check fault and exact-state campaign.
The timed reads check one hot account balance. Each transfer uses a distinct session; long-lived
client sequence reuse, range-heavy reads and larger datasets remain separate calibration cases.

#table(columns: (1.3fr, 0.8fr, 1fr, 0.9fr, 0.9fr),
  table.header([*Journal mode*], [*Mixed ops/s*], [*Min-max ops/s*], [*Read p99 ms*], [*Write p99 ms*]),
  ..(("reference", "Per transition"), ("grouped", "Grouped")).map(item => {
    let rs = runs(item.at(0))
    let xs = rates(item.at(0))
    (item.at(1), num(median(xs)), [#num(calc.min(..xs)) - #num(calc.max(..xs))],
      num(median(rs.map(r => r.read_latency_ms.p99))),
      num(median(rs.map(r => r.write_latency_ms.p99))))
  }).flatten(),
)

The ratio of median mixed throughput is
#num(median(rates("grouped")) / median(rates("reference"))) times. Latency summaries above are
medians of per-run percentiles, not pooled percentiles. Raw samples retain counts, durations,
percentiles, CPU, per-voter peak RSS, checks and source/binary hashes. No failed run is counted as
completed work. The machine is shared; three repetitions do not remove all environmental variation.

#table(columns: (1.4fr, 1.3fr, 1.3fr),
  table.header([*Journal mode*], [*Timed voter CPU, seconds*], [*Largest voter peak RSS, MiB*]),
  ..(("reference", "Per transition"), ("grouped", "Grouped")).map(item => {
    let rs = runs(item.at(0))
    (item.at(1), num(median(rs.map(r => r.voter_cpu_seconds_timed))),
      num(median(rs.map(r => calc.max(..r.peak_rss_bytes_per_voter))) / 1048576))
  }).flatten(),
)

CPU covers all voters over each timed interval. RSS includes setup and fault phases and is the
largest per-voter process high-water mark in each run. The controller is outside those resource
counters but inside measured completion latency and throughput. These short, small-dataset runs
do not establish memory or recovery bounds for continuous ingestion.

#callout(title: "Production status remains unchanged")[
  Journal grouping addresses measured storage overhead. The later native-service chapter adds
  authenticated networking. This experiment does not establish
  complete SQL determinism, deterministic write quotas, certified snapshots, bounded retained history
  or endurance qualification. Multi-master admission still requires a quorum and applies every write
  at every replica. SQLodin is not yet production-ready.
]
