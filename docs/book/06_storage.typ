#import "figures.typ": steps, panel
= Durable execution
<storage>

A network message can outlive the process that sent it. If a vote is sent before it
is durable, another voter may choose a value using evidence that disappears after a
crash. The recovered acceptor could then vote incompatibly. Persistence must therefore
precede visibility, not merely follow it soon afterward.

#figure(steps((
  ([Stage], [Copy protocol effects into owned pending storage.]),
  ([Commit], [Write required journal records; complete the FULL barrier.]),
  ([Release], [Expose dependent messages and advance the durable frontier.]),
)), caption: [A successful synchronization separates private work from externally usable evidence.])

== Two stores, one acknowledgement rule

Format 5 separates application data from consensus state. The application database
contains user rows, outcomes, retry fences, revision and the applied watermark. The
consensus database contains node-local promises, accepted/chosen evidence, reservations
and generation metadata. A donor's application image can be transferred; its acceptor
identity cannot be copied onto another voter.

#figure(grid(columns: 2, gutter: 10pt,
  panel([Application state], [Rows + outcomes + session fences + revision + applied prefix.]),
  panel([Local consensus state], [Promises + votes + chosen suffix + ID reservations + catalog.])),
  caption: [State transfer must preserve the recipient's acceptor facts.])

Consensus evidence is durable before dependent effects are released. Chosen application
work then commits its data and metadata atomically in SQLite. Only afterward can the
service acknowledge the matching request. These separate transactions need no distributed
transaction between the two files: ordering and replay bridge the possible crash gap.

#table(columns: (1.2fr, 1.8fr),
  table.header([Crash point], [Recovery consequence]),
  [Before durable choice], [No successful write response is justified. Retry the same identity.],
  [After choice, before application], [Replay the chosen suffix in order.],
  [After application, before reply], [The result exists; an identical retry recovers it.],
  [After reply], [Recovery must preserve the acknowledged outcome and data.],
)

SQLite uses WAL and `synchronous=FULL` for the consensus journal, catalogs, images and the
embedded engine. The separated service store treats its application database as a cache of
the journal (SOD 0005): it commits with WAL `synchronous=NORMAL`, which keeps every crash state
a committed prefix, and recovery replays the retained chosen suffix. An entry is applied only
after the journal barrier containing its decision. Required standalone files and directories
also cross explicit synchronization barriers. These rules assume
the filesystem and device honor successful synchronization. SIGKILL and injected syscall
failures test software boundaries; they are not physical power-cut certification.

#pagebreak()
== Group commits without changing meaning

A FULL commit has a cost even when the transaction is small. SQLodin can group up to
sixteen adjacent application requests in one outer transaction. A savepoint separates
each request. Its SQL either succeeds or rolls back before its outcome is recorded.

Let $R_i$ be the reference state after $i$ individually committed requests. Let $G_i$
be the private grouped state after staging the same prefix. The useful invariant is

$ G_i = R_i. $

It holds initially. At the next request, both paths inspect the same retry fence and
revision, execute the same deterministic SQL, and record the same outcome. A classified
error rolls back that request in both paths. This establishes the induction step.

Deferred foreign keys need a check at every request boundary. Otherwise a later request
could repair an earlier violation that the reference path would have rejected. SQL
`ROLLBACK` conflict actions can abort the outer transaction; the implementation discards
that unacknowledged attempt and retries through individual reference transactions.
Unknown storage or execution failures are not semantic fallback: they fail closed.

Savepoint release does not acknowledge a write. The outer commit is the publication
point for the group; its durability comes from the FULL journal barrier that preceded it.
Journal grouping combines persistence for every Paxos transition of a service turn while
preserving the same durable-before-send rule. Owned copies keep effect
payloads valid when the next protocol transition reuses its working storage.

== Why ordered SQL still needs a policy

A shared order does not make `random()` deterministic. Every voter might agree to
execute the same expression and store a different value. SQLodin therefore restricts
replicated functions, schema operations and extension behavior.

Wall-clock and random writer functions are rejected, including uses hidden in defaults.
The service owns transaction boundaries and internal metadata. Peers require matching
policy and engine fingerprints. Startup checks the pinned vector extension identity.
The qualified cluster uses matching Linux x86_64 builds; local macOS checks do not qualify
heterogeneous replication. Local read functions have a different role: their results affect future replication
only when a client submits concrete values in a write.

Policy 9 also keeps at least one hidden-rowid alias available in an ordinary rowid table.
A schema that shadows `rowid`, `_rowid_` and `oid` together is rejected; certified logical
snapshots need access to row identity. `WITHOUT ROWID` tables do not need that alias.
Schema rejection rolls back the entire request.

The deterministic-execution argument assumes identical logical state, admitted schema,
parameters, collations and pinned engine behavior. It includes planner inputs and generated
keys, not just a function allowlist. Physical-layout/cache variation tests supplement that
argument. Unknown I/O, allocation or execution failures stop acknowledgement; a local timeout
cannot invent a different replicated rejection or skip a chosen transaction.

The full #link("../../specs/sql-policy.typ")[SQL policy] and
#link("../../specs/grouped-sql.typ")[grouping argument] name the code and regressions.
