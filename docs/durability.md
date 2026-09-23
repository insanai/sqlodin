# Durable host contract

Import `src/durable` for disk-backed operation. Importing `src` and calling protocol transitions directly still requires a host to implement the persistence contract. The old `internal/inmemory` harness is deliberately volatile.

`durable.open(path, cluster, node_id, members, create=true)` exclusively creates a new database. Reopening omits `create`; a missing file, wrong identity, membership change, incompatible payload format, corrupt journal, or application watermark without decision evidence fails closed. Keep the parent directory on durable local storage, use one canonical pathname, and retain the database with its SQLite WAL. Do not delete a lock file, replace a live inode, use hard-link aliases, restore an old replica backup into an active identity, or independently modify the database. A lost replica needs a certified replacement/state-transfer procedure; format 3 does not implement that procedure.

The host owns a writer connection for application and consensus tables plus a read-only connection
for local snapshot queries. WAL mode and `synchronous=FULL` are checked. macOS also requests `fullfsync` and `checkpoint_fullfsync`. The pinned Linux build uses SQLite 3.51.3, which includes the [WAL-reset corruption fix](https://www.sqlite.org/releaselog/3_51_3.html). macOS uses its platform SQLite; the host serializes access to both connections.

Each transition follows this sequence:

1. Encode all promises, per-slot promises, votes and chosen decisions into a versioned little-endian journal. Encode logical fields, not compiler padding or pointers. Lossless zero-run packing retains inactive fields and all bits used in value equality. Record checksums form a SHA-256 chain; its head changes in the same transaction as the records.
2. Fold any leading no-op outcomes/watermark into the journal transaction, then commit with SQLite's FULL barrier. Only success advances the durable frontier and permits dependent effects to be released. The reference configuration also checks upstream's enforced gate.
3. Apply the contiguous prefix in groups of up to sixteen requests. Savepoints isolate expected rejections; deferred foreign keys are checked at each request boundary. A whole-group ROLLBACK falls back to individual transactions. SQL effects, outcomes, session records and the watermark become durable only at the outer FULL commit.
4. Copy outgoing payloads into owned packets, serve older decisions from disk, and advance the memory floor. The caller drains packets and provides transport and logical ticks.
5. Acknowledge only when `durable.acknowledged(host, slot, expected_value)` confirms that the expected value is durably chosen and applied. A proposal slot is not an acknowledgement.

A journal, unexpected application, or queue-allocation failure poisons the host. Expected SQL rejections complete without poisoning. A poisoned host emits no more packets or acknowledgements until it is closed and successfully recovered. Admission backpressure is recoverable by draining packets. Access must be serialized; the library does not create threads or a server.

Recovery checks SQLite integrity, identity, record lengths and hashes, sequence continuity, the chain head and ledger invariants. It restores promises and accepted values, verifies that applied slots have durable decisions and valid stored outcomes, then replays any unapplied contiguous decision suffix. A crash after the journal commit but before SQL application is therefore recoverable. Uncommitted SQLite transactions roll back through SQLite's WAL recovery.

`durable.next_id` durably reserves a block of 4096 Snowflake IDs before issuing any of them. Restart discards unused IDs and reserves a higher logical millisecond, including when the wall clock moves backward. Use this API instead of the engine's process-local generator. Node IDs must remain unique.

Format 3 retains complete decision history. This bounds the in-memory consensus window, but **disk usage and startup work grow with history**. Snapshot installation, journal compaction, membership changes, replacement of lost disks and backup/restore fencing are not implemented. There is no automatic migration from a previously volatile acceptor: form a new cluster identity with an explicitly coordinated data import.

The durable path enforces a function allowlist, including default expressions, and protects the
`_sqlodin_` namespace. Schema, engine-build, collation and ordering compatibility still require a
trusted caller contract; arbitrary SQL determinism is not yet established. Use version-2 transaction
requests for durable retry deduplication. Legacy raw and structured mutations do not carry request
IDs. `durable.outcome` distinguishes applied requests from completed SQL rejections, while
`acknowledged` returns true only for applied requests. See [the request contract](implementation-status.md).

`durable.propose_batch` admits up to sixteen independent requests through the complete upstream
batch API. Proposal and application batching preserve independent request outcomes. `step_batch`
groups up to sixteen incoming transitions with owned effects and a checked durable frontier; see
[the journal-group review](journal-group-commit.md). The `.Enforced` per-transition build remains
available with `-define:SQLODIN_JOURNAL_GROUP_COMMIT=false`. Window
exhaustion and outgoing queue saturation return `Backpressure`; drain/tick and retry without
changing an uncertain request's identity.

**Format migration:** format 3 / SQL policy 4 rejects earlier files and prototypes, and fingerprints
the SQLite source ID and build options. It preserves whole-value equality with lossless journal packing. Keep the previous binary, database and WAL.
No rolling migration, automatic conversion or lost-voter replacement is supported. Never edit
identity metadata or recreate an empty voter to bypass rejection.

`durable.begin_read` and `poll_read` provide a fresh ordered-barrier reference for fenced reads.
A ticket is single-use and bound to one active read on its host; a displaced marker requires a fresh
barrier. `cancel_read` retires the wait, not the proposed no-op. Only a ready barrier followed by its
new SQLite snapshot establishes the fenced read. Local snapshot reads alone remain local.
Read queries have row/instruction limits; those local limits do not decide replicated write outcomes.
See [the implementation ledger](implementation-status.md) for exact limits and remaining gates.

## Verification and limits

`python3 tools/check.py` runs the unit regressions and pinned upstream tests in debug and optimized builds. On Linux it also invokes `tools/check_durability.py`, which uses child-process SIGSTOP/SIGKILL at journal/application/acknowledgement boundaries and verifies restart contents. It also kills a three-voter cluster immediately after acknowledging its 80th write, before necessarily delivering every queued message, and verifies all three recovered copies. Unit tests cover simultaneous admission by all masters, history catch-up beyond the 64-slot window, persisted promises/votes, logical corruption, disk-full/read-only write failures, identity/locking, metadata protection and restart-safe IDs.

The original reports are `benchmarks/results/linux-durability.json` and `linux-durable-verification.log`.
The P1 campaign adds eight transaction/rejection/retry crash cases and records its source snapshot in
`benchmarks/results/linux-production-p1-durability.json`; its full run is `linux-production-p1-verification.log`. These tests exercise process crashes and injected failures, not a power-cut rig or exhaustive SQLite VFS I/O fault campaign. Durability depends on the filesystem/device honoring synchronization. Checksums detect damaged retained records; they cannot detect a rollback of the entire database and WAL to an internally consistent old backup. Passing these checks is evidence for the stated host contract, not production certification.

## Example integration

```odin
import durable "path/to/sqlodin/src/durable"

ids := [3]u16{1, 2, 3}
host, err := durable.open("data/node1.db", "orders-v1", 1, ids[:], create = true)
// Handle err. On later starts, omit create; never create to repair a missing voter.
defer durable.close(host)

slot, err := durable.propose(host, mutation)
// Drain durable.pop into caller-owned Packet storage, serialize durable.envelope(&packet),
// route authenticated incoming envelopes through durable.step, and call durable.tick.
// The next transition must not race packet serialization or any other host operation.
if durable.acknowledged(host, slot, &mutation) {
    // The expected value is durably chosen and applied; client completion is now valid.
}
```

The cluster identifier is local durable identity metadata. The application transport must also bind
every connection to the intended cluster and member; protocol envelopes alone do not carry a cluster
identifier or authentication. `engine_exec`, `engine_prepare`, and the underlying SQLite handle are
privileged embedding interfaces. Never expose them directly as an untrusted network SQL endpoint.
The safe snapshot API rejects configuration-changing PRAGMAs as well as writes.
