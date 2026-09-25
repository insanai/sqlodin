package durable

import sql ".."

Read_Ticket :: struct { slot: sql.Slot, token: u64 }
Read_Status :: enum { Pending, Ready, Displaced }
Read_Result :: struct { status: Read_Status, rows: int, sql_error: sql.Error }

@(private)
read_marker :: proc(id: sql.Node_Id, token: u64) -> sql.Mutation {
	m := sql.mutation_make_skip(id, 0)
	m.primary_key = token
	return m
}

// Call after the read invocation. One active barrier per serialized host; later
// arrivals may not borrow an already-proposed barrier. The durable ID reservation
// prevents reusing a marker after process restart or clock rollback.
begin_read :: proc(h: ^Host, timestamp_ms: u64) -> (ticket: Read_Ticket, err: Error) {
	if h.poisoned do return {}, .Poisoned
	if h.active_read.token != 0 do return {}, .Backpressure
	err = history_admission(h)
	if err != .None do return
	token := next_id(h, timestamp_ms) or_return
	slot := propose_internal(h, read_marker(h.node.id, token)) or_return
	h.active_read = Read_Ticket{slot, token}
	return h.active_read, .None
}

// The new marker must be chosen and its contiguous prefix locally applied before
// acquiring the SQLite read snapshot. Completed earlier writes therefore precede
// this read. This is an ordered-barrier reference, not a lease or Raft ReadIndex.
// Only the owning serialized host may use this ticket, and only once.
poll_read :: proc(h: ^Host, ticket: Read_Ticket, statement: string) -> (Read_Result, Error) {
	if h.poisoned do return {}, .Poisoned
	if ticket.token == 0 || ticket != h.active_read do return {}, .Invalid
	marker := read_marker(h.node.id, ticket.token)
	out, complete, err := outcome(h, ticket.slot, &marker)
	if err != .None do return {}, err
	if !complete {
		if h.engine.applied_through < ticket.slot do return {}, .None
		h.active_read = {}
		return Read_Result{status = .Displaced}, .None
	}
	if out.kind != .Applied do return {}, poison(h)
	// Consume even if the local query is invalid; it may not be reused for a
	// later invocation. Copying a ticket does not bypass the host's active token.
	h.active_read = {}
	rows, sql_err := sql.engine_read_snapshot(&h.engine, statement, ticket.slot)
	return Read_Result{.Ready, rows, sql_err}, .None
}

// Cancellation retires the caller's wait, not the consensus proposal. A subsequent
// read receives a new marker; an already-chosen no-op may still apply normally.
cancel_read :: proc(h: ^Host, ticket: Read_Ticket) -> Error {
	if ticket.token == 0 || ticket != h.active_read do return .Invalid
	h.active_read = {}
	return .None
}
