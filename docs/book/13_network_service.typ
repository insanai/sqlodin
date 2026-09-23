#import "theme.typ": callout
#let local = json("../../benchmarks/results/local-orm-transactions-v2.json")
#let linux = json("../../benchmarks/results/linux-orm-transactions-v2.json")
#let cluster = json("../../benchmarks/results/linux-orm-three-host-v2.json")
#let python = json("../../benchmarks/results/local-python-api-0.3.json")
#assert(local.complete and linux.complete and cluster.complete and python.complete)

= Native SQL Service and Python

SQLodin now has a standalone Odin service. `sqlodin serve` owns the disk-backed
Paxos voter, SQLite engine, nonblocking mTLS sockets and bounded request state.
Replication flows directly between the voters; a Python coordinator is not needed.
The `sqlodin` Python package is a synchronous application client, built with uv.

== One owner for mutable state

A serialized event loop owns all durable-host and SQLite access. A fixed connection
array holds request state and bounded output rings. Explicit lifetimes separate
configuration, transient decoding, queued frames and durable mutations. The TLS
binding exposes readiness states; poll waits for useful I/O instead of dedicating a
thread to each socket. TCP_NODELAY avoids adding packet-coalescing delays to small
consensus exchanges. OpenSSL 3 provides TLS; the embedded engine does not import it.

Authentication binds an exact configured DNS SAN to a peer or SQL-client role.
Peers must agree on cluster, node identity, voter plan, protocol and engine/policy
fingerprints before replication. A SQL client cannot impersonate a voter through a
JSON field. Client session identities are namespaced by the authenticated SAN.

== A small Python interface

```python
import sqlodin

node = sqlodin.Endpoint("10.175.52.19:7600", "node1.sqlodin.test")
tls = sqlodin.TLS(ca="ca.pem", cert="app.pem", key="app.key")
with sqlodin.connect(node, cluster="orders", tls=tls) as db:
    db.execute("INSERT INTO orders VALUES (?, ?)", (42, "Ada"))
    order = db.query("SELECT * FROM orders WHERE id=?", (42,)).one()
    print(order["customer"])
```

A list of endpoints enables identity-preserving failover. `execute` returns a
durable write result; `query` returns named/indexed rows with `one`, `first` and
`scalar` helpers. Values remain bound parameters. Transaction contexts buffer a
bounded write batch and submit it atomically on successful exit. They do not hold
an interactive SQL transaction open between remote calls.

#callout(title: "An uncertain write retains its identity", kind: "warning")[
A lost response does not imply rollback. `UnknownOutcome` retains the session,
sequence and exact SQL/parameters. `resolve_pending()` retries that request;
a new write is blocked until resolution. Persisted pending requests can be restored
on a new connection. Application recovery is still needed if the client process
loses an identity before it has saved it.
]

#pagebreak()
== Evidence and limits

The book reads the following correctness results from JSON. These runs exercise the
new native service; they are not throughput comparisons and do not qualify all SQL
or failure scenarios.

#table(columns: (1.5fr, 0.45fr, 2.1fr),
  table.header([*Run*], [*Checks*], [*Scope*]),
  [Local macOS], [#local.checks.len()], [Static build; three processes; SQL, ORM and disk recovery.],
  [Linux], [#linux.checks.len()], [Static build; three processes; persistent filesystem and ORM recovery.],
  [Three Linux hosts], [#cluster.checks.len()], [Identical static executable; direct mTLS, SQL and ORM transactions.],
  [Python API], [#python.tests], [Parameters, rows, batching, retry identity, vectors and dialect contracts.],
)

Network checks cover writes through every voter, typed results, atomic constraint
rollback, read/result limits, unlisted certificates, peer/client role separation,
malformed frames, six concurrent mixed-workload sessions, durable cross-master
retries, minority refusal, explicit local reads, and all-process SIGKILL/reopen
convergence. The three Linux instances use ZFS-backed directories; physical and
storage failure-domain independence has not been established.

ORM checks add generated keys, relationships, rollback, nested savepoints, predicate
conflicts, cross-master retries, loss of the contacted voter, uncertain commits and
restart recovery. The voter-loss regression also verifies local delivery of Paxos
phase-one messages; those must cross the durable boundary just like remote messages.

The query API returns one complete bounded result or an error. It limits results to
4096 rows and a 256 KiB internal budget. Linearizable queries consume a fresh quorum
barrier before acquiring their snapshot in the same event-loop turn. Local reads
explicitly permit stale data. Transactions retain the initial 4096-byte SQL,
eight-statement, sixteen-parameter bounds and 256-byte text parameters.

#callout(title: "Production qualification remains open", kind: "warning")[
The eight-hour SSH campaign stopped after about 85 minutes on a verifier read budget;
it did not pass. Read-only post-failure audits found matching application/session
hashes and valid integrity across the three instances. Its frozen implementation
also cannot certify this new network service. Native-service soak tests, audited histories, write CPU
quotas, snapshot/trimming, session retirement, certificate lifecycle and safe live
voter changes remain open. Multi-master permits writes at any voter; it does not
establish comparative performance or independently shard writes.
]

A fresh native-service eight-hour campaign started on 23 September at 02:04 UTC,
with the workload scheduled to end at 10:04 UTC. It is recorded as in progress;
its final status must be read from `docs/cluster-qualification.md` and the run JSON.

The longer soak and separate-machine requirements are SQLodin-specific release goals, not a
universal database-readiness threshold. An unrun gate is missing qualification evidence; it does
not by itself demonstrate a defect. Implemented guarantees and known limitations are assessed
separately from pending tests.

Operational configuration and the protocol are in `docs/network-service.md`.
The Python API, installation and recovery examples are in
`languages/python/README.md`. Incus-style enrollment is a separate operator workflow;
issuing a certificate must never silently alter the consensus voter set.
