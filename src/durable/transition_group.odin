package durable

import "core:container/queue"
import sql ".."
import db "../sqlite"

MAX_STEP_BATCH :: 16
GROUP_MESSAGES :: 256
GROUP_COMMITTED :: 2 * (WINDOW + 1)
GROUP_REQUESTS :: MAX_STEP_BATCH * MAX_MEMBERS
TRANSITION_MESSAGES :: MAX_MEMBERS * CHUNK + 2 * MAX_MEMBERS + 1

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
}

// One serialized call, at most sixteen authenticated input packets. Validate the
// complete batch before changing protocol state. A successful return has durably
// completed all subgroups; any storage/consensus failure poisons the host.
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
		if h.transition_group == nil do h.transition_group = new(Transition_Group)
		for first := 0; first < len(packets); {
			count, ok := persist_transition_group(h, packets[first:])
			if !ok || count == 0 do return poison(h)
			first += count
		}
		return .None
	}
}

@(private)
group_has_room :: proc(g: ^Transition_Group) -> bool {
	return GROUP_MESSAGES - g.packet_count >= TRANSITION_MESSAGES &&
		GROUP_COMMITTED - g.entry_count >= WINDOW + 1 &&
		GROUP_REQUESTS - g.request_count >= MAX_MEMBERS
}

@(private)
persist_transition_group :: proc(h: ^Host, packets: []Packet) -> (count: int, ok: bool) {
	g := h.transition_group
	g.packet_count, g.entry_count, g.request_count = 0, 0, 0
	g.required_sequence = h.sequence
	if h.sequence != h.durable_sequence || !db.begin_tx(h.engine.db) do return 0, false
	defer if db.sqlite3_get_autocommit(h.engine.db) == 0 do db.rollback_tx(h.engine.db)
	for &packet in packets {
		if !group_has_room(g) do break
		if sql.node_step(&h.node, envelope(&packet), &h.effects) != .None do return 0, false
		if !stage_transition(h, g) do return 0, false
		count += 1
	}
	entries := g.entries[:g.entry_count]
	through, err := sql.engine_stage_skip_prefix(&h.engine, entries)
	if err != .None || !commit_group_journal(h) do return count, false
	h.engine.applied_through = through
	if h.checkpoint != nil do h.checkpoint(.After_Journal_Commit)
	if h.fault == .After_Journal_Commit do return count, false
	if g.required_sequence > h.durable_sequence do return count, false
	sql.effects_confirm_writes_durable(&h.effects)
	if sql.engine_apply_outcomes(&h.engine, entries) != .None do return count, false
	if h.checkpoint != nil do h.checkpoint(.After_Application_Commit)
	if h.fault == .After_Application_Commit do return count, false
	for &packet in g.packets[:g.packet_count] {
		if !append_packet(h, envelope(&packet)) do return count, false
	}
	for request in g.requests[:g.request_count] {
		switch r in request {
		case sql.Serve_Range_Request: if !serve(h, r) do return count, false
		}
	}
	if sql.node_advance_memory_floor(&h.node, h.engine.applied_through) != .None {
		return count, false
	}
	sql.effects_reset(&h.effects)
	return count, true
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
	g.required_sequence = h.sequence
	return true
}

@(private)
commit_group_journal :: proc(h: ^Host) -> bool {
	if h.sequence == h.durable_sequence do return db.commit_tx(h.engine.db)
	s, ok := prepare(h, "UPDATE _sqlodin_journal_meta SET seq=?,digest=? WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	if db.sqlite3_bind_int64(s, 1, i64(h.sequence)) != db.OK || !bind_blob(s, 2, h.head[:]) ||
	   db.sqlite3_step(s) != db.DONE || db.sqlite3_changes(h.engine.db) != 1 {
		return false
	}
	if h.checkpoint != nil do h.checkpoint(.Before_Journal_Commit)
	if h.fault == .Before_Journal_Commit || !db.commit_tx(h.engine.db) do return false
	h.durable_sequence = h.sequence
	return true
}
