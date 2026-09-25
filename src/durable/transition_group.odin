package durable

import "core:container/queue"
import sql ".."
import db "../sqlite"

MAX_STEP_BATCH :: 16
GROUP_MESSAGES :: 256
GROUP_COMMITTED :: 2 * (WINDOW + 1)
GROUP_REQUESTS :: MAX_STEP_BATCH * MAX_MEMBERS
TRANSITION_MESSAGES :: MAX_MEMBERS * CHUNK + 2 * MAX_MEMBERS + 1
// Records per group stay far below HISTORY_TRANSITION_RESERVE's 2,112 records.
GROUP_RECORDS :: 1024

// Reused, bounded ownership workspace. No pointer borrowed from a node transition
// survives that transition: writes are encoded into the SQLite transaction, and
// messages/committed values are copied here before the next upstream call.
Transition_Group :: struct {
	packets: [GROUP_MESSAGES]Packet,
	values: [GROUP_COMMITTED]sql.Mutation,
	entries: [GROUP_COMMITTED]sql.Committed(sql.Mutation),
	requests: [GROUP_REQUESTS]sql.Host_Request,
	packet_count, entry_count, request_count: int,
	required_sequence: u64,
	open: bool, // the journal transaction has begun
}

// SOD 0005 M1: a service turn stages every protocol transition into one journal
// transaction and crosses one FULL barrier in turn_commit. Nothing is released
// before that barrier. Between turn_begin and turn_commit, the caller may use
// step_batch, propose, propose_batch, begin_read, tick, progress and catch_up;
// maintenance, snapshots and generation work must run outside a turn. A group
// that reaches a capacity bound commits early, so bounds add barriers but never
// drop work. The individual-commit configuration has no turns.
turn_begin :: proc(h: ^Host) -> Error {
	if h.poisoned do return .Poisoned
	when JOURNAL_GROUP_COMMIT {
		if h.turn_open do return .Invalid
		if h.transition_group == nil do h.transition_group = new(Transition_Group)
		h.turn_open = true
	}
	return .None
}

turn_commit :: proc(h: ^Host) -> Error {
	when JOURNAL_GROUP_COMMIT {
		if !h.turn_open do return .None
		h.turn_open = false
		if h.poisoned do return .Poisoned
		if !group_close(h) do return poison(h)
	}
	return .None
}

// One serialized call, at most sixteen authenticated input packets. Validate the
// complete batch before changing protocol state. Outside a turn a successful
// return has durably completed all subgroups; inside one, completion and release
// happen at turn_commit. Any storage/consensus failure poisons the host.
step_batch :: proc(h: ^Host, packets: []Packet) -> Error {
	if h.poisoned do return .Poisoned
	if len(packets) == 0 || len(packets) > MAX_STEP_BATCH do return .Invalid
	if queue.len(h.packets) >= 1024 do return .Backpressure
	for &packet in packets {
		env := envelope(&packet)
		if env.to != h.node.id || !sql.membership_contains(&h.node.membership, env.from) {
			return .Invalid
		}
		if value, ok := sql.message_value(env.message); ok {
			if sql.mutation_validate(value) != .None do return .Invalid
		}
	}
	when !JOURNAL_GROUP_COMMIT {
		for &packet in packets do step(h, envelope(&packet)) or_return
		return .None
	} else {
		standalone := !h.turn_open
		if standalone do turn_begin(h) or_return
		for &packet in packets {
			if !transition_room(h) do return poison(h)
			env := envelope(&packet)
			if sql.node_step(&h.node, env, &h.effects) != .None do return poison(h)
			if !stage_transition(h, h.transition_group) do return poison(h)
			// SOD 0005 M2/M5. Optional: without room, the owner's own Commit still arrives.
			if commit, fast := sql.owner_fast_commit(&h.node, env); fast && group_has_room(h) {
				if sql.node_step(&h.node, commit, &h.effects) != .None do return poison(h)
				if !stage_transition(h, h.transition_group) do return poison(h)
			}
		}
		if standalone do return turn_commit(h)
		return .None
	}
}

@(private)
group_has_room :: proc(h: ^Host) -> bool {
	g := h.transition_group
	return GROUP_MESSAGES - g.packet_count >= TRANSITION_MESSAGES &&
		GROUP_COMMITTED - g.entry_count >= WINDOW + 1 &&
		GROUP_REQUESTS - g.request_count >= MAX_MEMBERS &&
		h.sequence - g.required_sequence + u64(TRANSITION_RECORDS) <= GROUP_RECORDS
}

