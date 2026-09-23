#import "theme.typ": callout

= Architecture and API Reference

== Package Boundaries

`src/paxos.odin` aliases the complete upstream protocol types and transitions. `MultiMaster_Node`
is `paxos.Node`, and `Effects` is the upstream effects type. Their capacity parameters and storage
layout are defined by the pinned dependency. SQLodin adds mutation construction and validation,
SQLite application, and its small rotating-ownership adapter.

`Engine` owns a writer connection, applied watermark statement and eight cached DML statements.
The durable host also opens a read-only connection for local queries.
Close it explicitly with `engine_close`. Borrowed mutation text/vector bindings are reset and cleared
before application returns. The version string returned by `sqlite.vec_version` is caller-owned and
must be deleted with its allocation context.

The consensus kernel uses fixed-capacity storage. SQLite and the host still allocate. The reusable
in-process host remains an embedding/benchmark fixture. The separate `service` package owns
the native mTLS event loop exposed through `sqlodin serve`.

== Public Entry Points

#table(
  columns: (1fr, 1.4fr),
  align: left + horizon,
  inset: (x: 5pt, y: 3.5pt),
  table.header([*Entry point*], [*Contract*]),
  [`durable.open`, `durable.close`], [Own a disk journal, engine and locked replica identity.],
  [`durable.propose`, `step`, `tick`], [Persist effects before application and outgoing packets.],
  [`durable.propose_batch`], [Validate up to sixteen independent proposals; slots are not acknowledgements.],
  [`durable.step_batch`], [Group up to sixteen received transitions with owned effects and FULL persistence.],
  [`durable.outcome`], [Read a durable success/rejection for the expected chosen value.],
  [`durable.acknowledged`], [Check the expected value is durably chosen and applied.],
  [`durable.next_id`], [Reserve ID blocks durably, including across clock rollback and restart.],
  [`durable.begin_read`, `poll_read`], [Wait for a fresh ordered barrier, then consume its single-use read ticket.],
  [`node_init`, `node_restore`], [Enable rotating ownership and install a no-op.],
  [`node_propose`], [Returns a proposed slot and `Consensus_Error`; proposal is not completion.],
  [`node_step`, `node_tick`], [Emit effects; the host honors durability and borrowed-value lifetimes.],
  [`engine_open`, `engine_close`], [Own one SQLite connection and its statement cache.],
  [`engine_apply_slot`, `engine_apply_batch`], [Atomically apply a contiguous decided prefix and watermark.],
  [`engine_query`, `query_result_free`], [Own bounded column names and typed values; all-or-error results.],
  [`engine_read_snapshot`], [Count read-only result rows, optionally requiring a minimum watermark.],
  [`engine_next_id_checked`], [Generate an ID within one live engine; restart frontier is a host obligation.],
  [`mutation_make_insert`], [Construct an insert from a caller-provided key.],
  [`mutation_make_transaction`], [Construct bounded SQL with durable session/sequence retry identity.],
  [`explain_error`], [Describe either a local application error or an upstream consensus error.],
)
