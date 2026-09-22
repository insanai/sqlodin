#import "theme.typ": blue, gray, callout
#import "figures.typ": multi_master_topology

= Foundations & The Replicated SQLite Problem

== The SQLite Concurrency Model

SQLite is the world's most ubiquitous embedded relational database. In its default Write-Ahead Log
(WAL) mode, SQLite achieves extraordinary single-process throughput: readers never block writers,
and writers never block readers. SQLite structures its storage as balanced B-trees over fixed-size
pages (typically 4,096 bytes).

However, SQLite's concurrency model fundamentally assumes a *single operating system boundary*.
A shared-memory POSIX lock (`wal-index`) coordinates reader and writer access:
- Multiple reader threads can concurrently scan point-in-time snapshot page frames.
- Exactly *one writer thread* is permitted to append page frames to the WAL at any given moment.

When attempting to distribute SQLite across independent machines over an asynchronous network,
this single-writer constraint presents an existential architectural dilemma.

== The Zaxonlite Architecture and the 42ms Forwarding Tax

Zaxonlite (`paxos-zig`) addressed this problem by coupling Paxos directly to SQLite's physical WAL
frames. When a client executed a write transaction on the designated leader node:
+ The leader's local SQLite engine executed the SQL statement.
+ SQLite wrote modified B-tree 4KB page frames into its local WAL file.
+ Zaxonlite intercepted these physical frames and passed them to Paxos as the replicated log value.
+ Once a majority quorum acknowledged the WAL frames, the frames were appended to follower WAL files.

While elegant in its simplicity, this physical replication model has a fatal structural limitation:
*Only the leader can accept writes.*

If two nodes concurrently execute independent SQL transactions and generate distinct 4KB WAL page
frames, those page frames cannot be merged. Replicating physical frames from two concurrent writers
would interleave partial B-tree node splits, causing instantaneous and irrecoverable database corruption.

Consequently, any write request arriving at a follower replica *must be forwarded across the network*
to the designated leader:

#multi_master_topology()

In typical multi-region cloud deployments (for example, US-East to US-West, or Europe to North America),
a round-trip network hop takes between 35ms and 45ms. In Zaxonlite benchmarks, remote writes incurred
a median *42 millisecond latency penalty* purely from this forwarding hop. In edge computing or
multi-master environments, this penalty renders the database unusable for interactive write workloads.

== The SQLodin Paradigm: Deterministic Logical Mutations

SQLodin eliminates the 42ms penalty by shifting the consensus abstraction layer from *physical WAL frames*
to *deterministic logical mutations*.

Instead of replicating binary page images produced by SQLite after execution, SQLodin replicates the
*intent* of the transaction before it is committed to SQLite:

```odin
Mutation :: struct {
    kind:         Mutation_Kind,
    origin_node:  Node_Id,
    timestamp_ms: u64,
    primary_key:  u64,
    table_name:   [MAX_TABLE_NAME_LEN]u8,
    table_len:    u8,
    col_count:    u8,
    col_names:    [MAX_MUTATION_COLS][MAX_TABLE_NAME_LEN]u8,
    col_name_lens:[MAX_MUTATION_COLS]u8,
    col_values:   [MAX_MUTATION_COLS]Column_Value,
    sql_bytes:    [MAX_SQL_LEN]u8,
    sql_len:      u16,
}
```

By decoupling consensus from SQLite's internal page structures:
+ Any node in the cluster can accept a write immediately from local clients.
+ The node assigns the transaction to an independently owned slot in the global decree log.
+ The transaction is committed across a majority quorum in *1 RTT*.
+ Each node's local SQLite engine sequentially and deterministically applies committed mutations
  in strict log order ($S = 1, 2, 3, dots$).

Because SQLite is executing transactions locally on every node in the identical logical sequence,
each local database converges to the exact same relational state without any page corruption.
