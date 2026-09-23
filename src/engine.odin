package sqlodin

import "base:runtime"
import "core:c"
import "core:strings"
import "sqlite"

Engine :: struct {
	db:              sqlite.Sqlite3,
	read_db:         sqlite.Sqlite3,
	authorization:   ^Engine_Authorization,
	last_sqlite_code: c.int,
	last_expression_error: bool,
	applied_through: Slot,
	snowflake_seq:   u16,
	snowflake_ms:    u64,
	snowflake_ready: bool,
	node_id:         Node_Id,
	in_memory:       bool,
	vec_enabled:     bool,
	watermark_stmt:  sqlite.Sqlite3_Stmt,
	statements:      [8]Engine_Statement,
	statement_next:  int,
	// Test-only crash boundary; production callers leave this nil.
	application_before_commit: proc(),
}

engine_open :: proc(
	path: string,
	node_id: Node_Id,
	memory: bool = false,
) -> (Engine, Error) {
	if node_id == 0 || node_id > 1023 do return {}, .Invalid_Node_Id
	db, ok := sqlite.open(path, memory)
	if !ok do return {}, .Sqlite_Open_Failed
	e := Engine{db = db, node_id = node_id, in_memory = memory}
	if !memory && !sqlite.enable_wal(db) {
		engine_close(&e)
		return {}, .Sqlite_Open_Failed
	}
	e.vec_enabled = sqlite.vec_register(db)
	if err := engine_load_watermark(&e); err != .None {
		engine_close(&e)
		return {}, err
	}
	e.authorization = new(Engine_Authorization)
	if sqlite.sqlite3_set_authorizer(db, engine_sql_authorize, e.authorization) != sqlite.OK {
		engine_close(&e)
		return {}, .Sqlite_Open_Failed
	}
	return e, .None
}

engine_close :: proc(e: ^Engine) {
	if e.db == nil do return
	if e.read_db != nil do sqlite.close(e.read_db)
	e.read_db = nil
	for &entry in e.statements {
		if entry.stmt != nil do sqlite.sqlite3_finalize(entry.stmt)
		entry = {}
	}
	if e.watermark_stmt != nil do sqlite.sqlite3_finalize(e.watermark_stmt)
	sqlite.close(e.db)
	free(e.authorization)
	e.authorization = nil
	e.db = nil
	e.watermark_stmt = nil
}

engine_applied_through :: #force_inline proc(e: ^Engine) -> Slot {
	return e.applied_through
}

// Logical milliseconds handle clock rollback and more than 4096 IDs per millisecond.
// Across restarts the host must supply a timestamp above the last issued logical ms.
engine_next_id_checked :: proc(e: ^Engine, timestamp_ms: u64) -> (u64, Error) {
	if e.node_id == 0 || e.node_id > 1023 do return 0, .Invalid_Node_Id
	ms := max(timestamp_ms, e.snowflake_ms)
	seq: u16
	if e.snowflake_ready && ms == e.snowflake_ms {
		if e.snowflake_seq == 4095 {
			ms += 1
		} else {
			seq = e.snowflake_seq + 1
		}
	}
	if ms >= u64(1) << 42 do return 0, .Snowflake_Exhausted
	e.snowflake_ms, e.snowflake_seq, e.snowflake_ready = ms, seq, true
	return ms << 22 | u64(e.node_id) << 12 | u64(seq), .None
}

// Convenience API for callers whose timestamps are known to fit the Snowflake epoch.
engine_next_id :: proc(e: ^Engine, timestamp_ms: u64) -> u64 {
	id, err := engine_next_id_checked(e, timestamp_ms)
	if err != .None do panic(explain_engine_error(err))
	return id
}

// Privileged local setup/inspection. Replicated writes must go through apply_slot/batch.
engine_exec :: proc(e: ^Engine, sql: string) -> Error {
	good := sqlite.exec(e.db, sql)
	engine_capture_error(e)
	if !good do return .Sqlite_Exec_Failed
	return .None
}

@(private)
engine_execute_mutation :: proc(e: ^Engine, m: ^Mutation) -> Error {
	switch m.kind {
	case .Insert, .Update, .Delete:
		return engine_apply_dml(e, m)
	case .Raw_SQL:
		if e.authorization.deterministic do return engine_execute_transaction(e, m)
		return engine_apply_raw(e, mutation_sql(m))
	case .Transaction:
		return engine_execute_transaction(e, m)
	case .Skip:
		return .None
	}
	return .Invalid_Mutation
}

// Apply a contiguous prefix in one transaction. Both SQL and the persisted watermark
// roll back on any failure. A failed decided mutation blocks application until repaired.
engine_apply_batch :: proc(e: ^Engine, entries: []Committed(Mutation)) -> Error {
	through := e.applied_through
	first := len(entries)
	for entry, i in entries {
		if entry.slot == 0 do return .Invalid_Slot
		if entry.slot <= e.applied_through do continue
		if through == max(Slot) || entry.slot != through + 1 do return .Invalid_Slot
		mutation_validate(entry.value) or_return
		first = min(first, i)
		through = entry.slot
	}
	if first == len(entries) do return .None
	if !sqlite.begin_tx(e.db) do return .Sqlite_Exec_Failed
	committed := false
	defer if !committed do sqlite.rollback_tx(e.db)
	e.authorization.restricted = true
	defer e.authorization.restricted = false
	for entry in entries[first:] {
		if entry.slot <= e.applied_through do continue
		engine_execute_mutation(e, entry.value) or_return
	}
	e.authorization.restricted = false
	stmt := e.watermark_stmt
	defer sqlite.sqlite3_reset(stmt)
	if sqlite.sqlite3_bind_int64(stmt, 1, i64(through)) != sqlite.OK {
		return .Sqlite_Step_Failed
	}
	if sqlite.sqlite3_step(stmt) != sqlite.DONE do return .Sqlite_Step_Failed
	if !sqlite.commit_tx(e.db) do return .Sqlite_Exec_Failed
	committed = true
	e.applied_through = through
	return .None
}

