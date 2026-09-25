package durable

import db "../sqlite"

// Reserve a whole logical millisecond (4096 IDs) before issuing any IDs from it.
// Unused IDs are intentionally lost after a restart. Never call engine_next_id on this host.
next_id :: proc(h: ^Host, timestamp_ms: u64) -> (u64, Error) {
	if h.poisoned do return 0, .Poisoned
	if timestamp_ms >= u64(1) << 42 do return 0, .Invalid
	if h.id_next == h.id_end || timestamp_ms > h.id_next >> 22 {
		if !reserve_ids(h, timestamp_ms) do return 0, poison(h)
	}
	id := h.id_next
	h.id_next += 1
	return id, .None
}

reserve_ids :: proc(h: ^Host, timestamp_ms: u64) -> bool {
	if !history_record_room(h) do return false
	if !db.begin_tx(journal_db(h)) do return false
	defer db.rollback_tx(journal_db(h))
	s, ok := prepare(h, "SELECT ms FROM _sqlodin_ids WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	if db.sqlite3_step(s) != db.ROW do return false
	last := db.sqlite3_column_int64(s, 0)
	if last < -1 || last >= i64(1) << 42 do return false
	ms := max(timestamp_ms, u64(last + 1))
	if ms >= u64(1) << 42 do return false
	update, prepared := prepare(h, "UPDATE _sqlodin_ids SET ms=? WHERE id=1")
	if !prepared do return false
	defer db.sqlite3_finalize(update)
	if db.sqlite3_bind_int64(update, 1, i64(ms)) != db.OK do return false
	if db.sqlite3_step(update) != db.DONE || db.sqlite3_changes(journal_db(h)) != 1 {
		return false
	}
	if !db.commit_tx(journal_db(h)) do return false
	h.id_next = ms << 22 | u64(h.node.id) << 12
	h.id_end = h.id_next + 4096
	return true
}
