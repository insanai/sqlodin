#import "theme.typ": callout
#let report = json("../../benchmarks/results/linux-durability-cost.json")
#assert(report.complete and report.samples.len() == 12)
#let median(values) = values.sorted().at(calc.floor(values.len() / 2))
#let rows(mode) = report.samples.filter(r => r.mode == mode)
#let num(x, digits: 2) = str(calc.round(x, digits: digits))

= Storage Costs and the Production Plan

The durable write rate needs an explanation before an optimization plan. The Linux cost profile
isolates repeated storage synchronization using the same pinned SQLite build and disk filesystem.
It retains FULL durability. A small C interposer forwards actual sync and pwrite calls unchanged
and records their count and elapsed time. The book loads `linux-durability-cost.json` directly.

== What the profile measures

Three shuffled repetitions each insert 480 timed rows after 96 warmup rows, using 256-byte payloads.
Every resulting row and payload is verified. Setup, warmup and verification are outside the timed
region. Three-voter SQLodin executes its replicas serially in one process; this is a cost diagnosis,
not a distributed capacity test. The single-threaded interposer is not a general concurrent profiler.

#table(columns: (1.7fr, 0.75fr, 0.8fr, 0.8fr),
  table.header([*Path*], [*Rows/s*], [*Syncs/row*], [*Time in sync*]),
  ..(("sqlite_full_1", "SQLite FULL / 1 row per tx"),
     ("sqlite_full_32", "SQLite FULL / 32 rows per tx"),
     ("durable_1", "SQLodin / 1 voter"),
     ("durable_3", "SQLodin / 3 serial voters")).map(item => {
    let rs = rows(item.at(0))
    (item.at(1), num(median(rs.map(r => r.rows_per_second))),
      num(median(rs.map(r => r.sync.calls / r.rows))),
      [#num(median(rs.map(r => r.sync.nanos / 1e9 / r.seconds)) * 100, digits: 1)%])
  }).flatten(),
)

#callout(title: "The bottleneck is in the durable host")[
  Roughly 90% of elapsed write time is inside synchronization calls. The serial three-voter path
  incurs about nine barriers per row across vote, decision and application persistence. Reducing
  CPU instructions alone cannot remove those waits. The efficient paxos-odin kernel remains the
  foundation; the host must amortize storage costs and let independent replicas perform I/O concurrently.
]

The 32-row SQLite transaction changes transaction granularity. It demonstrates amortization, not
an apples-to-apples comparison with 32 independently acknowledged SQL requests. File pwrite bytes
also differ substantially: the three-voter path writes about 224 KiB per row in this profile. These
are process-level file writes, not physical device traffic or ZFS allocated bytes.

== Correctness before throughput

The pre-SOD review reproduced two application failures: a chosen uniqueness violation blocked
reopening and raw `random()` created different replica values. Format 2 fixes those regression
cases with durable outcomes, retry identities and a function policy that also covers defaults.
This is partial P1 delivery; broad SQL determinism, compatibility and bounded execution remain open.

The *Production SQL and Durable Throughput* SOD keeps the complete paxos-odin pin. It proposes
bounded batches through upstream APIs, explicit durability ordering, compact canonical payloads
and serialized node ownership with asynchronous I/O. It does not copy protocol fragments or weaken
synchronization to obtain a larger benchmark number.

#pagebreak()
== Implementation gates

#table(columns: (0.45fr, 1.3fr, 2fr),
  table.header([*Phase*], [*Deliverable*], [*Required evidence*]),
  [P0], [Matched mixed-SQL baseline], [Disk-cost and separate-process diagnostics are available.
    Matched comparator runs and large-dataset calibration remain open.],
  [P1], [Transaction outcomes and deduplication], [Constraint rejection advances the replicated
    outcome; retries cannot apply twice; nondeterminism is prevented or rejected.],
  [P2], [Batching and I/O concurrency], [No messages or acknowledgements escape their durable
    prerequisites. Grouping preserves each supported transaction's semantics.],
  [P3], [Compact storage and data layout], [Payload lifetime, durable availability and recovery
    survive faults; allocation and write amplification are measured.],
  [P4], [Client, transport and read contracts], [Histories verify any-voter writes and explicit
    local, read-your-writes and linearizable read behavior.],
  [P5], [Snapshots and bounded recovery], [Certified snapshots, safe trimming and fenced voter
    replacement preserve acknowledged data and retry state.],
  [P6], [Release qualification], [Overload, crash and partition campaigns; 24-hour qualification
    and seven-day candidate soak; zero lost acknowledgements or duplicate effects.],
)

== Provisional targets and algorithm choices

