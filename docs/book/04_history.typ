#import "figures.typ": slots, frontier, steps
= One ordered history
<history>

Suppose two clients update the same account through different voters. Each client
needs a definite outcome. Every voter must eventually reach the same account state.
SQLodin solves the ordering problem first, then applies that order to SQLite.

A log slot is a place in this order. Paxos chooses at most one value for each slot.
A value may contain a SQL transaction, a read marker, a skip or a host control.
SQLite applies chosen values as a contiguous prefix. Choosing slot five does not
permit applying it while slot three is unresolved.

#figure(frontier(), caption: [The applied frontier stops at two. Slots four and five
are chosen, but their effects must wait for slot three.])

Let $S_0$ be the initial logical database state and $v_s$ the value chosen for slot $s$.
A deterministic application transition $F$ defines

$ S_s = F(S_(s-1), v_s). $

If two voters start at the same state and apply the same prefix, they reach the same
state by induction. The induction is short. Its premises are substantial: agreement
must survive crashes, execution must be deterministic, and every prefix update must
be atomic. The following chapters examine those premises separately.

#pagebreak()
== What multi-master distributes

Every configured voter may admit writes. Ownership rotates by the position in the
sorted membership list:

$ "owner-index"(s) = (s-1) mod N. $

Member IDs need not be consecutive. The formula selects an index, not an arbitrary
numeric node ID. For three voters, the first six owners look like this:

#figure(slots(), caption: [Ownership partitions proposal slots. It does not partition application data.])

A healthy owner can propose at its special round-zero ballot without a preparatory
phase-one exchange. Another voter needs a higher ballot to recover that slot. Idle
owners fill needed gaps with skips; a skip advances order without changing user rows.

Every voter still applies every chosen SQL transaction. Three voters therefore do
not give three independent SQLite write engines for disjoint shards. Replication
adds durability and fault tolerance, with coordination and storage costs.

== Separate the layers

#figure(steps((
  ([paxos-odin], [Choose values. Track ballots, votes, ownership and learning.]),
  ([Durable host], [Persist protocol evidence. Order application and recovery.]),
  ([SQL service], [Authenticate, admit requests, manage deadlines and return results.]),
)), caption: [SQLodin imports the complete pinned Paxos library. It does not copy fragments into a second protocol.])

The pin is `c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c`. The adapter in
`src/paxos.odin` supplies SQLodin values and enables rotating ownership. The library
owns consensus. `src/durable/` owns its storage contract. `service/` supplies the
native network loop; `cli/` and the Python package are clients of that service.

The low-level embedded API exposes these responsibilities to its caller. Returning
from `propose` means a proposal was admitted. The caller must drive messages and
check the durable outcome. The native service performs that work before returning
successful completion to an application.
