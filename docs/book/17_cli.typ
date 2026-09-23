#import "theme.typ": callout
#let evidence = json("../../benchmarks/results/cli-validation.json")
#assert(evidence.complete)
#pagebreak()
= A Command Line for SQL and Clusters

The `sqlodin` executable now serves three roles: a standalone SQLite shell, an
interactive authenticated cluster client, and the native SQL service. Local and
cluster commands share the executable; their persistence contracts remain explicit.

```sh
sqlodin local notes.db
sqlodin connect client.json
sqlodin connect client.json --mode json -c 'SELECT id, name FROM customer LIMIT 20;'
sqlodin connect client.json --bail -f migration.sql
sqlodin serve node.json
```

== Local files and cluster SQL

`local` embeds the pinned SQLite 3.51.3 shell with FTS5 and sqlite-vec. It supports
the build's SQLite dot-commands, including schema inspection, CSV import, SQL dumps,
backup/restore and output modes. No installed `sqlite3` program or shared database
library is required. Dynamic extension loading remains disabled. `sqlodin sql` is
an alias, and invoking `sqlodin` without arguments opens the local in-memory shell.

`connect` uses mutual TLS, verifies the server identity and cluster, and defaults
to quorum-fenced reads. The Odin editor provides cursor editing, bounded in-memory
history and unique-prefix completion. SQL may span lines and trigger bodies;
SQLite's completeness checker recognizes quoted semicolons and comments. Scripts
and repeated `-c`/`-f` arguments execute in order, with nonzero exit status on error.

#table(columns: (1.05fr, 2fr),
  table.header([*Task*], [*Cluster commands*]),
  [Explore], [`.tables`, `.schema`, `.indexes`, `.limits`],
  [Inspect], [`.connection`, `.nodes`, `.status`, `.health`],
  [Recover], [`.pending`, `.retry`, `.reconnect CLIENT.json`],
  [Render], [`.mode`, `.headers`, `.separator`, `.nullvalue`],
  [Automate], [`.read`, `.output`, `.once`, `.bail`, `.parameter`],
)

Column output uses aligned headings; CSV and JSON remain usable by programs.
JSON preserves signed 64-bit integers and nulls and encodes BLOBs as base64 objects.
Error diagnostics go to stderr. ANSI styling uses Odin's terminal package and is
disabled for redirected streams, `TERM=dumb` or `NO_COLOR`.

#callout(title: "A diagnostic must explain the next step", kind: "note")[
A cluster transaction conflict is reported as *TRANSACTION CONFLICT*, with the
script location and a hint to repeat the entire transaction against the new
revision. Constraint errors point to `.schema`; result-limit errors suggest
indexed predicates, fewer columns or pagination. An uncertain write directs the
operator to preserve client state and use `.retry` with the same identity.
]

#callout(title: "Local mode does not participate in consensus", kind: "warning")[
Do not modify an active voter's database through the local shell. A standalone
SQLite backup does not capture the cluster's Paxos journal and durable session
outcomes. Cluster-wide backup/restore and online membership changes remain separate,
unimplemented protocols; file commands cannot substitute for them.
]

#pagebreak()
== Transactions and durable client recovery

```sql
BEGIN;
UPDATE account SET balance=balance-10 WHERE id=1;
SAVEPOINT credit;
UPDATE account SET balance=balance+10 WHERE id=2;
SELECT id, balance FROM account WHERE id IN (1,2);
RELEASE credit;
COMMIT;
```

Cluster transactions use bounded optimistic serializable previews. Staged writes
are rolled back in each private preview; reads can observe that staged body.
`COMMIT` proposes the complete body with its original revision guard. A conflict
requires replaying the whole transaction. `ROLLBACK TO` restores a saved staged
body; full rollback or exit discards the transaction. These operations do not hold
a SQLite writer lock across a human editing session.

The service's existing limits still apply: 4,096 SQL bytes per request or transaction,
eight writes, 4,096 result rows and 256 KiB of result storage. A script is not
implicitly one atomic transaction. The shell first tries a read-only query and
routes an `Invalid_SQL` result to the durable write path; explicit execute/query
benchmark clients avoid that additional probe. The CLI is an operator interface,
not the throughput benchmark adapter.

Before a write is sent, the shell commits its exact SQL, session and sequence to a
private local recovery database using SQLite FULL synchronization. By default this
is `CLIENT.json.shell.db`; `--state` chooses another path. An advisory lock prevents
concurrent shells from sharing the state. The client stores the loaded certificate's
fingerprint and keeps the TLS context stable during the connection.

If a reply is lost, the write may already have committed. Further writes are
blocked, and the process exits with status 2 while an outcome is unresolved.
Reopen the same state, restore connectivity and issue `.retry`. An operator may
use `.reconnect` to contact another voter in the same cluster with the same client
certificate. The recovered request retains its exact identity and revision guard.
Deleting the state or issuing the SQL under a new identity would defeat this protection.

#callout(title: "Observe membership without changing it", kind: "note")[
`.nodes` lists configured voter addresses and identities. `.status` reports the
contacted node's local applied slot. Neither proves quorum reachability. `.health`
performs a fresh fenced read. None of these commands adds a voter or changes the
fixed configuration; certificate enrollment and consensus membership remain separate.
]

The integration suite exercises local file operations, SQL and savepoints, typed
output, terminal colors and editing, state locking, revision conflicts and
all-voter restart. Its lost-response fixture forwards a write to the real service,
receives the committed response, then closes the client connection without delivering
it. A fresh CLI process retries the saved request and verifies a single application.

Run `python3 tools/check_cli.py --binary bin/sqlodin --server bin/sqlodin` for the
executable-level checks. Saved local/Linux results and the full command reference
are described in `docs/cli.md`. The ongoing eight-hour soak uses its original binary;
new CLI tests do not retroactively qualify that implementation or complete the soak.


#table(columns: (1.4fr, 1fr, 1fr),
  table.header([*Test platform*], [*CLI checks*], [*Service checks*]),
  ..evidence.platforms.map(p => (p.platform, str(p.cli_checks), str(p.service_checks))).flatten(),
)

These are matched optimized client/server binaries. The JSON evidence manifest
links each result to its binary and static dependency hashes.
