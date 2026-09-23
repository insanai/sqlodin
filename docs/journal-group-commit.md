# Journal grouping: implementation and review boundary

Vikrant Rathore, with assistance from Ronak Rathore. Updated 2026-09-23.

This implements the synchronous receiving side of SOD 0004 P2. It is enabled by default after local and Linux unit, process-crash and three-process workload
checks. Compile with `-define:SQLODIN_JOURNAL_GROUP_COMMIT=false` for the upstream `.Enforced`
reference path. The grouped build uses the complete pinned library's `.Host_Managed` integration mode. No upstream source is modified. This is not asynchronous I/O,
a network service or production qualification.

## Ordered state and ownership

`durable.step_batch` accepts at most sixteen already authenticated packets. It validates every
recipient, membership and mutation before processing any packet. The caller still owns one
serialized host: concurrent or reentrant calls are unsupported.

For each transition, the host immediately encodes all journal writes into one open SQLite
transaction. It copies every emitted value and committed value into a reusable ownership
workspace before the next upstream transition. SQLite statements are stepped and finalized while
their bindings remain valid. Pending messages retain copied payloads; their pointers are rebound
when read. Committed entries point into fixed arrays that never reallocate.

The workspace holds 256 outbound packets, 130 committed values and 80 host requests. Before another
transition, the host reserves room for the upstream per-transition maxima. If space is insufficient,
it finishes the current subgroup first. These bounds depend on the pinned library's documented
effect capacities and must be reviewed when changing that pin or host capacities.

`sequence` is the appended journal frontier. `durable_sequence` advances only after a successful
FULL commit, or from checked on-disk metadata during reopen. Each subgroup records its required
frontier. An append or commit error stops the host; it never fabricates a completed barrier.

## Refinement argument

The intended reference is the same ordered stream of upstream transitions, each persisted
individually. Grouping changes which prefixes can survive a crash, not their order or logical
records. The following construction supplies the four obligations of upstream `Host_Managed`:

1. **Persist before peer visibility.** Pending messages remain private until the complete subgroup's
   journal commit succeeds. Its required frontier must be at or below `durable_sequence`.
   `append_packet` rejects an unconfirmed frontier, and `pop` blocks while one exists. No
   pre-durable message exception is used, including round-zero owner Accept messages.
2. **Retain pending writes.** Before resetting upstream effects, each borrowed write is encoded
   into the still-open SQLite transaction. Its messages and committed values have owned copies.
   A failed subgroup poisons the host and is resolved by checked disk recovery, not by continuing
   from speculative in-memory consensus state.
3. **Durable decisions before SQL.** User SQL starts only after the group journal commit.
   Leading no-op outcomes can share that journal transaction because they have no user effects.
   Application group commit retains independent transaction outcomes and its existing
   deferred-foreign-key and whole-transaction rollback handling.
4. **Recover from the journal.** A process crash before the outer journal commit exposes the
   previous durable prefix. A crash after it retains every promised/voted/chosen record in the
   subgroup. Recovery replays the checked journal and any decided, unapplied SQL suffix.

These are implementation review arguments, not a completed machine-checked proof. Storage must
honor SQLite's FULL durability contract. Unknown commit failures remain fail-closed even if some
or all data actually reached disk. A process kill cannot establish physical power-loss behavior.

## Evidence and limits

Targeted tests check one journal barrier for sixteen consecutive decisions, recovery at the
journal/application boundaries, validation before admission, storage rejection and owned promise
payloads surviving a later vote that overwrites the upstream ledger cell. The reference build
runs the same tests with per-transition commits. Linux crash probes additionally exercise a
promise followed by fifteen votes, including before journal commit, after journal commit,
after application handling and after releasing responses. The independent-process controller
uses `step_batch` and can compile the reference path with `--individual-journal`.

This implementation does not change journal format 3 or SQL policy 4. Records remain individually
checksummed and ordered; the commit boundary groups several of them atomically. Existing format-3
voters can reopen either configuration on the same compatible SQLite build. Earlier-format
migration remains unsupported.

Outstanding P2 work includes asynchronous persistence, admission coalescing, overload/fairness
contracts, explicit completion queues, deeper storage-fault injection and formal refinement.
The broader production gates in [the implementation ledger](implementation-status.md) remain open.

The first grouped Linux snapshot passed 84 SQLodin tests, 22 crash scenarios and all nine
three-process workload/fault checks. Its reports are `benchmarks/results/linux-journal-group-*`.
A complete revalidation of the default-enabled source is recorded separately as
`linux-journal-final-*`; only completed reports count as evidence.
