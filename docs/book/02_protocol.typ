#import "theme.typ": blue, gray, callout
#import "figures.typ": rotating_slot_timeline

= The Rotating Slot Consensus Protocol

== Log Partitioning via Rotating Ownership

To allow every node to propose writes without negotiating leader leases or running Phase 1
`Prepare`/`Promise` handshakes for every transaction, SQLodin partitions the unbounded decree log
using *rotating slot ownership*.

Given a cluster of $N$ nodes with node identifiers $i in {1, 2, dots, N}$:
$ "Owner"(S) = ((S - 1) mod N) + 1 $

Every slot $S$ is pre-assigned to a unique owner:
- Node 1 owns slots $1, 1+N, 1+2N, dots$
- Node 2 owns slots $2, 2+N, 2+2N, dots$
- Node $k$ owns slots $k, k+N, k+2N, dots$

#rotating_slot_timeline()

== Healthy Slot Choice

When a client submits a write to Node $i$:
+ *Slot Allocation:* Node $i$ selects its next unallocated owned slot $S = "own\_next"$.
+ *Round 0 Ballot:* Node $i$ constructs ballot $B = "ballot\_make"(0, 0, i)$. Under SQLodin's
  protocol rules, ballot round 0 is permanently reserved for the slot's designated owner.
+ *Phase 2 Broadcast:* Because Node $i$ owns slot $S$, Phase 1 is completely bypassed. Node $i$
  durably records its own vote before it broadcasts an `Accept(S, B, V)` message directly to all peers.
+ *Quorum Acknowledgement:* When peers receive `Accept(S, B, V)` with round 0 from owner $i$,
  they verify $B >= "promised"(S)$, durably record $V$ before returning `Accepted(S, B, i)`.
+ *Local Commit:* As soon as a majority quorum of acceptances is gathered, the slot is chosen.
  Healthy slot choice uses one quorum round trip. Client success must additionally wait for
  durability and contiguous SQLite application.

#callout(title: "Direct Owner Proposals", kind: "tip")[
  Any owner proposes directly to peers without a standing-leader forwarding hop. This is a protocol
  path distinction, not a measured latency saving. Network placement, durable barriers and earlier
  undecided slots determine the observed application latency.
]

#pagebreak()
== Log Continuity and Idle Skip Ticks

State machines require *gap-free, contiguous log playback*. A database cannot apply slot $S+1$ until
slot $S$ has been decided and applied.

If Node 2 has no client traffic while Node 1 is actively processing 10,000 transactions per second,
Node 1 would propose slots $1, 4, 7, 10, dots$. However, the state machine would halt at slot 1
waiting for Node 2 to decide slot 2.

SQLodin resolves this using deterministic *Skip Mutations*:

```odin
mutation_make_skip :: proc(origin: Node_Id, ts: u64) -> Mutation {
    m: Mutation
    m.kind = .Skip
    m.origin_node = origin
    m.timestamp_ms = ts
    return m
}
```

When a node observes that peers have proposed slots far ahead of its own owned slots, during a logical tick, it automatically proposes a lightweight `Skip`
mutation through normal quorum voting into an eligible owned slot. When replicas receive and commit a `Skip`, the state machine simply
increments its applied watermark without modifying the underlying SQLite tables.

== Preemption and Phase 1 Revocation

If a node crashes or becomes partitioned, its owned slots will not advance, threatening to block the
cluster state machine.

When a live node detects that a peer's slot has stalled beyond the upstream `election_timeout_ticks`:
+ The live node campaigns to take over the stalled slot by issuing a *Phase 1 `Prepare`* with round $r > 0$.
+ Quorum members return their highest accepted vote for that slot.
+ If the stalled owner already had an accepted value $V$, the rescuer proposes $V$ in Phase 2.
+ If no value was reported accepted by the successful Phase 1 quorum, the rescuer proposes a `Skip` mutation, revoking the dead node's slot
  and allowing the cluster to advance.
