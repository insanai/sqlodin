package sqlodin

import "core:c"
import "sqlite"

// Revision changes only when application SQL applies, never for read barriers or
// duplicate/rejected requests. It is updated in the same transaction as outcomes.
engine_read_version :: proc(e: ^Engine) -> (result: u64, err: Error) {
	s := engine_prepare(e, "SELECT version FROM _sqlodin_tx_revision WHERE id=1") or_return
	defer sqlite.sqlite3_finalize(s)
	if sqlite.sqlite3_step(s) != sqlite.ROW do return 0, .Sqlite_Corrupt
	version := sqlite.sqlite3_column_int64(s, 0)
	if version <= 0 do return 0, .Sqlite_Corrupt
	return u64(version), .None
}

@(private)
engine_advance_version :: proc(e: ^Engine, slot: Slot) -> Error {
	if slot >= u64(max(i64)) do return .Invalid_Slot
	s := engine_prepare(e, "UPDATE _sqlodin_tx_revision SET version=? WHERE id=1") or_return
	defer sqlite.sqlite3_finalize(s)
	if sqlite.sqlite3_bind_int64(s, 1, i64(slot + 1)) != sqlite.OK ||
	   sqlite.sqlite3_step(s) != sqlite.DONE {
		return .Sqlite_Step_Failed
	}
	return .None
}

// A preview owns a short-lived connection and always rolls back. No SQLite lock,
// mutable workspace or snapshot survives a network round trip. The ordered commit
// checks the same revision before executing the complete batch on every replica.
engine_preview :: proc(
	e: ^Engine, body, query: ^Mutation, allocator := context.allocator,
) -> (result: Query_Result, out: Outcome, changes, lastrowid: i64, err: Error) {
	version := engine_read_version(e) or_return
	if body.read_version == 0 || version != body.read_version {
		out.kind = .Conflict
		return
	}
	defensive: c.int
	if sqlite.sqlite3_db_config(e.db, 1010, c.int(1), &defensive) != sqlite.OK || defensive != 1 {
		return {}, {}, 0, 0, .Sqlite_Open_Failed
	}
	sqlite.sqlite3_update_hook(e.db, engine_policy_rowid, e.authorization)
	if !sqlite.exec(e.db, "PRAGMA foreign_keys=ON") do return {}, {}, 0, 0, .Sqlite_Exec_Failed
	if !sqlite.begin_tx(e.db) do return {}, {}, 0, 0, .Sqlite_Exec_Failed
	defer sqlite.rollback_tx(e.db)
	// Preview work is uncommitted and can safely be interrupted. Replicated
	// writes retain their separate deterministic execution contract.
	budget := Read_Budget{remaining = MAX_READ_PROGRESS_CALLS}
	sqlite.sqlite3_progress_handler(e.db, READ_PROGRESS_INTERVAL, engine_read_progress, &budget)
	defer sqlite.sqlite3_progress_handler(e.db, 0, nil, nil)
	if body.sql_len > 0 {
		err = engine_run_outcome(e, body, &out)
		if budget.exhausted do err = .Query_Limit
		if err != .None || out.kind != .Applied do return
		changes = i64(sqlite.sqlite3_changes(e.db))
		lastrowid = sqlite.sqlite3_last_insert_rowid(e.db)
	}
	if query.sql_len > 0 {
		result, err = engine_query(e, mutation_sql(query), query, allocator)
	}
	return
}
