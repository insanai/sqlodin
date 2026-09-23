#import "theme.typ": callout
#let run = json("../../benchmarks/results/linux18-native-comparison-complete.json")
#let env = json("../../benchmarks/results/linux18-native-environment.json")
#assert(run.complete)
#assert(env.address == "10.175.52.18")
#assert(run.realworld.len() + run.failures.filter(r => r.group == "realworld").len() == 3 * run.workload.repeats)
#assert(run.sequential_writes.len() + run.failures.filter(r => r.group == "sequential_writes").len() == 4 * run.workload.repeats)
#let med(values) = {
  let v = values.sorted()
  let n = v.len()
  let middle = calc.floor(n/2)
  if calc.odd(n) { v.at(middle) }
  else { (v.at(middle - 1) + v.at(middle)) / 2 }
}
#let num(value, digits: 1) = str(calc.round(value, digits: digits))
#let label(system) = (sqlodin: "SQLodin", zaxonlite: "Zaxonlite", rqlite: "rqlite", cowsql: "cowsql demo").at(system)
#let rows(system, group: run.realworld) = group.filter(r => r.system == system)
#pagebreak()
= Native Network Benchmark Evaluation

These measurements run on the designated benchmark host, `insan@10.175.52.18`,
with three voter processes per product and persistent ZFS data directories. They
measure the current native SQLodin mTLS service, including real socket transport
and fresh quorum barriers for reads. Earlier embedded and SSH-fixture measurements
retain their historical execution boundaries and hardware; do not combine them
into a single ranking.

The existing harness matches the vendored workload. Versions are SQLodin format 4 /
policy 6, Zaxonlite v0.7.0, rqlite v10.2.7, and stock go-cowsql v1.22.0 with libcowsql
v1.15.9. JSON retains binary hashes, dependency manifests and every repetition.
Qualification activity ran concurrently on the other three instances. Independent
physical CPU/storage failure domains and exclusive benchmark hardware were not established.

== Mixed transactional SQL

The order-processing workload generates approximately 70% reads and 30% writes.
Order inserts drive inventory updates, order lines and ledger entries through a
trigger. Reads include indexed lookups, customer histories and dashboard aggregates.
All products use the same generated operation sequences: #run.workload.operations
operations per measured phase, #run.workload.warmup warmup operations,
#run.workload.concurrency client workers and #run.workload.repeats repetitions.
SQLodin clients start at different voters. This is native one-request transaction
traffic, not a measurement of interactive ORM preview/commit overhead.

#figure(image("plots/native-healthy.svg", width: 100%),
  caption: [Healthy service measurements from successful samples. Labels show
    sample counts; medians and observed min–max are not confidence intervals.
    The latency axis is logarithmic.])

#callout(title: "A failed repetition is part of the result", kind: "warning")[
The third Zaxonlite mixed-SQL attempt failed during schema/seed setup with
“database disk image is malformed.” Read-only integrity checks on the stopped
replicas confirmed that error on two databases; the third reported OK. Data, logs
and hashes are preserved; the root cause is not established. Charts contain two
successful mixed samples for Zaxonlite and three each for SQLodin/rqlite. This is
not an all-run success rate or a general reliability ranking.
]

*Persistence and service contracts differ.* SQLodin uses mTLS and on-disk SQLite
with WAL FULL application and Paxos commits. Zaxonlite uses mTLS, a full-sync Paxos
log and SQLite WAL NORMAL; rqlite uses HTTP, persistent Raft state and on-disk SQLite.
Each uses its own linearizable reads. Encoding, TLS, batching and persistence costs
remain part of these measurements; short shared-host runs do not establish capacity.

#pagebreak()
== Failure phases and resource cost

After the healthy phase, the harness kills one peer voter, continues traffic, then
restarts it and checks catch-up. It next kills the entry voter for SQLodin, or the
leader for the leader-based systems. SQLodin has rotating slot ownership and no
standing leader, so these are distinct failure roles. Finally, all voters are killed
and reopened; generated order/ledger/inventory invariants and per-node integrity
must pass. Latency includes retries and recovery stalls.

#figure(image("plots/native-failures.svg", width: 100%),
  caption: [Continued traffic with a voter down. The right-hand latency axis is
    logarithmic. Each plot uses medians and observed min–max across repetitions.])

