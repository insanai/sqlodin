package sqlodin

// Comprehensive enumeration of consensus, SQLite engine, and multi-master error codes.
Error :: enum {
	None = 0,

	// Membership errors
	Empty_Membership,
	Too_Many_Members,
	Invalid_Node_Id,
	Duplicate_Node_Id,
	Invalid_Read_Quorum,
	Invalid_Write_Quorum,
	Non_Intersecting_Quorums,

	// Input and addressing errors
	Not_Member,
	Wrong_Recipient,
	Invalid_Peer,
	Invalid_Slot,
	Read_Buffer_Too_Small,
	Unknown_Node,

	// Liveness and multi-master progress errors
	Window_Full,
	Global_Slot_Exhausted,
	Empty_Batch,
	Slot_Buffer_Too_Small,
	Ballot_Exhausted,
	Invalid_Promise,
	Slot_Not_Owned,
	Resubmit_Queue_Full,
	Campaign_Disabled,
	Stall_Detected,

	// Durability and safety violations
	Promise_Regression,
	Conflicting_Value,
	Conflicting_Commit,
	Trim_Regression,
	Durability_Gate_Breached,

	// SQLite engine and state machine errors
	Sqlite_Open_Failed,
	Sqlite_Exec_Failed,
	Sqlite_Prepare_Failed,
	Sqlite_Step_Failed,
	Sqlite_Constraint_Violation,
	Sqlite_Table_Not_Found,
	Sqlite_Corrupt,

	// Multi-master mutation errors
	Snowflake_Exhausted,
	Invalid_Mutation,
	Payload_Too_Large,
	Serialization_Failed,
	Deserialization_Failed,
	Stale_Watermark,
	Query_Limit,

	// Vector search and FTS5 errors
	Vector_Dimension_Mismatch,
	Vector_Invalid_Format,
	Vector_Extension_Not_Loaded,
	Fts_Query_Failed,
}