// Upper bound on journal records written by one upstream transition.
@(private)
TRANSITION_RECORDS :: 2 * (WINDOW + 1) + 2 * CHUNK + 4

// Called inside a turn before each upstream transition: open the journal
// transaction lazily, or commit a full group and start the next one.
@(private)
transition_room :: proc(h: ^Host) -> bool {
	g := h.transition_group
	if g.open && group_has_room(h) do return true
	if g.open && !group_close(h) do return false
	if h.sequence != h.durable_sequence || !db.begin_tx(journal_db(h)) do return false
	g.packet_count, g.entry_count, g.request_count = 0, 0, 0
	g.required_sequence = h.sequence
	g.open = true
	return true
}

// Commit the group's journal transaction (one FULL barrier), then apply the
// released contiguous prefix and publish the copied messages and requests.
@(private)
group_close :: proc(h: ^Host) -> bool {
	g := h.transition_group
	if !g.open do return true
	g.open = false
	defer if db.sqlite3_get_autocommit(journal_db(h)) == 0 do db.rollback_tx(journal_db(h))
	entries := g.entries[:g.entry_count]
	through, err := stage_journal_skips(h, entries)
	if err != .None || !commit_group_journal(h) do return false
	h.engine.applied_through = through
	if h.checkpoint != nil do h.checkpoint(.After_Journal_Commit)
	if h.fault == .After_Journal_Commit do return false
	if h.sequence != h.durable_sequence do return false
	sql.effects_confirm_writes_durable(&h.effects)
	if !apply_host_entries(h, entries) do return false
	if h.checkpoint != nil do h.checkpoint(.After_Application_Commit)
	if h.fault == .After_Application_Commit do return false
	for &packet in g.packets[:g.packet_count] {
		if !append_packet(h, envelope(&packet)) do return false
	}
	for request in g.requests[:g.request_count] {
		switch r in request {
		case sql.Serve_Range_Request: if !serve(h, r) do return false
		}
	}
	if sql.node_advance_memory_floor(&h.node, h.engine.applied_through) != .None {
		return false
	}
	sql.effects_reset(&h.effects)
	g.packet_count, g.entry_count, g.request_count = 0, 0, 0
	return true
}

@(private)
stage_transition :: proc(h: ^Host, g: ^Transition_Group) -> bool {
	for w in sql.effects_writes_slice(&h.effects) {
		r, ok := make_record(w)
		if !ok || !persist_record(h, &r) do return false
	}
	// Host_Managed permits inspection here, but not publication. Copies remain
	// private until the complete group has crossed its FULL journal barrier.
	for env in sql.effects_messages_slice(&h.effects) {
		if g.packet_count == GROUP_MESSAGES do return false
		p := &g.packets[g.packet_count]
		p.env = env
		if value, ok := sql.message_value(env.message); ok do p.value = value^
		g.packet_count += 1
	}
	for entry in sql.effects_committed_slice(&h.effects) {
		if g.entry_count == GROUP_COMMITTED do return false
		i := g.entry_count
		g.values[i] = entry.value^
		g.entries[i] = {entry.slot, &g.values[i]}
		g.entry_count += 1
	}
	for request in sql.effects_requests_slice(&h.effects) {
		if g.request_count == GROUP_REQUESTS do return false
		g.requests[g.request_count] = request
		g.request_count += 1
	}
	sql.effects_reset(&h.effects)
	return true
}

@(private)
commit_group_journal :: proc(h: ^Host) -> bool {
	if h.sequence == h.durable_sequence do return db.commit_tx(journal_db(h))
	s, ok := prepare(h, "UPDATE _sqlodin_journal_meta SET seq=?,digest=? WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	if db.sqlite3_bind_int64(s, 1, i64(h.sequence)) != db.OK || !bind_blob(s, 2, h.head[:]) ||
	   db.sqlite3_step(s) != db.DONE || db.sqlite3_changes(journal_db(h)) != 1 {
		return false
	}
	if h.checkpoint != nil do h.checkpoint(.Before_Journal_Commit)
	if h.fault == .Before_Journal_Commit || !db.commit_tx(journal_db(h)) do return false
	h.durable_sequence = h.sequence
	return true
}
