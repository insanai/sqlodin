#set document(title: "SQLodin transaction and read order",
  author: ("Vikrant Rathore", "Ronak Rathore"))
= R1.4 real-time read and transaction order

This argument assumes the agreed immutable Paxos log, durable acknowledgement
boundary, and deterministic SQL transition contract checked separately by R1/R2.
It establishes the read/transaction ordering consequence of those assumptions;
it is not a proof of the compiler, network or arbitrary SQLite execution.

== Fresh reads
`durable.begin_read` allocates a new durable marker identity after invocation.
The service may share that marker among a closed cohort of already accepted
reads; every member invocation precedes marker allocation. Later arrivals wait
for another marker, even if the preceding cohort has not returned yet.
`poll_read` checks the chosen value equals that marker and the contiguous local
application prefix includes it. A displaced proposal cannot authorize a read.
The owning host consumes the ticket once, including when the local query fails.
An acknowledged write completed before invocation already occupies an immutable
slot in the log. Quorum intersection and contiguous application ensure that a
successful fresh marker cannot bypass that write.

The serialized service owner processes no other state transition between checking
the marker and opening/executing the actual query. The read snapshot may include
later concurrent decisions already applied locally; that only moves its valid
linearization point forward within its invocation/response interval. A minority
cannot complete a new marker. Explicit local reads intentionally omit this
guarantee and are labelled as such in the API.

== Optimistic SQL and predicate reads
`transaction_result` obtains the revision after a fresh marker. Every preview
also crosses a fresh marker, opens the active generation's application database,
and checks its revision equals the transaction's original revision. The service
owner is serialized: no application commit can interleave the revision comparison
and preview snapshot acquisition. The preview replays the staged body privately,
then reads its effects, and always rolls back. No mutable preview workspace or
SQLite transaction is retained between requests.

An applied application transaction advances the global revision in the same FULL
transaction as its data and request outcome. Duplicate/rejected requests and read
markers do not advance it. Explicit session retirement also advances it. At the
ordered write slot, `engine_run_outcome` compares the original revision before
executing any SQL. If any application transition intervened, the transaction
rejects with Conflict. This conservative whole-database validation covers predicate
reads and phantoms as well as the keys a transaction eventually changes. It trades
concurrency for a simple serializability boundary; disjoint writes may conflict.

For a successful writing transaction, all preview reads therefore describe the
same committed predecessor, combined with that transaction's own staged effects.
Place it at its applied log slot. For a read-only transaction, all successful
previews use the same revision, so place it at a successful read snapshot. Its
client-side commit need not create another write. A subsequent changed-revision
read aborts the transaction. Savepoint operations only change the staged body;
release does not publish it or acknowledge a durable commit.

Consequently successful transactions admit a serial order respecting completed-
before-invoked real-time edges. Writes that overlap a read-only transaction after
its last read may follow that transaction in the serial order. Unknown commit
outcomes retain their request identity and require resolution under R1.3; they
must not be treated as either a definite abort or a new transaction.

== Executable evidence
`tools/check_transaction_history.py` records monotonic invocation/response times,
successful predicate observations before and after staged changes, conflicts,
contacted voters and restart/rejoin reads. For each bounded concurrent batch it
exhaustively searches serial executions of a separate four-row set model,
respecting every response-before-invocation edge. A final nonconcurrent predicate
read anchors the resulting state between batches. It never accepts a batch merely
because the final row count matches. Raw histories and a serial witness are saved.

Negative controls reject a stale predicate after a completed write and committed
write skew. Native checks cover each voter absent, every surviving entry point,
rejoin, full restart, and minority/stale-read rejection. Existing ORM regressions
cover savepoints, repeatable reads, disjoint-write conflicts and pending commits.
The bounded ReadFence model supplies stale-marker and early-snapshot negative
controls, with concrete host regressions. These tests supplement the argument;
a finite history search does not prove all possible executions.


The Linux reports `transaction-history-linux.json` and
`transaction-history-readonly-linux.json` each contain sixteen concurrent batches
and their serial witnesses, plus rejoin/restart reads. They pass two seeds on the
recorded disk-backed filesystem. Light local reports check four batches each.
`source-manifest-sql-contract-linux.json` identifies the native candidate and source.
Together with the existing model and native/ORM regressions, this closes R1.4;
release-candidate integration remains R7. No elapsed soak requirement is imposed.

== Closed-cohort refinement
`service/read_batch.odin` closes membership in `begin_read_cohort` on the serialized
owner, with no connection dispatch during allocation. `finish_read_cohort` consumes
the host ticket exactly once and executes each member snapshot before another
application/consensus transition. A displaced marker leaves members pending for a
fresh cohort. `release_read` removes one waiter without cancelling other members;
only the last member cancels the host wait. Connection admission bounds cohort size.
Generation publication retains the host's active ticket and applied-prefix checks.

The `ReadCohort` model checks 180,443 reachable states under the immutable-log
premises above. Three required negative controls expose late membership, reading
before marker application, and cancellation that invalidates another waiter.
`formal-read-cohort-local.json` records all four results. Concrete regressions in
`tests/test_service_read_batch.odin` require quorum, preserve another waiter after
cancellation, and require a later read following a completed write to use a newer
marker and observe that write. Cohorts change amortized barrier cost, not the
freshness contract or the durable host ticket's single-use semantics.
