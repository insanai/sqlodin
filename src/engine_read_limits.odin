package sqlodin

import "base:runtime"
import "core:c"
import "sqlite"

MAX_READ_ROWS :: 65536
READ_PROGRESS_INTERVAL :: 1000
MAX_READ_PROGRESS_CALLS :: 1000
Read_Budget :: struct { remaining: int, exhausted: bool }

// This is a local read budget, never a replicated SQL outcome. SQLite progress
// callback counts are approximate and depend on preparation/planning; using them
// to decide a replicated write's success would require a separate determinism proof.
@(private)
engine_read_progress :: proc "c" (user: rawptr) -> c.int {
	context = runtime.default_context()
	budget := cast(^Read_Budget)user
	budget.remaining -= 1
	if budget.remaining > 0 do return 0
	budget.exhausted = true
	return 1
}

@(private)
engine_prepare_read :: proc(db: sqlite.Sqlite3, text: string) -> (sqlite.Sqlite3_Stmt, Error) {
	if len(text) == 0 || len(text) > MAX_SQL_LEN do return nil, .Payload_Too_Large
	stmt: sqlite.Sqlite3_Stmt
	tail: cstring
	rc := sqlite.sqlite3_prepare_v2(db, cstring(raw_data(text)), c.int(len(text)), &stmt, &tail)
	if rc != sqlite.OK || stmt == nil {
		if stmt != nil do sqlite.sqlite3_finalize(stmt)
		return nil, .Sqlite_Prepare_Failed
	}
	valid := false
	defer if !valid do sqlite.sqlite3_finalize(stmt)
	if sqlite.sqlite3_stmt_readonly(stmt) == 0 do return nil, .Invalid_Mutation
	consumed := int(uintptr(rawptr(tail)) - uintptr(raw_data(text)))
	if consumed <= 0 || consumed > len(text) do return nil, .Invalid_Mutation
	rest := text[consumed:]
	if len(rest) > 0 {
		extra: sqlite.Sqlite3_Stmt
		rc = sqlite.sqlite3_prepare_v2(db, cstring(raw_data(rest)), c.int(len(rest)), &extra, nil)
		if extra != nil do sqlite.sqlite3_finalize(extra)
		if rc != sqlite.OK || extra != nil do return nil, .Invalid_Mutation
	}
	valid = true
	return stmt, .None
}
