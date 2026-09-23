#import "theme.typ": callout

= Multi-Master Writes and Keys

== Admission and Conflict Resolution

Each member can propose writes into its own slots. All replicas still apply the same global slot
order. The tests submit conflicting writes from all three masters before delivering messages and
check the final value and applied watermark on every replica. This verifies concurrent admission
in the in-process model; it does not measure parallel execution on different machines.

Structured inserts use `INSERT OR REPLACE`, updates modify the named columns, and deletes of a
missing row are no-ops. For writes to the same row, the later applied slot determines the result
subject to SQLite constraints and triggers. Replacement semantics can fire triggers or affect
foreign keys, so they are not interchangeable with every form of SQL upsert.

== Generating Unique Keys

`mutation_make_insert` takes an explicit primary key. It does not generate one. The process-local engine API is
`engine_next_id_checked`. A durable host uses `durable.next_id` to generate a Snowflake value with 42 timestamp bits, 10 node bits and
12 sequence bits. The checked API accepts node IDs 1 through 1023, advances logical milliseconds
when the sequence exhausts, and does not move its clock backward during a process lifetime.

```odin
id, err := durable.next_id(host, timestamp_ms)
// Check err before constructing a mutation with id.
mutation, err := mutation_make_insert(engine.node_id, timestamp_ms, id, "documents")
```

Disjoint bit fields make distinct in-range input tuples map to distinct keys. They do not ensure
that a host never repeats an input tuple. The host must assign unique node IDs. `durable.next_id` reserves a whole logical millisecond
(4096 IDs) in a FULL-synchronous transaction before issuing IDs. Restart discards the unused
portion and advances beyond the stored frontier. The lower-level engine generator remains
process-local. Exhaustion of the 42-bit timestamp returns an error.

The low-level `snowflake_generate` helper masks its inputs and wraps its sequence. It is an unchecked
bit packer, not the recommended generator for a long-running service. SQLite INTEGER keys are
signed 64-bit values; applications using the full unsigned key range must account for that when
sorting and exposing IDs.

== Retries and Deterministic Outcomes

A duplicate delete is harmless to row state; a duplicate insert with triggers may not be. Slot replay
is skipped using the persisted applied watermark, but the same client request chosen in a new slot
is a new application. The host must track request identity and its committed outcome when retries
or upstream resubmission are possible. Unique row keys alone do not provide exactly-once execution.
