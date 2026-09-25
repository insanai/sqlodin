#import "figures.typ": steps
= Reads, retries and serial order
<transactions>

A read can return an old but internally consistent SQLite snapshot. That is not enough
for an application that expects to observe writes completed before the read began.
SQLodin's default read path establishes a fresh ordering point before opening the snapshot.

== A read marker is used once

After accepting a read, the host allocates a new marker identity and proposes it through
Paxos. It verifies that the expected marker was chosen and that the local contiguous
applied prefix includes it. The service then consumes the ticket and runs the query in
the same serialized owner turn. No application transition slips between the check and
the snapshot acquisition.

A write acknowledged before the read's invocation already has an immutable chosen slot.
A fresh marker cannot authorize a snapshot that skips it. The actual snapshot may also
include later concurrent writes; that places the read later within its invocation/response
interval and is permitted by linearizability.

#figure(steps((
  ([Accept read], [The invocation now exists.]),
  ([Apply fresh marker], [Check the expected value and contiguous prefix.]),
  ([Read snapshot], [Consume the ticket; execute before another owner transition.]),
)), caption: [The marker establishes order. The SQLite snapshot supplies the rows.])

Already accepted reads can share one marker as a closed cohort. Every member must arrive
before the marker is allocated. A later read cannot join, even while the cohort waits.
Suppose a write finishes after marker creation but before that later read arrives: reusing
the marker could return a snapshot older than the completed write.

Cancelling one cohort member leaves the other members' wait intact. Cancelling the last
member cancels the host wait. A displaced proposal requires a fresh marker; finding a
different value at its proposed slot is not enough.

`consistency="local"` explicitly omits this barrier and permits stale state. `status()`
also reports only local state. Neither can establish that a quorum is available.

#pagebreak()
== An optimistic transaction validates its predecessor

Let $r$ denote the application revision. Begin obtains $r$ after a fresh marker. Each
preview obtains another fresh marker, checks that the current revision is still $r$,
replays the staged body privately, reads its effects, and rolls back.

At the ordered commit slot, a writing transaction checks

$ r_("current") = r_("begin"). $

If the equality fails, it returns a conflict before executing the body. A successful
application write advances the revision atomically with data and outcome. Read markers,
duplicate retries and rejected requests do not. Session retirement does advance it.

Thus every successful preview sees one committed predecessor plus the transaction's own
staged writes. A successful commit can be placed at its applied log slot. A read-only
transaction can be placed at one of its successful snapshots; a changed-revision read
would instead fail. This yields a serial order respecting completed-before-invoked edges,
under the consensus and deterministic-execution premises.

The validation is database-wide. It covers predicate reads and phantoms without tracking
read sets, but unrelated writes can conflict. That is a concurrency cost, not a hidden
row-level lock. No preview workspace or SQLite writer lock survives between network requests.

== A retry is a request identity

The service binds a request to the authenticated client principal, epoch, session,
sequence and content. Reusing the same identity and body returns the recorded outcome
without applying the body again. Reusing an identity with different content is an error.
Changing voter endpoints does not create a new request.

The application transaction commits its data, outcome, session fence and applied prefix
together. A lost reply leaves uncertainty at the client, but no gap between the durable
application effect and the durable fence. Retrying the original request resolves that gap
in knowledge. It does not require guessing whether the first connection reached the server.

== Reclaim sessions without reviving old writes

There are at most 65,536 session rows in the current epoch. Local eviction would be unsafe:
an old request could arrive after its fence vanished and execute again. Instead, a chosen
retirement command advances epoch $e$ to $e+1$ and deletes old session rows atomically.

Every request is checked against the current epoch before session lookup. A request from
an older epoch is expired even when its row is gone. Inductively, because the epoch never
decreases or wraps, erased requests remain fenced at every later prefix. Only one scalar
must survive, rather than one tombstone per old request.

Retirement is an operator action. Quiesce clients and resolve pending outcomes first.
Use `.retire-sessions E --quiesced` or `retire_sessions(expected_epoch=E)` deliberately.
An expired uncertain request must not be relabelled into a new epoch. Retain its identity
and reconcile the business operation. The CLI preserves its used state file's epoch;
it does not silently adopt a newer one.

The #link("../../specs/transaction-order.typ")[ordering argument] maps reads and
previews to code. The #link("../../specs/session-retirement.typ")[retirement argument]
explains the epoch invariant and its crash tests.
