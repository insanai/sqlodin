package sqlodin

import "core:c"
import "sqlite"

APPLICATION_GROUP_COMMIT :: #config(SQLODIN_APPLICATION_GROUP_COMMIT, true)
MAX_APPLICATION_GROUP :: 16

// Each request is a savepoint with an independently checked FK boundary. Only
// the outer FULL commit publishes outcomes and the applied watermark. A SQL
// ROLLBACK can abort that outer transaction: replay the complete unacknowledged
// group through the individual-transaction reference path in that case.
@(private)
engine_apply_group :: proc(
	e: ^Engine, entries: []Committed(Mutation),
) -> (grouped: bool, err: Error) {
	if len(entries) == 0 || len(entries) > MAX_APPLICATION_GROUP do return false, .Invalid_Mutation
	if !sqlite.begin_tx(e.db) do return false, .Sqlite_Exec_Failed
	defer if sqlite.sqlite3_get_autocommit(e.db) == 0 do sqlite.rollback_tx(e.db)
	for entry in entries {
		staged := engine_stage_request(e, entry.slot, entry.value) or_return
		if !staged do return false, .None
	}
	if e.application_before_commit != nil do e.application_before_commit()
	if !sqlite.commit_tx(e.db) do return false, .Sqlite_Exec_Failed
	e.applied_through = entries[len(entries) - 1].slot
	return true, .None
}

@(private)
engine_stage_request :: proc(
	e: ^Engine, slot: Slot, m: ^Mutation,
) -> (staged: bool, err: Error) {
	out := Outcome{slot = slot}
	execute, record_session := true, false
	if m.kind == .Transaction {
		out, execute, record_session = engine_request_lookup(e, m, slot) or_return
	}
	if !sqlite.exec(e.db, "SAVEPOINT _sqlodin_request") do return false, .Sqlite_Exec_Failed
	if execute {
		engine_run_outcome(e, m, &out) or_return
		if sqlite.sqlite3_get_autocommit(e.db) != 0 {
			// Only a classified rejection can cause semantic fallback. Storage,
			// OOM and unknown failures have already returned through or_return.
			if out.kind == .Applied do return false, .Sqlite_Exec_Failed
			return false, .None
		}
		if out.kind == .Applied {
			current, highwater: c.int
			if sqlite.sqlite3_db_status(e.db, 10, &current, &highwater, 0) != sqlite.OK {
				return false, .Sqlite_Exec_Failed
			}
			if current != 0 {
				out = Outcome{kind = .Constraint, sqlite_code = sqlite.CONSTRAINT | (3 << 8), slot = slot}
			}
		}
		if out.kind != .Applied {
			if !sqlite.exec(e.db, "ROLLBACK TO _sqlodin_request") do return false, .Sqlite_Exec_Failed
		}
	}
	if !sqlite.exec(e.db, "RELEASE _sqlodin_request") do return false, .Sqlite_Exec_Failed
	engine_record_outcome(e, slot, out, m, record_session) or_return
	return true, .None
}
