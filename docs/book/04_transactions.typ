#import "theme.typ": callout

= Transactions and Retries

A lost response does not tell a client whether its write happened. Retrying an increment with a new
identity can increment twice. A stable session and sequence let any voter
can receive the retry and the ordered application can recognize it.

== Submit a complete transaction

```odin
id := sql.Request_Id{sequence = 1}
id.session = client_session // Persist this nonzero 128-bit identity.
m, err := sql.mutation_make_transaction(host.node.id, id,
    "UPDATE inventory SET available=available-?1 WHERE id=?2; " +
    "INSERT INTO reservations(quantity,item) VALUES(?1,?2);")
// Check every builder and proposal error.
err = sql.transaction_add_int(&m, 2)
err = sql.transaction_add_int(&m, 17)
slot, propose_err := durable.propose(host, m)
// Drive transport and ticks, then inspect the durable outcome.
out, complete, outcome_err := durable.outcome(host, slot, &m)
// Only complete && outcome_err == .None determines a completed result.
// out.kind == .Applied means SQL succeeded; other kinds describe rejection.
```

The body has no BEGIN/COMMIT: the host supplies the transaction. All statements share the same
bound parameter tuple. An inventory CHECK constraint can reject the update; then neither statement
takes effect. The initial API admits at most 4 KiB SQL, eight statements and sixteen parameters,
with 256 bytes per text value. It does not return SELECT result sets or provide interactive transactions.

== Outcomes survive rejection and restart

Each request commits its SQL effects, outcome, session record and applied watermark atomically.
Expected constraints and policy/syntax rejection roll back SQL, then store a durable rejection.
Application groups check deferred foreign keys at each request boundary. Savepoints isolate
rejections; a whole-group ROLLBACK falls back to individual commits before acknowledgement.
Only the outer FULL commit makes a group durable. Storage and unknown errors stop the host.

#table(columns: (1.15fr, 2.2fr),
  table.header([*Retry condition*], [*Durable behavior*]),
  [Same current sequence and content], [Return the original outcome and original slot; no SQL rerun.],
  [Same sequence, different content], [Identity conflict; no SQL effects.],
  [Older sequence], [Expired; it can never become a new execution.],
  [Sequence gap], [Consume the sequence as a rejection; lower missing requests expire.],
)

One session has one outstanding request. Advancing its sequence retires the previous result while
retaining its durable high-water mark. At most 65,536 sessions are admitted; session retirement is
not implemented. Clients must preserve identity and exact content across uncertain results.

#callout(title: "Implementation boundary", kind: "warning")[
  Function allowlisting covers direct SQL, triggers and defaults, but does not prove arbitrary SQL
  determinism. Engine builds, schemas, collations and ordering must still match. The service needs
  admission validation, deterministic resource quotas, result handling and compatibility negotiation.
]
