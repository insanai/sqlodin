#import "theme.typ": blue, gray, callout

= Multi-Master Ingestion & Conflict-Free Keys

== The Primary Key Collision Problem

In a single-leader database, primary keys are typically generated via SQLite's `AUTOINCREMENT` counter.
SQLite queries its internal `sqlite_sequence` table, increments the counter, and assigns the next integer.

In a multi-master cluster where Node 1 and Node 2 simultaneously insert new rows into table `users`,
independent `AUTOINCREMENT` sequences will generate duplicate primary keys:
- Node 1 inserts user "Alice" with ID `1`.
- Node 2 inserts user "Bob" with ID `1`.

When these transactions are replicated across the cluster, the second insert will violate SQLite's
unique primary key constraint, throwing a hard constraint error and halting database replication.

== 64-bit Snowflake Identifiers

SQLodin resolves this at the protocol level by equipping each engine with a hardware-timed
*64-bit Snowflake Generator*:

```odin
snowflake_generate :: proc(node_id: Node_Id, timestamp_ms: u64, seq: ^u16) -> u64 {
    seq^ = (seq^ + 1) & 0x0FFF
    time_part := timestamp_ms & 0x3FFFFFFFFFF  // 42 bits
    node_part := u64(node_id & 0x03FF)         // 10 bits (0..1023)
    seq_part  := u64(seq^)                     // 12 bits (0..4095)
    return (time_part << 22) | (node_part << 12) | seq_part
}
```

The 64-bit integer is structured into three disjoint bitfields:
+ *Timestamp (42 bits):* Milliseconds since custom epoch. Provides 139 years of monotonically
  increasing identifiers and rough chronological sorting.
+ *Node Identifier (10 bits):* Uniquely identifies the proposing master ($0 dots 1023$). Guarantees
  that two masters can never produce the same identifier even at the identical millisecond.
+ *Per-Node Sequence (12 bits):* Rolls over from $0 dots 4095$, allowing a single node to generate
  up to 4,096,000 unique keys per second.

Every insert mutation constructed by SQLodin (`mutation_make_insert`) automatically populates the
primary key using `snowflake_generate`. Because the bitfields are mathematically disjoint, primary
key collisions across concurrent masters are mathematically impossible.

== Idempotent Deletes

In distributed systems, concurrent deletes and updates can arrive out of order depending on client
arrival times. For instance:
+ Client A deletes item with PK `1005` on Node 1.
+ Client B reads or updates item `1005` on Node 2.

To guarantee that all replicas reach identical database state regardless of local application timing,
SQLodin enforces *idempotent delete mechanics*:

```sql
DELETE FROM <table> WHERE id = <primary_key>;
```

If the row with `<primary_key>` does not exist (or has already been deleted by a prior slot), SQLite
executes the statement as a no-op, affecting 0 rows without raising an error. The slot commits,
the state machine advances, and convergence is preserved.

== Deterministic Conflict Resolution

When two masters concurrently update the same row in different slots, the final state is determined
strictly by the *total order of the consensus log*. Replicas apply slot $S_1$ followed by slot $S_2$.
The mutation in the higher slot index wins. Because all replicas apply slots in the identical sequence,
every replica holds the identical value for every column.
