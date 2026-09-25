#import "theme.typ": callout
#import "figures.typ": metric-bar
#let matrix = json("../../benchmarks/results/verification-20260924/workload-matrix-analysis-linux.json")
#let native = json("../../benchmarks/results/verification-20260924/workload-matrix-linux.json")
#let comparison = json("../../benchmarks/results/linux18-native-comparison-complete.json")
#assert(matrix.complete and native.complete and comparison.complete)
#let number(n, digits: 1) = str(calc.round(n, digits: digits))
#let sample(reads) = matrix.cases.find(c => c.parameters.clients == 32
  and c.parameters.reads == reads and c.parameters.payload == 256
  and c.parameters.statements == 1 and c.parameters.rows == 1
  and not c.parameters.skew and c.parameters.rate == 0)
#let mixed = sample(70)
#let writes = sample(0)
= Performance evaluation
<benchmarks>

A benchmark answers a question about a particular workload, build and machine. It does
not rank database languages. This chapter separates SQLodin's durable workload matrix
from an earlier comparison with other systems. Tables read the retained JSON directly.
Failures stay in the evidence even when a chart shows only completed repetitions.

== The durable workload matrix

The designated benchmark instance is Linux host `.18`. Three native mTLS voters use
separate directories on persistent ZFS storage. The matrix uses SQLite FULL durability
for application and consensus state, and fresh barriers for reads. It covers 1/8/32/64
clients; 70/30, 50/50, 95/5 and pure-write mixes; 1–8 statements; 1–4 row changes;
256-byte and 4 KiB values; skew; and entry through every voter.

The #matrix.cases.len() cases verify #matrix.operations_verified operations. The source
reports identify the binary, workload, seeds, individual latency distributions and
resource counters. The matrix predates the final maintenance-budget and one-transaction
replay scheduling fixes. It is performance evidence for that recorded candidate,
not a fresh timing measurement of the final artifact.

The SQLite reference runs the matched SQL and schema with FULL synchronization and
bounded grouping of up to sixteen already waiting requests. It is one engine with no
TLS or replication. That difference is the baseline's purpose and must remain visible.

#table(columns: (1.1fr, 1fr, 1fr, 1fr),
  table.header([32 clients; 256 B], [SQLodin tx/s], [SQLite tx/s], [SQLite fraction]),
  ..(70, 50, 95, 0).map(reads => {
    let c = sample(reads)
    ([#reads% reads], number(c.native_tps), number(c.sqlite_tps),
      [#number(100*c.sqlite_fraction)%])
  }).flatten(),
)

#figure(block[
  #metric-bar([70/30 SQLodin], mixed.native_tps, mixed.sqlite_tps, [#number(mixed.native_tps) tx/s])
  #v(7pt)
  #metric-bar([70/30 SQLite], mixed.sqlite_tps, mixed.sqlite_tps, [#number(mixed.sqlite_tps) tx/s])
  #v(13pt)
  #metric-bar([Writes SQLodin], writes.native_tps, mixed.sqlite_tps, [#number(writes.native_tps) tx/s])
  #v(7pt)
  #metric-bar([Writes SQLite], writes.sqlite_tps, mixed.sqlite_tps, [#number(writes.sqlite_tps) tx/s])
], caption: [Matched durable SQL, different system boundaries. Both pairs use one shared linear scale.])

The 70/30 case completes #number(mixed.writes_per_second) successful writes/s within
#number(mixed.native_tps) total transactions/s. Its read/write p99 latencies are
#number(mixed.latency_ms.read.p99) / #number(mixed.latency_ms.write.p99) ms.
The pure-write case completes #number(writes.native_tps) writes/s with
#number(writes.latency_ms.write.p99) ms write p99. These are measured cases, not maxima.

Closed-loop latency starts at actual invocation. Scheduled-arrival cases include waiting
from the offered arrival time. Do not mix the two distributions: a closed-loop client
stops generating arrivals while it waits. The reports name the latency basis explicitly.

#pagebreak()
== Targets remain visible

#table(columns: (1.4fr, 1.4fr),
  table.header([Original provisional goal], [Disposition]),
  [3,000 mixed tx/s; 900 writes/s], [Not achieved; future improvement goal.],
  [1,000 pure writes/s], [Not achieved; future improvement goal.],
  [Read/write p99 ≤ 20/50 ms], [Not achieved; future improvement goal.],
  [At least 25% of matched SQLite rate], [Not achieved in the matrix.],
)

The owner accepted release after correctness qualification with these shortfalls disclosed.
The original numbers were not changed into lower passing thresholds. This release should
not be selected on the assumption that those rates or latencies have been delivered.

Whole-process mean synchronization times in the matrix range from roughly 5.5 to 21.2 ms.
Low CPU use alongside these waits points toward durability and coordination costs, not
proof of an efficient or inefficient compiler. The observations include setup, validation
and shutdown where the report says so. They are not isolated SQL-statement measurements.

