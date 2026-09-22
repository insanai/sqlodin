package sqlodin

import "core:c"
import "core:fmt"
import "core:strings"
import "sqlite"

Engine :: struct {
	db:              sqlite.Sqlite3,
	applied_through: Slot,
	snowflake_seq:   u16,
	node_id:         Node_Id,
	in_memory:       bool,
	vec_enabled:     bool,
}

engine_open :: proc(
	path: string,
	node_id: Node_Id,
	memory: bool = false,
) -> (Engine, Error) {
	db, ok := sqlite.open(path, memory)
	if !ok do return {}, .Sqlite_Open_Failed

	if !memory {
		if !sqlite.enable_wal(db) {
			sqlite.close(db)
			return {}, .Sqlite_Open_Failed
		}
	}

	vec_ok := sqlite.vec_register(db)

	return Engine{
		db = db,
		applied_through = 0,
		snowflake_seq = 0,
		node_id = node_id,
		in_memory = memory,
		vec_enabled = vec_ok,
	}, .None
}

engine_close :: proc(e: ^Engine) {
	if e.db != nil {
		sqlite.close(e.db)
		e.db = nil
	}
}

engine_applied_through :: #force_inline proc(e: ^Engine) -> Slot {
	return e.applied_through
}

// Generates next Snowflake primary key for local inserts.
engine_next_id :: proc(e: ^Engine, timestamp_ms: u64) -> u64 {
	return snowflake_generate(e.node_id, timestamp_ms, &e.snowflake_seq)
}

// Executes raw DDL/SQL directly on the engine.
engine_exec :: proc(e: ^Engine, sql: string) -> Error {
	if !sqlite.exec(e.db, sql) do return .Sqlite_Exec_Failed
	return .None
}

// Binds column values to an active prepared statement.
engine_bind_mutation_cols :: proc(
	stmt: sqlite.Sqlite3_Stmt,
	m: ^Mutation,
	start_idx: c.int,
) -> bool {
	for i in 0..<int(m.col_count) {
		col_idx := start_idx + c.int(i)
		val := &m.col_values[i]
		#partial switch val.kind {
		case .Integer:
			sqlite.sqlite3_bind_int64(stmt, col_idx, val.int_val)
		case .Real:
			sqlite.sqlite3_bind_double(stmt, col_idx, val.real_val)
		case .Text:
			txt_str := strings.clone_to_cstring(string(val.text_val[:val.text_len]))
			defer delete(txt_str)
			sqlite.sqlite3_bind_text(stmt, col_idx, txt_str, -1, nil)
		case .Null:
			sqlite.sqlite3_bind_null(stmt, col_idx)
		case:
			sqlite.sqlite3_bind_null(stmt, col_idx)
		}
	}
	return true
}

engine_apply_insert :: proc(e: ^Engine, m: ^Mutation) -> Error {
	table := mutation_table_name(m)
	sql_buf: [1024]u8
	b := strings.builder_from_slice(sql_buf[:])
	fmt.sbprintf(&b, "INSERT OR REPLACE INTO %s (id", table)
	for i in 0..<int(m.col_count) {
		col_name := string(m.col_names[i][:m.col_name_lens[i]])
		fmt.sbprintf(&b, ", %s", col_name)
	}
	fmt.sbprint(&b, ") VALUES (?")
	for _ in 0..<int(m.col_count) {
		fmt.sbprint(&b, ", ?")
	}
	fmt.sbprint(&b, ");")
	insert_sql := strings.to_string(b)

	sql_cstr := strings.clone_to_cstring(insert_sql)
	defer delete(sql_cstr)

	stmt: sqlite.Sqlite3_Stmt
	rc := sqlite.sqlite3_prepare_v2(e.db, sql_cstr, -1, &stmt, nil)
	if rc != sqlite.OK do return .Sqlite_Prepare_Failed
	defer sqlite.sqlite3_finalize(stmt)

	sqlite.sqlite3_bind_int64(stmt, 1, i64(m.primary_key))
	engine_bind_mutation_cols(stmt, m, 2)

	if sqlite.sqlite3_step(stmt) != sqlite.DONE {
		return .Sqlite_Step_Failed
	}
	return .None
}

engine_apply_delete :: proc(e: ^Engine, m: ^Mutation) -> Error {
	table := mutation_table_name(m)
	del_sql := fmt.tprintf("DELETE FROM %s WHERE id = ?;", table)
	sql_cstr := strings.clone_to_cstring(del_sql)
	defer delete(sql_cstr)

	stmt: sqlite.Sqlite3_Stmt
	rc := sqlite.sqlite3_prepare_v2(e.db, sql_cstr, -1, &stmt, nil)
	if rc != sqlite.OK do return .Sqlite_Prepare_Failed
	defer sqlite.sqlite3_finalize(stmt)

	sqlite.sqlite3_bind_int64(stmt, 1, i64(m.primary_key))
	sqlite.sqlite3_step(stmt)
	return .None
}

// Applies one decided slot mutation to the SQLite database.
engine_apply_slot :: proc(e: ^Engine, slot: Slot, m: ^Mutation) -> Error {
	if slot != e.applied_through + 1 {
		return .None
	}

	sqlite.begin_tx(e.db)
	defer sqlite.commit_tx(e.db)

	#partial switch m.kind {
	case .Insert:
		engine_apply_insert(e, m) or_return
	case .Delete:
		engine_apply_delete(e, m) or_return
	case .Raw_SQL:
		sql_str := mutation_sql(m)
		if !sqlite.exec(e.db, sql_str) do return .Sqlite_Exec_Failed
	case .Skip:
		// No-op skip slot
	}

	e.applied_through = slot
	return .None
}

// Monotonic read: executes query if local applied state satisfies minimum watermark.
engine_read_snapshot :: proc(
	e: ^Engine,
	sql: string,
	min_watermark: Slot = 0,
) -> (rows: int, err: Error) {
	if e.applied_through < min_watermark {
		return 0, .Stale_Watermark
	}
	sql_cstr := strings.clone_to_cstring(sql)
	defer delete(sql_cstr)

	stmt: sqlite.Sqlite3_Stmt
	rc := sqlite.sqlite3_prepare_v2(e.db, sql_cstr, -1, &stmt, nil)
	if rc != sqlite.OK do return 0, .Sqlite_Prepare_Failed
	defer sqlite.sqlite3_finalize(stmt)

	for sqlite.sqlite3_step(stmt) == sqlite.ROW {
		rows += 1
	}
	return rows, .None
}
