package sqlodin

import "core:c"
import "base:runtime"
import "core:strings"
import "sqlite"

Engine_Authorization :: struct {
	restricted, deterministic, denied, schema_changed, catalog_maintenance: bool,
}

// This is an enforced function/extension boundary, not a complete proof of SQL
// determinism. Schema, collation and statement-order validation are separate gates.
@(private)
engine_policy_action :: proc(action: c.int, arg1, arg2, database: cstring) -> bool {
	// Temporary state and planner statistics must not enter replicated state.
	if database != nil && string(database) != "main" do return false
	if action >= 3 && action <= 6 do return false
	// SQLite also emits REINDEX while building CREATE INDEX. Index construction
	// is allowed; persistent planner-statistics changes (ANALYZE) are not.
	if action == 19 {
		return arg1 != nil && arg2 == nil && strings.equal_fold(string(arg1), "data_version")
	}
	if action == 28 do return false
	// Recursive CTEs can execute forever; this initial bounded SQL profile does
	// not admit them. A general deterministic execution budget remains separate.
	if action == 33 do return false
	// Application SQL must not edit SQLite's AUTOINCREMENT high-water marks.
	if (action == 9 || action == 18 || action == 23) && arg1 != nil &&
	   strings.equal_fold(string(arg1), "sqlite_sequence") {
		return false
	}
	if action == 20 && arg1 != nil {
		table := string(arg1)
		if len(table) >= 7 && strings.equal_fold(table[:7], "pragma_") do return false
		if (strings.equal_fold(table, "sqlite_master") || strings.equal_fold(table, "sqlite_schema")) &&
		   arg2 != nil &&
		   !strings.equal_fold(string(arg2), "ROWID") {
			return false
		}
	}
	FUNCTION :: 31
	CREATE_VTABLE :: 29
	if action == CREATE_VTABLE {
		return arg2 != nil && strings.equal_fold(string(arg2), "fts5")
	}
	if action != FUNCTION do return true
	return arg2 != nil && engine_policy_function(string(arg2))
}

@(private)
engine_policy_function :: proc(function: string) -> bool {
	for name in ([?]string{
		"abs", "coalesce", "ifnull", "nullif", "length", "lower", "upper",
		"substr", "substring", "trim", "ltrim", "rtrim", "replace", "instr",
		"hex", "unhex", "zeroblob", "unicode", "char", "typeof", "quote", "like", "glob",
		"printf", "format",
		"min", "max", "count", "json", "json_array", "json_object", "json_extract",
		"json_type", "json_valid", "json_array_length", "json_quote", "->", "->>",
	}) {
		if strings.equal_fold(function, name) do return true
	}
	return false
}

@(private)
engine_execute_transaction :: proc(e: ^Engine, m: ^Mutation) -> Error {
	text := mutation_sql(m)
	statements := 0
	for len(text) > 0 {
		e.authorization.catalog_maintenance = false
		stmt: sqlite.Sqlite3_Stmt
		tail: cstring
		rc := sqlite.sqlite3_prepare_v2(e.db, cstring(raw_data(text)), c.int(len(text)),
			&stmt, &tail)
		engine_capture_error(e)
		if rc != sqlite.OK {
			if stmt != nil do sqlite.sqlite3_finalize(stmt)
			return .Sqlite_Prepare_Failed
		}
		consumed := int(uintptr(rawptr(tail)) - uintptr(raw_data(text)))
		if consumed <= 0 || consumed > len(text) {
			if stmt != nil do sqlite.sqlite3_finalize(stmt)
			return .Invalid_Mutation
		}
		text = text[consumed:]
		if stmt == nil do continue
		statements += 1
		if statements > 8 {
			sqlite.sqlite3_finalize(stmt)
			e.authorization.denied = true
			return .Invalid_Mutation
		}
		err := engine_transaction_statement(e, stmt, m)
		sqlite.sqlite3_finalize(stmt)
		if err != .None do return err
	}
	if statements == 0 {
		e.authorization.denied = true
		return .Invalid_Mutation
	}
	return .None
}