The earlier healthy-path 100 ms ownership wait has a deterministic no-tick regression.
Missing-owner recovery still uses failure detection. Changing one timer or language cannot
remove storage barriers, prefix dependencies and application work at the same time.

== After SOD 0005: fewer sequential barriers

The measurements above describe the qualified release candidate. SOD 0005 traced up to seven
sequential sync barriers per write and per fresh read. It then introduced one barrier per service
turn, one-message learning of owner no-ops (and, with three voters, of values this voter also voted
for), a WAL NORMAL application cache of the FULL journal, and quorum-frontier reads. The same
calibration matrix, with SQLite measured in the same run on `.18`, moved from 1.7–10.5% to
6.8–40.6% of SQLite; the absolute gain is 1.9–10.5× per case. On three separate hosts, 24-client
pure writes rose from 133 to 651 per second, and a sequential fresh read fell from 55.5 to 0.58 ms.
Thirty-two-client pure writes remain far below the 25% goal on the shared-disk host. The reports,
including failed attempts, are in `benchmarks/results/sod-0005/`, and SOD 0005 records the method
and the remaining gaps.

== Earlier cross-system evaluation

The retained comparison ran three voter processes per system on `.18`, using native
clients and persistent directories. It measured SQLodin format 4 / policy 6, Zaxonlite
v0.7.0, rqlite v10.2.7 and the stock go-cowsql v1.22.0 demo with libcowsql v1.15.9.
These are historical builds; the chart is not a comparison of today's releases.

The mixed workload uses order, inventory and ledger changes with indexed reads and dashboard
queries. Each measured phase has #comparison.workload.operations operations after
#comparison.workload.warmup warmups, with #comparison.workload.concurrency client workers
and #comparison.workload.repeats attempted repetitions. SQLodin admits through different
voters. The cowsql demo has no matching arbitrary-SQL endpoint, so it is not forced into
this mixed profile.

#figure(image("plots/native-healthy.svg", width: 100%), caption: [Historical mixed-SQL comparison.
Successful sample counts are shown in the chart. Whiskers are observed ranges, not confidence intervals.])

One Zaxonlite mixed repetition failed during setup with a malformed database error.
Stopped-database checks confirmed the error on two replicas; its cause was not established.
Two successful mixed samples appear in its chart, versus three for SQLodin and rqlite.
This is neither an all-attempt success rate nor a general reliability ranking.

Persistence differs. SQLodin uses FULL application and Paxos commits. That Zaxonlite build
uses a full-sync Paxos log and SQLite WAL NORMAL. rqlite uses persistent Raft state and
on-disk SQLite. TLS/HTTP transport and product batching remain part of each result. A common
SQL statement does not make the persistence paths identical.

The common sequential workload inserts 256-byte values. It includes cowsql only through
its supported HTTP PUT/GET demo. The demo keeps its SQLite image in memory while persisting
Raft logs and snapshots on disk. That is durable replicated state, but not an on-disk
SQLite application image like SQLodin's.

#figure(image("plots/native-sequential.svg", width: 100%), caption: [Historical sequential writes.
Product-specific persistence remains part of the result; the latency axis is logarithmic.])

#let cow = comparison.sequential_writes.filter(r => r.system == "cowsql")
Cowsql's full-cluster restart verification succeeded in
#cow.filter(r => r.restart_verified).len() of #cow.len() repetitions. Those restart
results are separate from throughput. Other completed runs also check acknowledged
state after voter loss and restart. Raw failures and sample hashes remain in
`benchmarks/results/linux18-native-comparison-complete.json`.

== Capacity, recovery and topology

Lightweight current-candidate checks complete snapshot publication, restart and exact
key counts. The 64 MiB fixture restarts in 1.32 seconds. A prior candidate completed a
10 GiB payload run and restarted in 14.89 seconds. Retained larger-store continuations
took 114 and 137 seconds to become ready, exceeding the original 60-second goal.
Integrity scanning dominated those observations.

The later growth campaign was stopped at the owner's request at its last saved 32 GiB
checkpoint. It is interrupted evidence, not a passed 64 GiB test. Large-capacity campaigns
and fixed soak durations are not release requirements. Targeted proofs and fault tests
support the stated release scope; they do not imply an unmeasured capacity or recovery SLA.

The three-instance fault checks use `.19`, `.20` and `.21`. Their first writes after
removing each voter take about 2.37, 1.24 and 2.48 seconds. This meets the five-second goal
in that campaign, not under every disk or network delay. Physical failure-domain independence,
exclusive hardware and device power-loss protection were not established. Shared ZFS I/O
pressure was observed during large-data work.

Use #link("../../benchmarks/README.md")[the benchmark guide] for reproduction and the
#link("../../benchmarks/results/verification-20260924/release-decision.json")[release manifest]
for the exact evidence binding. Historical memory-only and embedded runs remain in the
archive; they must not be combined with network/durable measurements into a single ranking.
