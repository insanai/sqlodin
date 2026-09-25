# sqlodin

Multi-master SQLite application layer in Odin, using the complete
[paxos-odin](https://github.com/insanai/paxos-odin) consensus library.

The upstream Git submodule is pinned to
`c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c` (published on the upstream `sqlodin/bounded-ownership-progress` branch).
SQLodin's adapter enables rotating ownership; it does not implement a separate Paxos algorithm.

Every member can propose into its own slots without forwarding to a standing leader.
A healthy owner's consensus fast path takes one quorum round trip. Client-visible application
also waits for earlier slots, durability, and SQLite execution. This is **not a guaranteed
one-RTT transaction latency**, and no fixed WAN latency saving has been measured.

[Documentation](docs/index.typ): usage guides, the book, design decisions, release evidence and historical records.

## Command-line SQL

```sh
sqlodin local notes.db
sqlodin connect client.json
sqlodin connect client.json --mode json -c 'SELECT id, name FROM customer LIMIT 20;'
```

The [CLI guide](docs/guides/cli.typ) covers the bundled local SQLite shell and the native
cluster client: interactive editing, scripts, transactions/savepoints, result
formats, catalog and cluster commands, and durable recovery of uncertain writes.
Diagnostics include correction hints and terminal-aware ANSI styling.

## Status

SQLodin provides an embedded library, standalone mTLS SQL service and CLI, and a
[uv-managed Python package](languages/python/README.md) with FTS/vector search and
SQLAlchemy transactions, rollback and savepoints. **Qualified for the fixed three-voter production scope described below.**

Implemented storage paths include FULL-durable consensus and application stores,
fresh quorum-backed reads, durable request retries, certified snapshots, bounded
history, snapshot catch-up, backup/restore and fenced replacement. The qualified
cluster scope is three fixed voters accepting requests at every member.

The [fixed release checklist](docs/releases/2026-09-25.typ) is the authoritative completion
contract and evidence record. All 23 criteria are closed for the identified candidate,
with the owner's explicit performance and capacity dispositions. The original throughput
and p99 targets remain unmet improvement goals. Large-capacity testing is not a release
requirement; retained large-store startup samples took 114–137 seconds against the
original 60-second goal, so no general large-database recovery SLA is claimed.
Historical reviews and soak records are supporting evidence, not additional gates.
See the [native service contract](docs/guides/network-service.typ) and
[SQL/durability contract](specs/sql-policy.typ) for supported APIs and deployment limits.

- The full upstream library provides ownership, quorum skips, recovery, retransmission, replay,
  bounded windows, learners and reconfiguration. SQLodin's convenience initializer selects
  fixed-membership rotating ownership; advanced upstream APIs remain available via a direct import.
- Structured inserts, updates, deletes, text and vector bindings apply in log order. Inserts use
  `INSERT OR REPLACE`; this is an explicit overwrite policy, not conflict detection.
- `engine_apply_batch` applies a contiguous prefix and its `_sqlodin_state.applied` watermark
  atomically. Failed begin, SQL, or commit rolls back and leaves the watermark unchanged.
- Embedded engine databases use WAL with `synchronous=FULL`. The applied watermark survives reopening.
  The service's separated store keeps its consensus journal FULL and commits its application
  database with WAL NORMAL as a replayable cache of that journal ([SOD 0005](docs/sod/records/0005-durable-turn-and-fast-skip-learning.typ)).
- Eight cached prepared DML statements per engine reduce repeated prepare/finalize work.
  Text/vector bindings borrow mutation storage only until execution and binding cleanup finish.
- Consensus transitions allocate no heap memory. SQLite and host queues do allocate.
  Mutation payloads are fixed capacity: 16 columns, 256 text bytes per column, 4,096 SQL bytes,
  and a **shared 384-float vector budget** by default. Use
  `-define:SQLODIN_MAX_MUTATION_VEC_VALUES=N` for multiple embeddings totaling more than 384 floats.
  One vector still has at most 384 dimensions.
- `engine_next_id_checked` handles sequence overflow and clock rollback with logical milliseconds,
  and rejects node IDs outside 1..1023. Use `durable.next_id` to reserve IDs durably across restarts. `snowflake_generate` is only an unchecked low-level bit packer.
- FTS5 and sqlite-vec support bounded network search: atomic document updates,
  exact vector scans and single-snapshot hybrid retrieval.

Schemas, collations, engine builds and SQL behavior must be deterministic and identical across
replicas. The durable host enforces a function allowlist, blocks transaction escape and protects
internal metadata. This is not a complete arbitrary-SQL determinism validator. Expected constraint,
policy and prepare-time syntax/schema rejections become durable outcomes; storage errors remain fatal.
Use `mutation_make_transaction` with a stable session/sequence for retry deduplication. Legacy raw
SQL and structured mutations have no request identity and can execute again in another slot.

Serialize access to each node, effects batch and engine. Persist effects before releasing messages
or committed entries, and copy borrowed payloads before another transition or window reuse.
Advance the memory floor only after durable application and arranging historical catch-up service.
`engine_read_snapshot` returns the **number of result rows**, not a scalar aggregate; a watermark
read supplies read-your-writes only when the caller carries the confirmed applied write's slot.
It is not a quorum/linearizable read API.

## Build and verify

Requires Odin `dev-2026-09` or newer, Python 3, a C compiler, `ar`, Make and Perl.
The macOS/Linux build downloads and verifies pinned SQLite 3.51.3 (FTS5 enabled),
sqlite-vec 0.1.9 and OpenSSL 3.5.8, then links their static archives. The resulting
CLI has no shared SQLite, sqlite-vec or OpenSSL dependency. Normal OS runtime libraries
remain. Typst is only needed for docs. See [self-contained builds](docs/guides/building.typ).

```sh
git clone --recurse-submodules https://github.com/insanai/sqlodin.git
cd sqlodin
# Existing checkout:
make deps
./build.sh
make test
make vet
make check
make example
make bench
```

`make deps` installs the committed submodule revision; it never tracks a moving branch.
Direct `odin` commands work after initialization, without a sibling checkout or collection flags.
`make check` verifies the clean pin, tests SQLodin and the whole upstream library in debug and
optimized builds, checks capacity/durability contracts, runs seeded drop/reorder/duplicate/restart
simulations on 1/3/5 nodes, and validates the example and benchmark. On Linux it also runs actual
SIGKILL/restart checks against the durable host. Simulator journals remain modeled in memory;
process-crash tests do not certify physical power-loss behavior.

## Performance and memory

[SOD 0005](docs/sod/records/0005-durable-turn-and-fast-skip-learning.typ) removed most sequential
sync barriers from the durable service path. Its changes are:

- one journal barrier per service turn;
- Mencius-style owner no-op learning, and learning a value this voter also voted for, with three voters;
- a WAL NORMAL application cache of the FULL journal;
- quorum-frontier fresh reads.

On `.18`, with SQLite measured in the same runs, the calibration matrix moved from 1.7–10.5% to
6.8–40.6% of SQLite; the absolute gain is 1.9–10.5×. On three separate hosts, 32-client pure writes
rose from 95 to 784 per second (medians), and a sequential fresh read fell from 44.6 to 0.51 ms. These gains
post-date the qualified 25 September candidate, which the release record still describes. The 1,000
pure-write/s and 25%-of-SQLite goals remain unmet at 32 clients. Reports and failed attempts are in
[`benchmarks/results/sod-0005/`](benchmarks/results/sod-0005/).


The historical memory suite compares rotating ownership, single-leader operation and the local SQLite application
engine. It records seven repetitions per build/workload, verified replica contents, warmup, throughput,
batch latency percentiles, per-process CPU and peak RSS. Source/binary hashes, compiler flags and
hardware metadata travel with the raw samples in [the result JSON](benchmarks/results/linux-latest.json).
The [book evaluation chapter](docs/book/11_benchmarks.typ) separates these historical results
from later native, durable measurements.

```sh
make check
make bench-linux
make docs
```

All replication is in-process and single-threaded. The suite excludes sockets, serialization, consensus
journaling/fsync and WAN/client-forwarding latency. It includes sequential and twelve-proposal pipeline
cases, with both integer-only and 256-byte text rows. See [method and reproduction](benchmarks/README.md).
The older `make bench` output and one-row search fixtures are smoke examples.

The optimized DML cache compares bounded table/column metadata without formatting SQL on hits.
The FIFO starts at 32 packets and grows when necessary. The runner keeps the earlier lookup and
256-packet reservation as comparison builds so both changes can be measured separately.

The previous published ~762k writes/sec and fixed ~42ms saving are withdrawn: failed proposals
were counted, commit messages were mishandled, and writes were not applied to SQLite. The new native service has
not yet had a matched comparative performance run, so **superiority to Zaxonlite is unproven**.

A separate [durable Linux workload report](benchmarks/results/linux-realworld.json) compares the
supported workloads of SQLodin, Zaxonlite, rqlite and cowsql. SQLodin uses three disk-backed embedded
hosts; Zaxonlite and rqlite use network servers; the stock cowsql demo uses persisted Raft with an
in-memory SQLite image. The [book evaluation chapter](docs/book/11_benchmarks.typ) keeps these execution boundaries explicit. See [reproduction](benchmarks/README.md).
Zaxonlite uses its official v0.7.0 Linux binary, verified against published checksums.

```sh
# Linux only, after native dependencies and verification:
python3 tools/setup_comparison.py
python3 tools/fetch_zaxon_release.py
make check-durability
make bench-durable-linux
make docs
```

In the historical benchmark snapshot the mutation occupied **7,800 bytes**, down from 30,840 bytes.
With the same upstream node capacities (`members=3, window=64, chunk=16`), that reduces node storage
from 3,026,488 to 768,568 bytes. Default window=256/chunk=64 occupies about 3 MB per node, before
SQLite, transport, journal and application storage. Format 2 enlarges the request for 4 KiB SQL and
retry identity; these historical sizes are not current layout claims. Compact payload work remains
open. Fixed capacity is bounded memory, not zero cost.
The current arm64 layout is 11,416 bytes per mutation and 11,488 bytes per packet. The larger SQL
limit therefore has a measurable memory/copy cost; it is not itself a performance optimization.

See [the design discussion and measurements](docs/sod/records/0004-production-sql-and-durable-throughput.typ) for findings, limitations and
benchmark interpretation. [SOD 0002](docs/sod/records/0002-sqlodin-architecture.typ)
records the accepted integration and application architecture.

## Layout

- `deps/paxos-odin/`: complete, pinned upstream repository and tests.
- `src/paxos.odin`: protocol aliases and rotating-ownership initialization/recovery adapters.
- `src/durable/`: checked disk journal, restart replay, historical range service and durable IDs.
- `src/engine*.odin`, `src/mutation.odin`: SQLite application layer and bounded values.
- `internal/inmemory/`: shared example/test/benchmark transport with copied payloads.
- `tests/`, `sim/`, `bench/`, `examples/`: verification and measured workloads.
- `docs/`: design documents; historical protocol discussions describe assumptions, not deployment evidence.

Authored by Vikrant Rathore, with assistance from Ronak Rathore. MIT license; see [LICENSE](LICENSE).
The upstream library's license is retained in its submodule.

## Book and design records

The [book source](docs/book.typ) develops usage, ordered replication, durability, formal
verification and operating procedures, followed by measured performance and a reference chapter. `make docs` builds the book, SOD index, numbered bundle and every standalone record into
`docs/build/`; build errors fail the command. All PDFs use the same portable Typst typography.

The [SOD 0004: Production SQL and Durable Throughput](docs/sod/records/0004-production-sql-and-durable-throughput.typ) defines
the accepted mixed-transaction, batching and recovery design. Correctness qualification is
complete for the declared fixed-voter scope; unmet performance targets remain improvement goals. The [historical Linux cost profile](benchmarks/results/linux-durability-cost.json)
attributes durable write costs without weakening synchronization. The
[format-2 batch profile](benchmarks/results/linux-production-p1-batches.json) measures the initial
transaction implementation separately; these are historical measurements. The current release
decision and approved scope are in the [release record](docs/releases/2026-09-25.typ).


The historical format-3 candidate added bounded application groups, packed durable records and ordered read
barriers. Its [Linux cost profile](benchmarks/results/linux-candidate-v3-cost.json) and
[three-process disk campaign](benchmarks/results/linux-candidate-v3-process-2400-v2.json) remain in the historical evidence archive. The latter uses one Linux machine with three independent data directories, fenced
reads and nine workload/fault checks. Neither report is a production-readiness certification;
see the [release record](docs/releases/2026-09-25.typ) for the current qualified candidate.


Incoming-transition journal grouping is now enabled, with an enforced per-transition reference
configuration retained. The [journal-group review](docs/sod/records/0004-production-sql-and-durable-throughput.typ) describes owned
effects and durability ordering. The [matched Linux process comparison](benchmarks/results/linux-journal-matched-process.json)
measures the two configurations over three repetitions each; all six samples passed their fault
checks. These historical reports are retained separately from the final source-bound release evidence.