#table(columns: (1fr, 1fr, 1fr, 1fr),
  table.header([*System*], [*CPU seconds*], [*Peak RSS MiB*], [*Disk MiB*]),
  ..("sqlodin", "zaxonlite", "rqlite").map(system => {
    let r = rows(system)
    (label(system), num(med(r.map(x => x.resources.sampled_database_cpu_seconds))),
     num(med(r.map(x => x.resources.sampled_peak_aggregate_rss_bytes))/1048576),
     num(med(r.map(x => x.disk.allocated_bytes))/1048576))
  }).flatten(),
)

CPU and peak aggregate resident memory are sampled from database child processes
every 10 ms. They cover setup, all workload phases, verification and restart;
Python client/coordinator CPU is excluded. Disk is allocated persistent data after
shutdown. These lifecycle measurements are not per-operation CPU costs, peak
working-set proofs or evidence of optimal resource use. In particular, a product
can have low CPU utilization while waiting for synchronization or protocol timers.
Summed RSS can count shared pages more than once; it is not unique physical RAM.
The instance exposes #env.cpu_affinity.len() logical CPUs. ZFS mounts are verified;
pool sync settings and physical power-loss behavior are not independently verified.

SQLodin's service advances consensus timers every 100 ms, and the pinned ownership
implementation uses a ten-tick stall timeout before revoking missing slots. These
mechanisms are relevant to the observed voter-loss stalls; the measurements alone
do not isolate each one's contribution. Improving scheduling, read fencing and
persistence batching requires further profiling and correctness checks. Odin's
efficient machine code alone does not remove these distributed coordination costs.
The native service also invokes the durable host once per received consensus
packet; it does not yet feed the host's bounded incoming-transition batch API.
That makes network-service journal batching a concrete follow-up to measure,
alongside event-driven idle-slot propagation and lower-cost safe read fences.

The eight-hour qualification uses `.19`, `.20` and `.21` separately. Its status is
reported in `docs/cluster-qualification.md`; short benchmark recovery checks cannot
stand in for a completed endurance run.

#pagebreak()
== The common sequential write workload

The common case inserts 256-byte values sequentially. It uses the same operation,
warmup and repetition counts. Cowsql is measured only through the stock demo's
supported HTTP PUT/GET path. Its SQLite image is in memory, with durable Raft logs
and snapshots on disk. That is a different persistence design from SQLodin's on-disk
SQLite application; the chart does not relabel it as an on-disk SQLite database.

#figure(image("plots/native-sequential.svg", width: 100%),
  caption: [Sequential acknowledged writes. Product-specific persistence paths
    remain part of the result; medians and observed min–max across repetitions.
    The latency axis is logarithmic.])

#table(columns: (1fr, 1fr, 1fr, 1fr),
  table.header([*System*], [*CPU seconds*], [*Peak RSS MiB*], [*Disk MiB*]),
  ..("sqlodin", "zaxonlite", "rqlite", "cowsql").map(system => {
    let r = rows(system, group: run.sequential_writes)
    (label(system), num(med(r.map(x => x.resources.sampled_database_cpu_seconds))),
     num(med(r.map(x => x.resources.sampled_peak_aggregate_rss_bytes))/1048576),
     num(med(r.map(x => x.disk.allocated_bytes))/1048576))
  }).flatten(),
)

These are whole-lifecycle medians, including membership setup, verification and
recovery. They use the same sampling scope and limitations as the mixed-SQL table.

The cowsql runner waits for three persisted voter assignments and validates every
measured value. It also attempts a full-cluster restart without changing the product
or demo. Restart outcomes are retained separately in the JSON, including failures;
a throughput measurement never implies a successful recovery check.

#let cow = rows("cowsql", group: run.sequential_writes)
Cowsql restart verification succeeded in #cow.filter(r => r.restart_verified).len()
of #cow.len() repetitions. SQLodin's sequential runs verify all stored values by
count after all-voter restart; the mixed-SQL suite performs richer state invariants.
The rqlite/Zaxonlite sequential adapter uses the reference retry-capable clients
with idempotent row keys and checks counts/payloads after all-voter restart.
The original simple helper stopped on an ambiguous Zaxonlite setup response;
that failed report is retained. Completed mixed samples were reused only after
matching binary, workload and adapter-source checks. No database binary was patched.

The source data is `benchmarks/results/linux18-native-comparison-complete.json`.
See `benchmarks/README.md` for reproduction commands and the preserved failure reports.