For a three-machine LAN with qualified durable SSD/NVMe storage, SOD 0004 sets provisional targets of 3,000 mixed
transactions per second at 70% reads and 30% writes, with read p99 at most 20 ms and write p99 at
most 50 ms. It separately targets 1,000 sustained write transactions per second and at least 25%
of a matched durable SQLite baseline using the same commit policy. The working dataset starts at
10 GiB and grows to 100 GiB; concurrency, conflicts and larger payloads have separate cases.

These are *unverified engineering targets*, contingent on hardware qualification and P0 calibration.
They are not extrapolations from the current ZFS profile. The SOD also specifies provisional RSS,
history, recovery and overload budgets, transaction sizes and result limits.

Modern algorithms are candidates with proof obligations. Mencius-style skip coordination requires
measured gap overhead; EPaxos-style dependency ordering requires sound conflict detection for SQL
ranges, triggers and constraints. Flexible quorums require cross-phase intersection and a revised
failure model. Sharding needs its own cross-shard transaction design. None is adopted merely because
its paper reports a faster workload. The plan uses queueing models, refinement arguments and
planned TLA+/PlusCal models to connect each proposed change to a testable contract.

The accepted implementation plan is SOD 0004: `docs/sod/records/0004-production-sql-and-durable-throughput.typ`.
The profiler is `tools/profile_durability_cost.py`; reproduction instructions are in
`benchmarks/README.md`. Partial P1 implementation and upstream proposal batching are now present.
Application groups, incoming-transition journal groups, packed journals and ordered read barriers
are implemented. Asynchronous persistence, compact in-memory values, the production service and
snapshots remain open.
The current phase ledger is `docs/implementation-status.md`.

#pagebreak()
== First implementation measurements

#let p1 = json("../../benchmarks/results/linux-production-p1-batches.json")
#assert(p1.complete and p1.samples.len() == 24)
#let p1-rows(mode) = p1.samples.filter(r => r.mode == mode)
#let p1-rate(mode) = median(p1-rows(mode).map(r => r.rows_per_second))

The format-2 implementation adds request identity, durable outcomes and rejection isolation.
An initial batch API calls the complete pinned upstream library with its durability gate enforced.
It batches proposal persistence while committing every SQL request separately. Local snapshot
queries now use a read-only connection, preserving aggregates without weakening the writer policy.

This new Linux run has three shuffled repetitions of eight modes, each with 480 timed 256-byte
rows after 96 warmup rows. The four transaction modes below use one distinct session per row,
bound parameters, and verification of every replica's rows and payloads. Replicas still execute
serially on the same host. Batch storage is allocated before warmup; all FULL barriers remain.

#table(columns: (1.4fr, 0.8fr, 0.8fr, 0.9fr),
  table.header([*Transaction path*], [*Proposal batch*], [*Writes/s*], [*Syncs/request*]),
  ..(("transaction_1", "1 voter", "1"),
     ("transaction_1_batch16", "1 voter", "16"),
     ("transaction_3", "3 serial voters", "1"),
     ("transaction_3_batch16", "3 serial voters", "16")).map(item => {
    let rs = p1-rows(item.at(0))
    (item.at(1), item.at(2), num(p1-rate(item.at(0))),
      num(median(rs.map(r => r.sync.calls / r.rows)), digits: 3))
  }).flatten(),
)

Batching raises the median rate by
#num(p1-rate("transaction_1_batch16") / p1-rate("transaction_1")) times for one voter and
#num(p1-rate("transaction_3_batch16") / p1-rate("transaction_3")) times for three serial voters.
The modest three-voter gain is consistent with leaving most acceptor, decision and application
barriers intact. This is an initial optimization measurement, not completed group commit or an
achievement of the production targets. Do not compare the new retry-safe request rates with old
raw-SQL rates as though batching were the only implementation or environment change.

The source and binary hashes, native dependencies, filesystem and raw samples are in
`benchmarks/results/linux-production-p1-batches.json`. The book loads this JSON directly. A fresh
run must use a new output path; the profiler refuses to overwrite recorded evidence.

== Verification and remaining gates

The matching Linux checks cover 62 SQLodin tests and 79 upstream tests in debug and optimized
builds, 150,000 modeled fault steps and thirteen process-crash scenarios. New crash cases exercise
successful and rejected transactions at journal/application/completion boundaries, then retry the
same identity after recovery. A separate small mixed-SQL regression verifies order, ledger, stock,
index and trigger behavior on all three replicas before and after restart.

These checks support the implemented contract. P1 still needs broader deterministic admission,
engine/schema compatibility, write execution quotas and result handling. Later work adds application
groups, separate voter processes, packed journals and ordered read barriers. Authenticated transport,
certified snapshots, bounded history/recovery and endurance remain release gates. See the current
implementation ledger; this historical measurement is not production qualification.
