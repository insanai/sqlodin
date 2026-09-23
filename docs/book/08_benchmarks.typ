#import "theme.typ": blue, gray, callout

#let report = json("../../benchmarks/results/linux-latest.json")
#assert(report.complete, message: "The book requires a completed benchmark report")
#assert(report.format == 1, message: "Unsupported benchmark report version")
#let rows = report.summary
#let pick(variant, mode, batch, payload: 256) = {
  let matches = rows.filter(r => r.variant == variant and r.mode == mode and
    r.batch == batch and r.payload_bytes == payload)
  assert(matches.len() == 1 and matches.first().verified)
  matches.first()
}
#let number(n, digits: 1) = str(calc.round(n, digits: digits))
#let mode-name(mode) = if mode == "multi" { [Multi-master] } else if mode == "single" {
  [Single leader]
} else { [Local SQLite] }

= Historical In-Memory Linux Measurements

The source snapshot in this chapter predates the durable host and later SQL authorization fixes.
Its JSON is retained unchanged as historical evidence; the next chapter measures persisted workloads.

== Measurement Scope

The measurements below are loaded directly from
`benchmarks/results/linux-latest.json`, including every sample, build flags, binary/source hashes,
and machine metadata. Run date: #report.run_at_utc.slice(0, 10). Host: #report.host.hostname,
Linux #report.host.architecture,
#report.host.lscpu.lscpu.find(r => r.field == "Model name:").data, process pinned to logical CPU
#report.host.cpu_affinity.first(). The machine was not exclusively reserved.

Compiler: #report.odin. Native dependencies: SQLite #report.native_build.sqlite and
sqlite-vec #report.native_build.sqlite_vec. Both are built from verified amalgamations. The full
Paxos dependency is pinned to #raw(report.paxos_pin.slice(0, 12)).

#callout(title: "These are in-process application measurements", kind: "warning")[
  Multi-master and single-leader cases run three SQLite memory databases in one thread and wait
  for application on every replica. They include payload copies and consensus transitions, but
  exclude sockets, wire encoding, a consensus journal, durable fsync and WAN forwarding. They
  cannot establish that SQLodin is faster than Zaxonlite or cowsql as a durable database service.
]

Every case has #report.methodology.samples fresh-process repetitions, each with
#report.methodology.warmup warmup writes followed by #report.methodology.iterations measured writes.
The runner shuffles all 36 case/build combinations per round with a recorded seed. It retains every
sample and verifies all keys, values, text payloads, row counts and applied prefixes after timing.
The integer-key dataset grows throughout each sample.

Batch 1 drains each proposal before the next. Batch 12 submits four writes from each master before
message delivery; the single-leader case submits twelve to the leader. Local SQLite is the same
application engine without replication and applies a batch in one transaction. Replicated modes
apply each contiguous committed effects batch, which can yield different transaction counts.

== Throughput and Completion Latency

The following table uses the optimized build and 256 bytes of text per row. Rates are medians
across repetitions. Latency is the median of each repetition's measured batch percentile, in
microseconds. For batch 12 it is completion time for the whole group, not per-write latency.

#block(above: 0.6em, below: 0.7em)[
#set text(size: 8pt)
#table(
  columns: (1.35fr, 0.5fr, 1fr, 1.25fr, 0.8fr, 0.8fr),
  table.header([*Mode*], [*Batch*], [*Writes/s*], [*Min–max/s*], [*p50 µs*], [*p99 µs*]),
  ..("multi", "single", "sqlite").map(mode => (1, 12).map(batch => {
    let r = pick("optimized", mode, batch)
    (mode-name(mode), str(batch), number(r.ops_per_second.median, digits: 0),
      [#number(r.ops_per_second.min, digits: 0)–#number(r.ops_per_second.max, digits: 0)],
      number(r.batch_p50_us.median), number(r.batch_p99_us.median))
  }).flatten()).flatten(),
)
]

#let multi = pick("optimized", "multi", 1)
#let single = pick("optimized", "single", 1)
With one operation in flight, multi-master achieves
#number(multi.ops_per_second.median / single.ops_per_second.median * 100)% of single-leader
throughput in this local workload. The design allows admission at every member; it does not promise
that the extra protocol work will outperform a leader in a single-thread, zero-network test. Balanced
admission also avoids the idle-owner holes that arise under skewed production traffic.

== CPU and Memory

#block(above: 0.6em, below: 0.7em)[
#set text(size: 8pt)
#table(
  columns: (1.3fr, 0.5fr, 1fr, 1fr, 1fr),
  table.header([*Mode*], [*Batch*], [*CPU, one core*], [*Peak RSS MiB*], [*RSS range MiB*]),
  ..("multi", "single", "sqlite").map(mode => (1, 12).map(batch => {
    let r = pick("optimized", mode, batch)
    (mode-name(mode), str(batch), [#number(r.process_cpu_percent_of_one_core.median)%],
      number(r.peak_rss_bytes.median / 1048576, digits: 2),
      [#number(r.peak_rss_bytes.min / 1048576, digits: 2)–#number(r.peak_rss_bytes.max / 1048576, digits: 2)])
  }).flatten()).flatten(),
)
]

CPU and peak RSS come from each child's `wait4` result and include startup, warmup, verification
and cleanup. Throughput excludes those phases. CPU percent is relative to one core; RSS includes
the growing SQLite dataset, runtime, consensus state and queue. No hardware-counter or multi-core
study was performed, so the results do not establish globally optimal resource utilization.

== Measured Data-Layout Changes

The reference build already uses prepared statements and the shared vector buffer. It rebuilds
SQL text to find cached statements and starts its queue at 256 packets. The shape-cache build
matches bounded table/column metadata directly and avoids formatting SQL on a hit. The optimized
build additionally starts the growing FIFO at 32 packets. Both cache representations remain bounded.

#block(above: 0.6em, below: 0.7em)[
#set text(size: 8pt)
#table(
  columns: (1.3fr, 1fr, 1fr, 1fr),
  table.header([*Multi-master, batch 1*], [*Writes/s*], [*p99 µs*], [*Peak RSS MiB*]),
  ..("reference", "shape_cache", "optimized").map(variant => {
    let r = pick(variant, "multi", 1)
    (variant, number(r.ops_per_second.median, digits: 0), number(r.batch_p99_us.median),
      number(r.peak_rss_bytes.median / 1048576, digits: 2))
  }).flatten(),
)
]

#let reference = pick("reference", "multi", 1)
The optimized median is #number(multi.ops_per_second.median / reference.ops_per_second.median, digits: 2)
times the reference throughput on this host. The JSON retains every sample, additional latency
percentiles, context switches, page faults and median absolute deviations.

#let sample = report.samples.find(s => s.variant == "optimized" and s.mode == "multi")
Each mutation occupies #sample.mutation_bytes bytes and each packet #sample.packet_bytes bytes.
Reducing the initial queue from 256 to 32 avoids reserving
#number(224 * sample.packet_bytes / 1048576, digits: 2) MiB of packet storage. It can still grow under
load. Further copy reduction needs explicit durable-payload ownership.

== Design Verification and Remaining Work

The historical snapshot passed 34 SQLodin tests and 79 upstream tests in both build profiles,
contract checks and 30 fault simulations of 5,000 steps across 1, 3 and 5 nodes.
All #report.samples.len() benchmark samples verified. The next chapter adds durable-host evidence;
these memory measurements do not establish a deployed database's performance or recovery guarantees.

Reproduce with `make check`, `make bench-linux` and `make docs`.
See `benchmarks/README.md` for full methods, fault coverage and provenance.
