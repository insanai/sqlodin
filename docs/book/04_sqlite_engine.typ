#import "theme.typ": blue, gray, callout

= The SQLite State Machine Engine

== Embedded Engine Architecture

The core consensus library in SQLodin is a *pure state machine*: it performs zero I/O, issues zero
network calls, and executes zero SQLite commands internally. Instead, consensus outputs a list of
`Committed(V)` entries via the `Effects` struct.

The host application drives the database by feeding these entries into `Engine`:

```odin
Engine :: struct {
    db:              sqlite.sqlite3,
    node_id:         Node_Id,
    applied_through: Slot,
    in_memory:       bool,
    snowflake_seq:   u16,
}
```

When an engine instance is initialized via `engine_open`:
+ It opens or creates the SQLite database file.
+ In non-memory mode, it immediately enables Write-Ahead Logging:
  ```sql
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  ```
+ It queries or initializes the cluster metadata table:
  ```sql
  CREATE TABLE IF NOT EXISTS _sqlodin_meta (
      key TEXT PRIMARY KEY,
      value INTEGER
  );
  ```
+ It reads the persisted `applied_through` slot watermark from `_sqlodin_meta`. If recovering
  from a crash, the engine knows precisely which slot it has applied, and ignores redundant
  historical slots.

== Contiguous Slot Application

The database state machine requires strict linear continuity. An engine must never apply slot $S+1$
if slot $S$ is uncommitted.

In `engine_apply_slot`:
```odin
engine_apply_slot :: proc(e: ^Engine, slot: Slot, m: ^Mutation) -> Error {
    if slot <= e.applied_through {
        return .None // Idempotent skip for already-applied historical slot
    }
    if slot != e.applied_through + 1 {
        return .Log_Slot_Hole // Cannot apply out of order
    }
    // Execute SQL within an atomic transaction
    // Advance applied_through and commit
    e.applied_through = slot
    return .None
}
```

If a slot gap (`Log_Slot_Hole`) is encountered, the engine refuses application until the missing
slot is supplied by the consensus replication layer (either via peer gossip or `Learn_Message`).

== Atomic Application & Durability Barrier

Every applied slot is wrapped in an atomic SQLite transaction:
```sql
BEGIN IMMEDIATE;
<mutation SQL>;
INSERT OR REPLACE INTO _sqlodin_meta (key, value) VALUES ('applied_through', <slot>);
COMMIT;
```

If a server suffers an abrupt power failure during the execution of a mutation:
- SQLite's write-ahead log recovery rolls back uncommitted frames on restart.
- `_sqlodin_meta` reflects the last fully committed slot.
- On reboot, the engine restarts cleanly from `applied_through`, requesting missing slots from
  the surviving consensus quorum.
