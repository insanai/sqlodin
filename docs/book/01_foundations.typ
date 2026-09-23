#import "theme.typ": blue, gray, callout
#import "figures.typ": multi_master_topology

= Foundations: Replicating SQLite

== The SQLite Concurrency Model

SQLite is an embedded relational engine. In WAL mode, readers can hold snapshots while one
writer appends to the write-ahead log. SQLite does not enable WAL by default; SQLodin explicitly
configures it for file-backed databases. Locking and checkpoint behavior still impose limits.

The WAL index coordinates processes on the same host. Replication across machines requires an
additional protocol to establish which changes belong in the database and in what order. Every
SQLodin replica still executes a serial SQLite write stream; multi-master admission does not
turn SQLite into a concurrent-writer storage engine.

== Physical Replication and Forwarding

A physical WAL replication design must preserve a compatible page history. Independently generated
page streams cannot simply be interleaved. Single-leader designs commonly route writes to the node
responsible for that history; contacting it can add latency for clients near another replica.
The cost depends on topology, network conditions and the implementation. The durable benchmark chapter records different supported interfaces; it establishes no
fixed forwarding penalty or matched network-server advantage.

#multi_master_topology()

== Logical mutations as consensus values

SQLodin supports direct owner proposals by shifting the consensus abstraction layer from *physical WAL frames*
to *deterministic logical mutations*.

Instead of replicating binary page images produced by SQLite after execution, SQLodin replicates the
*intent* of the transaction before it is committed to SQLite:

The bounded `Mutation` value carries its kind, origin, explicit key, table/column metadata and
scalar or vector values. Raw SQL occupies its own bounded field. `src/mutation.odin` defines the
actual limits; the canonical durable codec, rather than native struct bytes, defines stored data.


By decoupling consensus from SQLite's internal page structures:
+ Any node in the cluster can admit a proposal subject to capacity and health checks.
+ The node assigns the transaction to an independently owned slot in the global decree log.
+ A healthy owned slot can be chosen in one quorum round trip, plus durable vote barriers.
  Application and client completion must also wait for earlier slots.
+ Each node's local SQLite engine sequentially and deterministically applies committed mutations
  in strict log order ($S = 1, 2, 3, dots$).

Because SQLite is executing transactions locally on every node in the identical logical sequence,
each local database can converge when schema, functions and all mutations are deterministic.
Arbitrary raw SQL does not satisfy that condition automatically.
