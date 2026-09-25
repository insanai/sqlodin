= Reference and source map
<reference>

This chapter collects names and limits used earlier. The operating guides contain the
full command syntax. The specifications define the contracts; the evidence reports identify
which source and binary were checked.

== Native commands

#table(columns: (1.35fr, 1.65fr),
  table.header([Command], [Purpose]),
  [`sqlodin local FILE`], [Open a standalone SQLite file; bypass replication.],
  [`sqlodin connect CLIENT.json`], [Open the interactive or scriptable cluster client.],
  [`sqlodin serve NODE.json`], [Reopen and serve one durable voter.],
  [`serve NODE.json --create`], [Create new state once; refuse an existing store.],
  [`request CLIENT.json REQUEST.json`], [Send one explicit authenticated protocol request.],
  [`backup NODE.json NEW-DIR`], [Take a verified offline application backup.],
  [`verify-backup DIR`], [Check manifest, bytes and application integrity.],
  [`restore BACKUP NODE.json --new-cluster`], [Restore into a fenced fresh namespace.],
  [`migrate NODE.json NEW-DIR`], [Perform supported offline format-4 migration.],
  [`compact NODE.json`], [Perform offline certified generation compaction.],
  [`version`, `help`], [Inspect the binary and available syntax.],
)

#pagebreak()
== Interactive client

SQL ends with a semicolon. `BEGIN`, `COMMIT`, `ROLLBACK` and savepoints use the optimistic
transaction protocol. Without `BEGIN`, each write is its own replicated request.

#table(columns: (1.25fr, 1.75fr),
  table.header([Command family], [Use]),
  [`.help`], [List the supported dot commands.],
  [`.mode`, `.headers`, `.nullvalue`], [Choose presentation and null formatting.],
  [`.tables`, `.schema`, `.indexes`], [Inspect the SQL catalog.],
  [`.read`, `.output`, `.once`], [Run scripts or direct output.],
  [`.timeout`, `.consistency`], [Set request waiting and explicit read consistency.],
  [`.status`, `.nodes`], [Inspect local state and fixed membership.],
  [`.pending`, `.retry`], [Inspect or resolve the exact saved uncertain request.],
  [`.reconnect CLIENT.json`], [Change endpoint within the same cluster and identity.],
  [`.session`, `.retire-sessions E --quiesced`], [Inspect session state or explicitly advance its epoch.],
)

The shell stores pending writes durably before sending them. `--state PATH` selects its
private recovery file. Do not share that file between simultaneous shells or delete it
to escape an uncertain result. `.pending` can reveal application values.

Diagnostics name the error and suggest a correction. Data goes to stdout or the selected
output; errors go to stderr. Terminal color is disabled for redirected streams, `TERM=dumb`
or `NO_COLOR`. CSV and JSON preserve values; terminal display escapes control bytes.
The #link("../guides/cli.typ")[CLI guide] covers editing keys, scripts and output modes.

== Default service bounds

#table(columns: (1.4fr, 1.6fr),
  table.header([Resource], [Default bound]),
  [Write transaction], [8 statements; 4,096 SQL bytes; 16 parameters.],
  [Text parameter], [256 UTF-8 bytes.],
  [Vectors], [384 float32 components per request; at most 384 per vector.],
  [Read result], [4,096 rows and 256 KiB accounted storage; whole-result failure on overflow.],
  [Read work], [Approximate one-million SQLite VM instruction budget.],
  [Client request / response], [64 KiB / 1 MiB wire limit.],
  [Connections], [32 total; 24 admitted clients; peer capacity reserved.],
  [Queued output], [256 frames and at most 2 MiB per connection.],
  [Consensus window], [64 active slots, reused only after safe floor advancement.],
  [Application/journal grouping], [16 requests per application group; one journal group per service turn, flushed early at 1,024 records or effect capacity.],
  [Sessions], [65,536 rows in the current epoch; explicit replicated retirement.],
  [Maintenance], [One job; 1 MiB chunks; 32 MiB transfer buffers.],
  [Consensus history], [8 GiB cap with reserves; separate from application/staging capacity.],
)

Bounds describe the default build and admitted API. They do not bound arbitrary SQL's
wall-clock cost or the operating system's buffers and cache. Arbitrary BLOB parameters,
attached databases, extension loading, dynamic membership and rolling upgrades are outside
the supported interface. Vector BLOB results and typed vector inputs are supported.

== Terms used in the book

#table(columns: (1fr, 2fr),
  table.header([Term], [Meaning]),
  [Slot], [One position in the replicated total order.],
  [Ballot], [An ordered proposal attempt; distinct from a log slot.],
  [Chosen], [Accepted by a quorum under the protocol.],
  [Applied prefix], [The contiguous chosen history reflected in local application state.],
  [Acknowledged], [The service has verified durable choice and application of the expected request.],
  [Read frontier], [The largest highest-seen slot of a read quorum, observed after a read's invocation; the snapshot waits for it.],
  [Read marker], [A fresh ordered value used by the embedded durable host to authorize a read snapshot.],
  [Revision], [An application-state counter used for optimistic validation.],
  [Epoch], [A replicated fence that prevents reclaimed retry sessions from reviving.],
  [Generation], [A recoverable application/consensus pair selected by the root catalog.],
  [Certificate], [Distinct matching durable snapshot receipts from a quorum.],
)

== Find the implementation or argument

#table(columns: (1fr, 1.2fr, 1.35fr),
  table.header([Concern], [Source], [Argument]),
  [Consensus adapter], [`src/paxos.odin` and `deps/paxos-odin/`], [#link("../../specs/multimaster-refinement.typ")[Multi-master refinement]],
  [SQL and grouping], [`src/engine*.odin`], [#link("../../specs/sql-policy.typ")[SQL policy]; #link("../../specs/grouped-sql.typ")[grouping]],
  [Reads and transactions], [`src/durable/reads.odin`, `service/read_batch.odin`], [#link("../../specs/transaction-order.typ")[Ordering]],
  [Durable lifecycle], [`src/durable/`, `src/snapshot/`], [#link("../../specs/generation-catalog.typ")[Publication]; #link("../../specs/image-retirement.typ")[retirement]],
  [Operator recovery], [`cli/backup.odin`, `cli/restore.odin`], [#link("../../specs/recovery-bootstrap.typ")[Recovery procedures]],
  [Networking and bounds], [`service/`, `transport/mtls/`], [#link("../../specs/resource-contract.typ")[Resource contract]],
  [Application clients], [`cli/`, `languages/python/`], [#link("../guides/orm-transactions.typ")[ORM contract]],
)

The #link("../sod/index.typ")[SOD index] records design decisions. The
#link("../releases/2026-09-25.typ")[release record] records qualification and known limits.
The #link("../index.typ")[documentation index] separates current guides from historical notes.
Use those records to follow a claim to its source rather than treating the book's prose
as a substitute for executable evidence.
