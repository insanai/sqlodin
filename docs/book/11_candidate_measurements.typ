#import "theme.typ": callout
#let report = json("../../benchmarks/results/linux-candidate-v3-cost.json")
#assert(report.complete and report.samples.len() == 24)
#let median(values) = values.sorted().at(calc.floor(values.len() / 2))
#let rows(mode) = report.samples.filter(r => r.mode == mode)
#let num(x, digits: 2) = str(calc.round(x, digits: digits))
#let rate(mode) = median(rows(mode).map(r => r.rows_per_second))

#pagebreak()
= Candidate: Group Commit and Process Isolation

The format-3 candidate retains the pinned paxos-odin library and FULL synchronization. It adds
independent SQL outcomes within application groups, lossless packed journal records and fresh
consensus barriers for ordered reads. Application groups contain at most sixteen requests.
Deferred foreign keys are checked at each request boundary; a transaction-wide SQL rollback
replays the unacknowledged group through the individual-commit reference path.

== Disk-cost measurement

This table loads `linux-candidate-v3-cost.json`. The diagnostic uses the same pinned SQLite build
on Linux ZFS, three shuffled repetitions, 96 warmup rows and 480 timed rows per sample. Each row
has a 256-byte payload. All rows are checked. Its replicas execute serially in one process;
this isolates storage costs and does not measure a production service's capacity.

#table(columns: (1.65fr, 0.65fr, 0.8fr, 0.9fr),
  table.header([*Path*], [*Batch*], [*Writes/s*], [*Syncs/request*]),
  ..(("sqlite_full_1", "SQLite FULL", "1"),
     ("sqlite_full_32", "SQLite FULL", "32 rows"),
     ("transaction_1", "SQLodin / 1 voter", "1"),
     ("transaction_1_batch16", "SQLodin / 1 voter", "16"),
     ("transaction_3", "SQLodin / 3 serial voters", "1"),
     ("transaction_3_batch16", "SQLodin / 3 serial voters", "16")).map(item => {
    let rs = rows(item.at(0))
    (item.at(1), item.at(2), num(rate(item.at(0))),
      num(median(rs.map(r => r.sync.calls / r.rows)), digits: 3))
  }).flatten(),
)

Application grouping improves the one-voter median by
#num(rate("transaction_1_batch16") / rate("transaction_1")) times in this run.
The three-voter improvement is
#num(rate("transaction_3_batch16") / rate("transaction_3")) times. Its remaining
acceptor and decision barriers dominate: this snapshot predates cross-transition journal batching.
The SQLite 32-row case is one transaction per batch, while SQLodin retains sixteen independently
identified request outcomes. It is an amortization reference, not a matched transaction contract.

#callout(title: "A measured improvement, with release gates still open")[
  The candidate improves one-voter grouped throughput substantially. The three-voter result still
  falls well short of the provisional production targets. A faster implementation language alone
  cannot remove serial durable barriers. The next optimization must preserve the complete
  persist-before-message contract while amortizing those barriers.
]

This profile required eighteen passing crash cases for the exact runtime source snapshot before
starting. Later journal-group builds require twenty-two cases. Its JSON retains source and binary hashes, native dependency versions, filesystem details,
the supporting durability-report digest and all individual samples. These tests inject process
crashes; they do not establish physical power-loss behavior of the host's storage stack.

#pagebreak()
== Three independent voters on one Linux host

#let process-report = json("../../benchmarks/results/linux-candidate-v3-process-2400-v2.json")
#assert(process-report.complete and process-report.read_mode == "fenced")
#let sample = process-report.sample

The authorized deployment uses three SQLodin processes, each with its own directory on ZFS.
A parallel Python controller routes bounded framed-pipe messages. This candidate run performs
#sample.operations mixed operations: #sample.reads ordered reads and #sample.writes transactional
transfers. Each transfer updates two account balances, inserts a 256-byte payload and fires a
two-entry audit trigger. Foreign keys, a secondary index and CHECK constraints are active.
Timed reads check one hot account balance; transfers use distinct request sessions.

#table(columns: (1.5fr, 1fr),
  table.header([*Measured quantity*], [*Result*]),
  [Timed mixed operations/s], [#num(sample.operations_per_second)],
  [Timed writes/s within the mix], [#num(sample.writes / sample.seconds)],
  [Read latency p50 / p99],
    [#num(sample.read_latency_ms.p50) / #num(sample.read_latency_ms.p99) ms],
  [Write latency p50 / p99],
    [#num(sample.write_latency_ms.p50) / #num(sample.write_latency_ms.p99) ms],
  [Timed voter CPU, all three processes], [#num(sample.voter_cpu_seconds_timed) CPU-seconds],
  [Peak RSS per voter],
    [#sample.peak_rss_bytes_per_voter.map(n => num(n / 1048576)).join(" / ") MiB],
)

Setup is outside timing. Closed-loop waves admit at most twelve writes or three fenced reads;
the driver, framing and scheduling costs are included in latency and throughput. CPU covers voters
over the timed interval; RSS is each voter's observed process high-water mark, including fault
phases. These small databases do not establish resource bounds for large datasets or long histories.

After timing, all replicas must pass exact transfer, amount, endpoint, payload, audit-pair and
balance checks. Nine workload/fault checks cover fresh read fences, uncertain and acknowledged
retries through another master, whole-cluster SIGKILL, minority isolation, surviving-quorum writes,
offline-voter catch-up and an immediate fenced read on a stale restarted voter. The final recovery
verifies #sample.verified_transfers_including_fault_phases transfers including the fault phases.

An earlier attempt exhausted the read-work budget in its correlated verification query. That
failed run remains recorded. The verifier now uses bounded exact-state checks; the runtime read
limit is unchanged. The successful report and its source hashes are
`linux-candidate-v3-process-2400-v2.json`.

#callout(title: "Qualification boundary")[
  This is one machine with three isolated processes and directories, as currently authorized.
  It exercises process failure and controller-simulated partitions. It does not test independent
  machine failures, a production network service, physical power cuts or 24-hour/seven-day endurance.
  The measured throughput and latency do not meet SOD 0004's provisional release targets.
]