engine_apply_slot :: proc(e: ^Engine, slot: Slot, m: ^Mutation) -> Error {
	entry := [1]Committed(Mutation){{slot = slot, value = m}}
	return engine_apply_batch(e, entry[:])
}

// Counts result rows (SELECT count(*) itself produces ONE result row).
// The host serializes access to this connection and its applied watermark.
engine_read_snapshot :: proc(
	e: ^Engine,
	sql: string,
	min_watermark: Slot = 0,
) -> (rows: int, err: Error) {
	if e.applied_through < min_watermark do return 0, .Stale_Watermark
	e.authorization.restricted = true
	defer e.authorization.restricted = false
	db := e.read_db if e.read_db != nil else e.db
	budget := Read_Budget{remaining = MAX_READ_PROGRESS_CALLS}
	sqlite.sqlite3_progress_handler(db, READ_PROGRESS_INTERVAL, engine_read_progress, &budget)
	defer sqlite.sqlite3_progress_handler(db, 0, nil, nil)
	stmt: sqlite.Sqlite3_Stmt
	stmt, err = engine_prepare_read(db, sql)
	if budget.exhausted do return 0, .Query_Limit
	if err != .None do return 0, err
	defer sqlite.sqlite3_finalize(stmt)
	for {
		rc := sqlite.sqlite3_step(stmt)
		if budget.exhausted do return rows, .Query_Limit
		if rc == sqlite.DONE do return rows, .None
		if rc != sqlite.ROW do return rows, .Sqlite_Step_Failed
		if rows == MAX_READ_ROWS do return rows, .Query_Limit
		rows += 1
	}
}

engine_prepare :: proc(e: ^Engine, sql: string) -> (sqlite.Sqlite3_Stmt, Error) {
	stmt: sqlite.Sqlite3_Stmt
	// A positive byte count lets SQLite consume a borrowed, non-NUL-terminated slice.
	rc := sqlite.sqlite3_prepare_v2(e.db, cstring(raw_data(sql)), c.int(len(sql)), &stmt, nil)
	engine_capture_error(e)
	if rc != sqlite.OK || stmt == nil {
		if stmt != nil do sqlite.sqlite3_finalize(stmt)
		return nil, .Sqlite_Prepare_Failed
	}
	return stmt, .None
}

@(private)
engine_load_watermark :: proc(e: ^Engine) -> Error {
	ddl := "CREATE TABLE IF NOT EXISTS _sqlodin_state (id INTEGER PRIMARY KEY CHECK(id=1), " +
		"applied INTEGER NOT NULL); INSERT OR IGNORE INTO _sqlodin_state VALUES (1, 0);"
	if !sqlite.exec(e.db, ddl) do return .Sqlite_Exec_Failed
	stmt := engine_prepare(e, "SELECT applied FROM _sqlodin_state WHERE id=1;") or_return
	defer sqlite.sqlite3_finalize(stmt)
	if sqlite.sqlite3_step(stmt) != sqlite.ROW do return .Sqlite_Step_Failed
	e.applied_through = Slot(sqlite.sqlite3_column_int64(stmt, 0))
	update_sql := "UPDATE _sqlodin_state SET applied=? WHERE id=1;"
	e.watermark_stmt = engine_prepare(e, update_sql) or_return
	return .None
}

// Replicated SQL may not escape its enclosing transaction or alter internal metadata.
// Deterministic expressions, triggers and identical replica schemas remain a host contract.
@(private)
engine_sql_authorize :: proc "c" (
	user: rawptr, action: c.int, arg1, arg2, db, trigger: cstring,
) -> c.int {
	context = runtime.default_context()
	policy := cast(^Engine_Authorization)user
	if policy != nil && !policy.restricted do return sqlite.OK
	if policy != nil && policy.deterministic && !engine_policy_action(action, arg1, arg2, db) {
		policy.denied = true
		return 1
	}
	TRANSACTION :: 22
	ATTACH :: 24
	DETACH :: 25
	PRAGMA :: 19
	SAVEPOINT :: 32
	// FTS5 internally queries this read-only pragma while executing mutations.
	if action == PRAGMA && arg1 != nil && arg2 == nil &&
	   strings.equal_fold(string(arg1), "data_version") {
		return sqlite.OK
	}
	if action == TRANSACTION || action == SAVEPOINT || action == ATTACH ||
	   action == DETACH || action == PRAGMA {
		if policy != nil do policy.denied = true
		return 1 // SQLITE_DENY
	}
	if arg1 != nil && mutation_reserved_name(string(arg1)) {
		if policy != nil do policy.denied = true
		return 1
	}
	// Table/index/trigger actions can carry the target table in arg2.
	if arg2 != nil &&
	   mutation_reserved_name(string(arg2)) {
		if policy != nil do policy.denied = true
		return 1
	}
	return sqlite.OK
}

@(private)
engine_apply_raw :: proc(e: ^Engine, sql: string) -> Error {
	good := sqlite.exec(e.db, sql)
	engine_capture_error(e)
	if !good do return .Sqlite_Exec_Failed
	return .None
}
