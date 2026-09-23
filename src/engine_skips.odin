package sqlodin

import "sqlite"

// Fold only a leading sequence of no-op decisions into the host's journal
// transaction. No user SQL, callbacks or session changes occur here. The host
// advances its in-memory watermark only after the containing FULL commit.
engine_stage_skip_prefix :: proc(
	e: ^Engine, entries: []Committed(Mutation),
) -> (through: Slot, err: Error) {
	through = e.applied_through
	if sqlite.sqlite3_get_autocommit(e.db) != 0 do return through, .Sqlite_Exec_Failed
	for entry in entries {
		if entry.slot <= through do continue
		if through == u64(max(i64)) || entry.slot != through + 1 do return through, .Invalid_Slot
		if entry.value.kind != .Skip do break
		mutation_validate(entry.value) or_return
		engine_record_outcome(e, entry.slot, Outcome{slot = entry.slot}, entry.value, false) or_return
		through = entry.slot
	}
	return through, .None
}
