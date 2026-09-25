#import "figures.typ": steps
= Reads, retries and serial order
<transactions>

A read can return an old but internally consistent SQLite snapshot. That is not enough
for an application that expects to observe writes completed before the read began.
SQLodin's default read path establishes a fresh ordering point before opening the snapshot.

== A quorum frontier bounds every completed write

After accepting a read, the service closes a cohort of already waiting reads. It then
observes its own highest seen slot and asks peers for theirs. Once a read quorum has
answered, including this voter, the largest reported slot $H$ is the read's frontier. The
cohort is answered when the local contiguous applied prefix reaches $H$. No application
transition slips between that check and the snapshot acquisition.

A write acknowledged before the read's invocation was chosen, so a write quorum durably
voted for its slot $s$. That quorum intersects the queried read quorum. Every voter's
highest seen slot is at least every slot for which it holds a durable vote, and it never
decreases, even across restart. Hence $H >= s$, and the snapshot includes the write. The
same argument orders reads: a read that returned a prefix $A$ only did so after every slot
up to $A$ was chosen, so a later read obtains $H >= A$. The actual snapshot may also include
later concurrent writes. That places the read later within its invocation/response interval,
which linearizability permits. The barrier writes nothing and needs no sync. This is Paxos
Quorum Reads (Charapko, Ailijiang and Demirbas, 2019), whose "rinse" phase is the wait for
the applied prefix.

#figure(steps((
  ([Accept read], [The invocation now exists; the cohort closes.]),
  ([Observe frontier], [Own highest seen slot and a read quorum of peers, all after closing.]),
  ([Read snapshot], [When applied reaches the frontier; before another owner transition.]),
)), caption: [The frontier establishes order. The SQLite snapshot supplies the rows.])

Already accepted reads share one frontier as a closed cohort. Every member must arrive
before the frontier is observed. A later read cannot join, even while the cohort waits.
Suppose a write finishes after the observation but before that later read arrives:
reusing the frontier could return a snapshot older than the completed write.

Cancelling one cohort member leaves the other members' wait intact. Cancelling the last
member retires the cohort. A reply for another cohort is ignored, and each peer counts
once. Unanswered requests are repeated every 200 ms; a minority cannot complete a frontier.
The embedded durable host keeps its single-use marker barrier (`begin_read`/`poll_read`)
for callers without a peer transport.

`consistency="local"` explicitly omits this barrier and permits stale state. `status()`
also reports only local state. Neither can establish that a quorum is available.

#pagebreak()
== An optimistic transaction validates its predecessor

Let $r$ denote the application revision. Begin obtains $r$ after a fresh read barrier. Each
preview crosses another fresh barrier, checks that the current revision is still $r$,
replays the staged body privately, reads its effects, and rolls back.

At the ordered commit slot, a writing transaction checks

$ r_("current") = r_("begin"). $

If the equality fails, it returns a conflict before executing the body. A successful
application write advances the revision atomically with data and outcome. Read barriers,
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