// Every error explains itself: a title, the cause, and a corrective `Hint:`.
@(rodata)
EXPLANATIONS := [Error]string{
	.Query_Limit = `
-- QUERY RESOURCE LIMIT --------------------------------------------------------

The local read exceeded its row or SQLite instruction budget; its result is incomplete.
Hint: Use indexed, bounded queries or paginate. Do not treat partial rows as a successful result.
`,
	.None = "No error.",
	.Empty_Membership = `
-- EMPTY MEMBERSHIP ------------------------------------------------------------

A consensus configuration needs at least one voting member.
Hint: Pass a slice with at least one non-zero ID to membership_init().
`,
	.Too_Many_Members = `
-- TOO MANY MEMBERS ------------------------------------------------------------

The membership is larger than the compile-time MAX_MEMBERS bound.
Hint: Reduce the member slice or deliberately raise MAX_MEMBERS.
`,
	.Invalid_Node_Id = `
-- INVALID NODE ID -------------------------------------------------------------

Node ID zero is reserved; the SQLite engine requires a 10-bit ID (1..1023).
Hint: Assign every logical member a stable, non-zero ID.
`,
	.Duplicate_Node_Id = `
-- DUPLICATE NODE ID -----------------------------------------------------------

The membership contains one voting identity more than once.
Hint: Validate uniqueness before calling membership_init().
`,
	.Invalid_Read_Quorum = `
-- INVALID READ QUORUM ----------------------------------------------------------

The phase-one quorum override is negative or exceeds the member count.
Hint: Use zero for a majority, or choose 1 <= read_quorum_size <= member_count.
`,
	.Invalid_Write_Quorum = `
-- INVALID WRITE QUORUM ---------------------------------------------------------

The phase-two quorum override is negative or exceeds the member count.
Hint: Use zero for a majority, or choose 1 <= write_quorum_size <= member_count.
`,
	.Non_Intersecting_Quorums = `
-- NON-INTERSECTING QUORUMS ----------------------------------------------------

A phase-one quorum might miss a prior phase-two quorum.
Hint: Require read_quorum_size + write_quorum_size > member_count.
`,
	.Not_Member = `
-- NOT A MEMBER ----------------------------------------------------------------

The source, target, or local ID is outside the active membership.
Hint: Check the cluster membership configuration and peer identity.
`,
	.Wrong_Recipient = `
-- WRONG RECIPIENT --------------------------------------------------------------

The envelope target is not the node processing it.
Hint: Repair transport routing before retrying the envelope.
`,
	.Invalid_Peer = `
-- INVALID PEER -----------------------------------------------------------------

A peer-only operation targeted the local node itself.
Hint: Pass a different member ID to the peer operation.
`,
	.Invalid_Slot = `
-- INVALID SLOT -----------------------------------------------------------------

Slot zero is reserved and cannot address a log entry.
Hint: Use a one-based slot index.
`,
	.Read_Buffer_Too_Small = `
-- READ BUFFER TOO SMALL --------------------------------------------------------

The caller buffer cannot hold the requested read entries.
Hint: Allocate sufficient capacity for the output slice.
`,
	.Unknown_Node = `
-- UNKNOWN NODE -----------------------------------------------------------------

The referenced node identity is unmapped in the cluster.
Hint: Ensure the node ID is included in membership_init().
`,
	.Window_Full = `
-- WINDOW FULL ------------------------------------------------------------------

Active proposals have exhausted the sliding consensus window.
Hint: Advance the memory floor or apply and trim decided slots.
`,
	.Global_Slot_Exhausted = `
-- GLOBAL SLOT EXHAUSTED --------------------------------------------------------

The 64-bit slot number reached maximum representable integer capacity.
Hint: Log capacity is exhausted; reconfigure with a new configuration epoch.
`,
	.Empty_Batch = `
-- EMPTY BATCH ------------------------------------------------------------------

A batch proposal was invoked with zero items.
Hint: Provide at least one valid mutation to propose_batch().
`,
	.Slot_Buffer_Too_Small = `
-- SLOT BUFFER TOO SMALL --------------------------------------------------------

The output slice cannot accommodate all allocated batch slots.
Hint: Pass a slice sized to at least the count of mutations in the batch.
`,
	.Ballot_Exhausted = `
-- BALLOT EXHAUSTED -------------------------------------------------------------

Round counter reached MAX_ROUND in packed ballot representation.
Hint: Reconfigure the cluster before ballot counter overflows 40 bits.
`,
	.Invalid_Promise = `
-- INVALID PROMISE --------------------------------------------------------------

An incoming promise message violates monotonicity or chunk bounds.
Hint: Inspect network frames for packet corruption or outdated peer state.
`,
	.Slot_Not_Owned = `
-- SLOT NOT OWNED ---------------------------------------------------------------

Under rotating slot ownership, node proposed into a slot owned by a peer.
Hint: In multi-master mode, propose only into slots where slot % N == owner.
`,
	.Resubmit_Queue_Full = `
-- RESUBMIT QUEUE FULL ----------------------------------------------------------

The bounded queue for stalled mutation resubmissions is exhausted.
Hint: Drain pending revocations or increase options.resubmit_queue_capacity.
`,
	.Campaign_Disabled = `
-- CAMPAIGN DISABLED ------------------------------------------------------------

Phase 1 campaign was called on a node configured for multi-master ownership.
Hint: Multi-master nodes propose directly on the fast path without campaigns.
`,
	.Stall_Detected = `
-- STALL DETECTED ---------------------------------------------------------------

A peer slot owner failed to advance its slot within the stall timeout window.
Hint: Trigger a bounded revocation to propose a no-op skip in the stalled slot.
`,
	.Promise_Regression = `
-- PROMISE REGRESSION -----------------------------------------------------------

An acceptor attempted to lower an existing promised ballot.
Hint: Durability violation: inspect journal replay or memory corruption.
`,
	.Conflicting_Value = `
-- CONFLICTING VALUE ------------------------------------------------------------

Two divergent values were proposed under the same ballot and slot.
Hint: Safety invariant breached: verify ballot uniqueness via node ID.
`,
	.Conflicting_Commit = `
-- CONFLICTING COMMIT -----------------------------------------------------------

Commit payload differs from the value accepted by write quorum.
Hint: Safety invariant breached: check ledger state and network integrity.
`,
	.Trim_Regression = `
-- TRIM REGRESSION --------------------------------------------------------------

A trim operation attempted to move the trim anchor backward in the log.
Hint: Log trims must be monotonically increasing.
`,
	.Durability_Gate_Breached = `
-- DURABILITY GATE BREACHED ----------------------------------------------------

Network message was emitted before corresponding ledger write was fsynced.
Hint: Enforce the durability gate: call effects_mark_durable() after disk sync.
`,
	.Sqlite_Open_Failed = `
-- SQLITE OPEN FAILED -----------------------------------------------------------

SQLite failed to open the database file or initialize memory database.
Hint: Check filesystem permissions, path validity, and available disk space.
`,
	.Sqlite_Exec_Failed = `
-- SQLITE EXEC FAILED -----------------------------------------------------------

An execution of a raw SQL statement returned a non-OK status code.
Hint: Verify SQL statement syntax, table schema, and SQLite error message.
`,
	.Sqlite_Prepare_Failed = `
-- SQLITE PREPARE FAILED ---------------------------------------------------------

sqlite3_prepare_v2 failed on statement compilation.
Hint: Check query syntax and schema validity using sqlite3_errmsg().
`,
	.Sqlite_Step_Failed = `
-- SQLITE STEP FAILED ------------------------------------------------------------

sqlite3_step failed during execution or row iteration.
Hint: Inspect constraint violations or transaction locks in SQLite.
`,
	.Sqlite_Constraint_Violation = `
-- SQLITE CONSTRAINT VIOLATION --------------------------------------------------

Database constraint (UNIQUE, CHECK, NOT NULL, FOREIGN KEY) was violated.
Hint: In multi-master writes, use Snowflake IDs or UPSERT to prevent conflicts.
`,
	.Sqlite_Table_Not_Found = `
-- SQLITE TABLE NOT FOUND -------------------------------------------------------

Target table does not exist in the local SQLite schema.
Hint: Run schema migrations before submitting mutations to this table.
`,
	.Sqlite_Corrupt = `
-- SQLITE CORRUPT ---------------------------------------------------------------

The SQLite database file reported corruption (SQLITE_CORRUPT).
Hint: Recover from state anchor and replay committed journal suffix.
`,
	.Snowflake_Exhausted = `
-- SNOWFLAKE EXHAUSTED ---------------------------------------------------------

The logical millisecond counter exceeds the 42-bit Snowflake timestamp field.
Hint: Use timestamps within a defined epoch and persist the ID frontier across restarts.
`,
	.Invalid_Mutation = `
-- INVALID MUTATION -------------------------------------------------------------

Mutation structure has unknown kind, missing columns, or invalid values.
Hint: Construct mutations using valid insert, delete, or update builders.
`,
	.Payload_Too_Large = `
-- PAYLOAD TOO LARGE ------------------------------------------------------------

Serialized mutation payload exceeds maximum supported envelope size.
Hint: Chunk large batch mutations or increase maximum buffer allocation.
`,
	.Serialization_Failed = `
-- SERIALIZATION FAILED ---------------------------------------------------------

Failed to encode mutation descriptor into network wire format.
Hint: Check buffer size and ensure all value types are valid primitives.
`,
	.Deserialization_Failed = `
-- DESERIALIZATION FAILED -------------------------------------------------------

Incoming message payload could not be decoded into a valid Mutation.
Hint: Protocol version mismatch or network packet corruption detected.
`,
	.Stale_Watermark = `
-- STALE WATERMARK --------------------------------------------------------------

Read-Your-Writes read requested a slot beyond the known cluster frontier.
Hint: Wait for local state machine replication to catch up to the watermark.
`,
	.Vector_Dimension_Mismatch = `
-- VECTOR DIMENSION MISMATCH ----------------------------------------------------

Input vector dimension does not match the target vec0 virtual table schema.
Hint: Verify embedding vector length (e.g. 384 vs 768 vs 1536 floats).
`,
	.Vector_Invalid_Format = `
-- VECTOR INVALID FORMAT --------------------------------------------------------

Failed to format or parse vector float array for sqlite-vec.
Hint: Vectors must be valid non-empty arrays of 32-bit floating point numbers.
`,
	.Vector_Extension_Not_Loaded = `
-- VECTOR EXTENSION NOT LOADED --------------------------------------------------

sqlite-vec virtual table module (vec0) is not registered with the SQLite db.
Hint: Call sqlite_vec_register(db) before executing vector queries.
`,
	.Fts_Query_Failed = `
-- FTS QUERY FAILED -------------------------------------------------------------

Full-text search MATCH query failed on FTS5 virtual table.
Hint: Check query syntax; words with hyphens must be quoted in FTS5 syntax.
`,
}

// Explains an error with actionable remediation diagnostics.
explain_engine_error :: proc(err: Error) -> string {
	return EXPLANATIONS[err]
}
