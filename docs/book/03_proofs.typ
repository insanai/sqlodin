#import "theme.typ": callout

= Safety Argument and Host Obligations

This chapter is an implementation review and proof sketch. It is not a machine-checked proof of
SQLodin, SQLite, the network host, or crash recovery. The executable evidence is the pinned upstream
suite, SQLodin integration tests and seeded fault simulations described in the benchmark chapter.

== Agreement per Slot

Membership has a stable sorted order. Slot $s$ belongs to member at index $(s-1) mod N$; member IDs
need not be consecutive. Only that owner may propose at round zero in that slot. This is an explicit
acceptor check in upstream `on_accept`, not a consequence of unique ballot integers alone. An
acceptor rejects conflicting values at the same ballot, and rejects ballots below its global or
per-slot promise. The owner must never reuse a slot and ballot for another value after a restart.

When another node recovers a stalled range, it runs Phase 1 at a higher ballot. Intersecting quorums
and selection of the highest accepted vote preserve any previously chosen value. This argument
requires that promises and votes survive crashes. Merely sending acknowledgements before a durable
barrier invalidates the argument. Authentic membership and non-Byzantine peers are also assumptions.

SQLodin imports the whole pinned `paxos-odin` package. Its adapter enables rotating ownership on
initialization and restore, and supplies the deterministic no-op. It does not maintain a second copy
of the consensus algorithm.

== Convergence after Application

Agreement supplies at most one value for each decided slot. It does not guarantee that every slot
will eventually decide under arbitrary message loss. For a contiguous decided prefix, replicas
starting from identical state converge if they apply identical deterministic mutations in slot order.
`engine_apply_batch` checks continuity, applies mutations and stores the applied watermark in one
SQLite transaction. Failure rolls back the whole batch and leaves the watermark unchanged.

The legacy engine batch path stops on a decided SQL error. Format 2's durable host instead records
expected SQL rejections with its watermark and session fence. Unknown/storage errors remain fatal.
These outcomes still require deterministic execution; total ordering alone is insufficient.

== Progress and Latency

Idle owners fill gaps with no-ops. Live peers can recover an unavailable owner's range using a
higher ballot, while retransmission and range learning repair loss. Progress still needs a reachable
quorum, eventual message delivery, fair scheduling and an eventually successful recovery proposer.
A minority partition cannot independently commit writes.

Healthy slot choice can use one quorum round trip, plus durable vote barriers. Client completion
also depends on earlier slots being decided and on SQLite application. Skewed traffic, slow owners
and recovery can therefore delay every replica's applied prefix. Multi-master admission does not
remove this ordering dependency and does not imply a throughput multiplier.

== Durability, Retry and History Contracts

#callout(title: "The supplied in-process harness is not a durable database service", kind: "warning")[
  The historical memory benchmark host uses `Host_Managed` effects with memory-only databases and no consensus
  journal. The fault simulator has a separate in-memory durable-state model. Neither establishes
  power-loss safety, filesystem correctness, a wire protocol or a production recovery service.
]

The separate `src/durable` host uses checked durable frontiers and a checked disk journal; the
per-transition reference also retains upstream's enforced gate. Its process-crash
tests extend the tested boundary; they do not certify physical power-loss behavior.

A durable host must persist the required Paxos effects before releasing dependent messages or
committed entries, retain accepted/chosen payloads, restore the ledger correctly, and serve history
or snapshots after trimming. Borrowed values in effects must be consumed or copied before another
transition overwrites their storage. SQLodin's packet queue snapshots them for that reason.

The integration harness advances its memory floor only through the minimum applied prefix across
all replicas. The simulator additionally keeps each replica's own applied history and serves range
requests from that history. Its canonical decision oracle is used only to check agreement.

Owner revocation may resubmit a value in another slot. A proposal's initial slot is therefore not a
client completion token until the host observes its committed outcome. Durable request IDs and
application-level deduplication are needed for retry safety. Format-2 transaction requests supply
these with bounded session sequences; raw/structured mutations and the volatile examples do not.

== Data Layout and Complexity

The upstream ledger uses fixed-capacity slot arrays; SQLodin's bounded mutation values keep vector
storage shared across columns. This avoids reserving a full embedding for every scalar column, but
small writes still copy a fixed-size mutation through the protocol. The benchmark records that size.
SQLite, statement preparation and the host packet queue still allocate memory.

Slot lookup is constant-time. Protocol work depends on membership, recovery range and effect
capacity; exact instruction counts depend on generated code and hardware. Exact vector scanning
cost also depends on the number of candidate vectors as well as their dimensions. No constant-cycle
or universally optimal CPU/memory claim is made.
