# Production-readiness review — 2026-09-22


**2026-09-23 update:** This is the earlier production-readiness review. The native mTLS
SQL service, typed results, fresh read barriers and Python client have since been
implemented and tested locally and across three Linux instances. See
[the current service contract](network-service.md) and [implementation status](implementation-status.md).
Python 0.3 adds bounded serializable ORM transactions, rollback and savepoints;
the current durable compatibility boundary is format 4 / SQL policy 6. See
[the ORM contract](orm-transactions.md) for limits and recovery behavior.
The remaining retention, membership, determinism/resource and qualification gates
still prevent a production-ready claim.

**Decision: SQLodin is not production-ready as a general-purpose distributed SQL database.**
It is a durable, fixed-membership embedding library with tested consensus/recovery paths. The
current implementation and workload evidence do not establish safe, high-volume continuous service.

## SQLodin qualification goals

The endurance and separate-machine requirements are SQLodin-specific release goals
adopted in SOD 0004, not a universal threshold for every database. An unrun gate
is missing qualification evidence; it is not by itself a demonstrated defect.
Assess implemented guarantees and known limitations separately from pending tests.

## Implementation update

The SOD implementation now records success, expected constraint failures, policy rejection and
prepare-time syntax/schema errors as durable outcomes. Deferred foreign-key failures and
ROLLBACK conflict actions are isolated per request. Stable session/sequence IDs and canonical
content hashes prevent duplicate effects on retries, including through another voter and after restart.
The durable host blocks nondeterministic functions, including defaults omitted by SQLite's authorizer,
and rejects maximum rowid writes that could enable random rowid allocation.

Upstream proposal batches, application groups, packed journals and ordered read barriers are
implemented. Incoming-transition journal groups now use owned effects and a checked durable
frontier; the enforced per-transition configuration remains a reference build. These are partial
P1/P2 deliveries. Asynchronous persistence, compact in-memory values and the production service remain open.
See [the implementation ledger](implementation-status.md) for exact API, limits, evidence and gaps.
Format 3 / policy 4 rejects earlier databases and engine fingerprints; no automatic or rolling migration is implemented.

The specific uniqueness/restart and random-function failures below have regression fixes. The
broader deterministic SQL contract, resource quotas, network/read guarantees and storage lifecycle
are still release blockers. **Do not interpret the historical findings below as the current behavior
of fixed regression cases, or interpret those fixes as completed production qualification.**

## Findings in the pre-SOD implementation

1. **P1 — Ordinary SQL rejection can stop the host and prevent reopening.**
   `src/durable/host.odin:135` persists a chosen decision before application; any application error
   poisons the host. `src/durable/journal.odin:106` retries that decision during recovery and fails
   opening if it still fails. A local optimized-build probe created an accounts table with a unique
   email, successfully inserted one row, and proposed another row with the same email. It returned
   `Storage` at slot 3, left the applied watermark at 2, rejected a subsequent valid write with
   `Poisoned`, and returned `Storage` on reopen. This preserves the chosen log instead of silently
   skipping it, but it is not a usable production transaction-rejection policy. Concurrent clients
   can encounter constraints even if each request appeared valid before consensus. A fix needs
   deterministic replicated success/rejection outcomes; storage failures must remain fatal.

2. **P1 — SQL determinism is a caller promise, not an enforced database guarantee.**
   `src/mutation.odin:224` validates raw SQL length and NULs, not its semantics. The SQL authorizer
   protects transaction boundaries and internal metadata but permits nondeterministic functions.
   Replicating `INSERT ... random()` orders identical SQL text, not identical resulting values.
   An optimized three-node probe confirmed different stored values at all three replicas with the
   same applied watermark of 2. Paxos agreed on the raw SQL payload; its execution violated the
   documented caller determinism contract, which the API does not enforce.
   Trusted callers must materialize nondeterministic inputs before proposing and control schemas,
   triggers, collations and functions. A general SQL service needs an enforceable execution contract.

3. **P1 — Long-running storage and recovery lifecycle is incomplete.**
   Format 1 retains every promise/vote/decision. Startup scans the journal and checks chosen
   evidence for each applied slot (`src/durable/journal.odin:70` and `:106`). The in-memory window
   advances, but disk history does not compact. Certified snapshots, lost-disk replacement,
   safe backup restore/rejoin and membership changes are absent. Continuous ingestion grows
   storage and recovery work; the current implementation cannot reclaim old history safely.

4. **P1 — Client and operational contracts remain outside this repository.**
   There is no production network server, authenticated cluster transport, distributed read fence,
   or durable client-request deduplication. Retrying an uncertain non-idempotent operation can
   apply it again in another slot. Host access must be serialized; callers must supply transport,
   scheduling, admission control, deadlines and overload handling. These requirements are documented
   in `docs/durability.md`; passing the core tests does not supply them.

5. **P2 — Sustained-load and overload behavior are not established.**
   The durable host fixes membership capacity at 5 and the active window at 64 slots. It checks
   outgoing queue backpressure before transitions at 1,024 packets. The public `propose` wrapper
   folds upstream proposal errors, including window exhaustion, into `Consensus`; a service needs
   to distinguish retryable saturation from other failures. There is no public durable batch/group
   commit API. Existing throughput measurements use a sequential caller and in-process transport.

## What multi-master guarantees within the host contract

Every configured voting node can propose into its owned slots without forwarding to a permanent
leader. An acknowledgement requires the expected mutation to be durably chosen and applied;
returning a proposal slot is not an acknowledgement. A reachable quorum is still necessary: for
three voters, a minority of one cannot confirm new writes independently.

All replicas apply the same global ordered stream. Multi-master distributes proposal admission;
it does not shard SQL execution or multiply SQLite write capacity by the node count. Earlier
undecided slots can delay later application, and uneven admission requires skip/recovery work.
The 64-slot active window is reused, so it is not a 64-write lifetime limit. Progress under a stream
requires processing packets/ticks and respecting admission limits, with sufficient disk capacity.

Large request size is separately constrained: SQL is at most 4,096 bytes in format 2; structured mutations
have at most 16 columns and 256 text bytes per value, with a shared 384-float vector budget by
default. There is no general large-BLOB ingestion API.

## Historical evidence reviewed

- Fresh local optimized run: all 43 SQLodin tests passed. This includes durable multi-master
  admission, restart, retained-history catch-up and injected storage-failure tests.
- Existing Linux verification: 43 SQLodin and 79 upstream tests in both profiles, 150,000 modeled
  fault steps, and five process-crash scenarios. These are not physical power-cut certification.
- Existing durable Linux write measurement: three repetitions, each 1,200 timed 256-byte writes
  after 240 warmup writes, about 54 seconds per timed repetition. Median: 22.18 writes/s across
  three embedded hosts in one process. This is neither a maximum-capacity measurement nor an
  hours/days-long soak test or a multi-machine network benchmark.
- Benchmark source hashes and data remain unchanged in `benchmarks/results/linux-realworld.json`.
  This review does not change the persistence contract or relabel measurements as production proof.

## Work needed before a production decision

Complete the P1 deterministic SQL, admission, compatibility and bounded-execution contract. Then add
certified snapshot/restore/replacement procedures, transport and distributed read guarantees,
and explicit overload/deadline handling. Validate the resulting service against a stated target
write rate, payload distribution and latency/recovery limits. Run long-duration growing-dataset
loads with skewed and simultaneous writers, slow replicas/disks, partitions, crashes, disk-full
conditions, snapshot catch-up and backup/restore exercises. Demonstrate bounded resource behavior
and preserved acknowledged data before making a production-readiness claim.