@(private)
engine_transaction_statement :: proc(
	e: ^Engine, stmt: sqlite.Sqlite3_Stmt, m: ^Mutation,
) -> Error {
	// The write API acknowledges an outcome, not a result stream. Reject RETURNING
	// before stepping rather than materializing and discarding its rows.
	if sqlite.sqlite3_stmt_readonly(stmt) == 0 && sqlite.sqlite3_column_count(stmt) > 0 {
		e.authorization.denied = true
		return .Invalid_Mutation
	}
	count := sqlite.sqlite3_bind_parameter_count(stmt)
	if (m.kind == .Raw_SQL && count != 0) || count > c.int(m.col_count) {
		e.authorization.denied = true
		return .Invalid_Mutation
	}
	// Each statement binds the prefix of the shared request parameter tuple.
	if !engine_bind_mutation_cols(stmt, m, 1, int(count)) do return .Sqlite_Step_Failed
	for {
		rc := sqlite.sqlite3_step(stmt)
		engine_capture_error(e)
		if rc == sqlite.DONE do return .None
		if rc != sqlite.ROW do return .Sqlite_Step_Failed
	}
}

@(private)
Blocked_Function :: struct { name: cstring, argc: c.int }

// Function callbacks cover uses that the authorizer omits (notably defaults).
// Enumerate SQLite's registered functions at startup, then replace every function
// outside the versioned allowlist. The host owns this connection; later function
// registration or direct local schema mutation is privileged, unsupported use.
engine_install_function_policy :: proc(e: ^Engine) -> Error {
	// Policy 5 permits FTS5, but ordinary SQL must not corrupt its shadow tables.
	defensive: c.int
	if sqlite.sqlite3_db_config(e.db, 1010, c.int(1), &defensive) != sqlite.OK || defensive != 1 {
		return .Sqlite_Open_Failed
	}
	functions := make([dynamic]Blocked_Function)
	defer {
		for fn in functions do delete(fn.name)
		delete(functions)
	}
	s := engine_prepare(e, "PRAGMA function_list") or_return
	good := false
	for len(functions) <= 2048 {
		rc := sqlite.sqlite3_step(s)
		if rc == sqlite.DONE { good = true; break }
		if rc != sqlite.ROW do break
		name := string(sqlite.sqlite3_column_text(s, 0))
		if engine_policy_function(name) do continue
		fn := Blocked_Function{strings.clone_to_cstring(name),
			max(c.int(-1), c.int(sqlite.sqlite3_column_int64(s, 4)))}
		if _, err := append(&functions, fn); err != nil {
			delete(fn.name)
			break
		}
	}
	sqlite.sqlite3_finalize(s)
	if !good do return .Sqlite_Prepare_Failed
	for fn in functions {
		if sqlite.sqlite3_create_function_v2(e.db, fn.name, fn.argc, 1, e.authorization,
			engine_denied_function, nil, nil, nil) != sqlite.OK {
			return .Sqlite_Prepare_Failed
		}
	}
	sqlite.sqlite3_update_hook(e.db, engine_policy_rowid, e.authorization)
	supported, schema_err := engine_snapshot_schema_supported(e)
	if schema_err != .None do return schema_err
	if !supported do return .Invalid_Mutation
	return .None
}

// SQLite uses random rowids after INT64_MAX. Prevent that state from being
// committed, including writes reached through triggers. This callback only sets
// host state; it never changes the SQLite connection from inside an update hook.
@(private)
engine_policy_rowid :: proc "c" (
	user: rawptr, operation: c.int, database, table: cstring, rowid: i64,
) {
	context = runtime.default_context()
	policy := cast(^Engine_Authorization)user
	if policy != nil && policy.restricted && policy.deterministic &&
	   operation != 9 && rowid == max(i64) {
		policy.denied = true
	}
}

@(private)
engine_denied_function :: proc "c" (
	ctx: sqlite.Sqlite3_Context, argc: c.int, argv: ^sqlite.Sqlite3_Value,
) {
	context = runtime.default_context()
	policy := cast(^Engine_Authorization)sqlite.sqlite3_user_data(ctx)
	if policy != nil do policy.denied = true
	sqlite.sqlite3_result_error(ctx, "SQLodin function policy rejected this expression", -1)
}
