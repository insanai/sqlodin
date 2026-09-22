#import "theme.typ": blue, gray, callout

= Architecture & API Reference

== Package Types & Struct Layouts

SQLodin is organized around pure, fixed-size data structures designed for mechanical sympathy and
zero runtime heap allocations.

=== MultiMaster_Node

The central consensus participant:

```odin
MultiMaster_Node :: struct(
    $Value: typeid,
    $MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
    $WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
    $CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
    $GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value)
```

=== Effects

The pure output of a single state transition:

```odin
Effects :: struct(
    $Value: typeid,
    $MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
    $WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
    $CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
    $GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
    writes:         small_array.Small_Array(2 * CHUNK_SLOTS + 1, Write(Value)),
    messages:       small_array.Small_Array(MAX_MEMBERS * CHUNK_SLOTS + 2 * MAX_MEMBERS + 1, Envelope(Value)),
    committed:      small_array.Small_Array(WINDOW_SLOTS + 1, Committed(Value)),
    writes_pending: bool,
}
```

=== Engine

The embedded SQLite state machine runtime:

```odin
Engine :: struct {
    db:              sqlite.sqlite3,
    node_id:         Node_Id,
    applied_through: Slot,
    in_memory:       bool,
    snowflake_seq:   u16,
}
```

== Core API Procedures

#table(
  columns: (180pt, 250pt),
  align: left + horizon,
  table.header([*Procedure*], [*Description*]),
  [`node_init(...) -> Error`], [Initializes a multi-master consensus participant.],
  [`propose_owned(...) -> Error`], [Fast-path 1-RTT write into the node's next owned slot.],
  [`node_step(...) -> Error`], [Evaluates one incoming wire message through the state machine.],
  [`engine_open(...) -> (Engine, Error)`], [Opens or creates local SQLite database with WAL & sqlite-vec.],
  [`engine_close(...)`], [Flushes WAL and closes database handle safely.],
  [`engine_apply_slot(...) -> Error`], [Applies committed mutation to local SQLite state machine.],
  [`engine_read_snapshot(...) -> (int, Error)`], [Executes point-in-time snapshot read with optional watermark.],
  [`snowflake_generate(...) -> u64`], [Generates conflict-free 64-bit cluster-unique key.],
  [`explain_error(err) -> string`], [Returns Elm-style diagnostics with banner and recovery hint.],
)

== Elm-Style Diagnostic Format

Every error variant in `Error` resolves to an explanatory diagnosis formatted as follows:

```
-- INVALID MEMBERSHIP ----------------------------------------------------------

A cluster membership was initialized with zero voting members or duplicate IDs.

Hint: Provide at least one valid node ID in 1..=65535 with no duplicate entries.
```
