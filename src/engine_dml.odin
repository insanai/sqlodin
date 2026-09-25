package sqlodin

import "core:c"
import "core:fmt"
import "core:strings"
import "sqlite"

ENGINE_SQL_CAPACITY :: 2048
ENGINE_STATEMENT_CACHE :: #config(SQLODIN_STATEMENT_CACHE, true)
ENGINE_SHAPE_CACHE :: #config(SQLODIN_SHAPE_CACHE, true)

when ENGINE_SHAPE_CACHE {
	Engine_Statement :: struct {
		stmt: sqlite.Sqlite3_Stmt,
		kind: Mutation_Kind,
		table: [MAX_TABLE_NAME_LEN]u8,
		table_len: u8,
		count: u8,
		names: [MAX_MUTATION_COLS][MAX_TABLE_NAME_LEN]u8,
		lengths: [MAX_MUTATION_COLS]u8,
	}
} else {
	Engine_Statement :: struct {
		stmt: sqlite.Sqlite3_Stmt,
		sql: [ENGINE_SQL_CAPACITY]u8,
		len: int,
	}
}

// Cache only the SQL shape; values and their lifetimes stay in the caller's mutation.
@(private)
engine_statement_matches :: proc(entry: ^Engine_Statement, m: ^Mutation) -> bool {
	when ENGINE_SHAPE_CACHE {
		if entry.kind != m.kind || entry.count != m.col_count do return false
		if string(entry.table[:entry.table_len]) != mutation_table_name(m) do return false
		for i in 0..<int(m.col_count) {
			if string(entry.names[i][:entry.lengths[i]]) !=
				string(m.col_names[i][:m.col_name_lens[i]]) {
				return false
			}
		}
		return true
	} else {
		return false
	}
}

// Bind directly from the immutable mutation. The caller clears all bindings before
// returning, so SQLITE_STATIC never outlives the mutation and no text clone is needed.
@(private)
engine_bind_mutation_cols :: proc(
	stmt: sqlite.Sqlite3_Stmt, m: ^Mutation, start_idx: c.int, count: int = -1,
) -> bool {
	bound := int(m.col_count)
	if count >= 0 do bound = min(bound, count)
	for i in 0..<bound {
		idx := start_idx + c.int(i)
		v := &m.col_values[i]
		rc: c.int
		switch v.kind {
		case .Integer: rc = sqlite.sqlite3_bind_int64(stmt, idx, v.int_val)
		case .Real:    rc = sqlite.sqlite3_bind_double(stmt, idx, v.real_val)
		case .Null:    rc = sqlite.sqlite3_bind_null(stmt, idx)
		case .Text:
			rc = sqlite.sqlite3_bind_text(
				stmt, idx, cstring(&v.text_val[0]), c.int(v.text_len), nil)
		case .Vector:
			rc = sqlite.sqlite3_bind_blob(
				stmt, idx, &m.vec_values[v.vec_offset], c.int(v.vec_dim) * 4, nil)
		case:
			return false
		}
		if rc != sqlite.OK do return false
	}
	return true
}

@(private)
engine_dml_sql :: proc(m: ^Mutation, buf: []u8) -> string {
	b := strings.builder_from_slice(buf)
	table := mutation_table_name(m)
	switch m.kind {
	case .Insert:
		fmt.sbprintf(&b, "INSERT OR REPLACE INTO \"%s\" (id", table)
		for i in 0..<int(m.col_count) {
			fmt.sbprintf(&b, ", \"%s\"", string(m.col_names[i][:m.col_name_lens[i]]))
		}
		fmt.sbprint(&b, ") VALUES (?")
		for _ in 0..<int(m.col_count) do fmt.sbprint(&b, ", ?")
		fmt.sbprint(&b, ");")
	case .Update:
		fmt.sbprintf(&b, "UPDATE \"%s\" SET ", table)
		for i in 0..<int(m.col_count) {
			if i > 0 do fmt.sbprint(&b, ", ")
			fmt.sbprintf(&b, "\"%s\"=?", string(m.col_names[i][:m.col_name_lens[i]]))
		}
		fmt.sbprint(&b, " WHERE id=?;")
	case .Delete:
		fmt.sbprintf(&b, "DELETE FROM \"%s\" WHERE id=?;", table)
	case .Skip, .Raw_SQL, .Transaction, .Session_Epoch:
	}
	return strings.to_string(b)
}

@(private)
engine_cached_statement :: proc(
	e: ^Engine, m: ^Mutation,
) -> (result: sqlite.Sqlite3_Stmt, err: Error) {
	when ENGINE_STATEMENT_CACHE && ENGINE_SHAPE_CACHE {
		for &entry in e.statements {
			if entry.stmt != nil && engine_statement_matches(&entry, m) do return entry.stmt, .None
		}
	}
	buf: [ENGINE_SQL_CAPACITY]u8
	sql := engine_dml_sql(m, buf[:])
	when !ENGINE_STATEMENT_CACHE do return engine_prepare(e, sql)
	when !ENGINE_SHAPE_CACHE {
		for &entry in e.statements {
			if entry.stmt != nil && string(entry.sql[:entry.len]) == sql do return entry.stmt, .None
		}
	}
	stmt := engine_prepare(e, sql) or_return
	entry := &e.statements[e.statement_next]
	if entry.stmt != nil do sqlite.sqlite3_finalize(entry.stmt)
	when ENGINE_SHAPE_CACHE {
		entry.kind, entry.count = m.kind, m.col_count
		entry.table, entry.table_len = m.table_name, m.table_len
		entry.names, entry.lengths = m.col_names, m.col_name_lens
	} else {
		copy(entry.sql[:], transmute([]u8)sql)
		entry.len = len(sql)
	}
	entry.stmt = stmt
	e.statement_next = (e.statement_next + 1) % len(e.statements)
	return stmt, .None
}

@(private)
engine_apply_dml :: proc(e: ^Engine, m: ^Mutation) -> Error {
	stmt := engine_cached_statement(e, m) or_return
	defer when !ENGINE_STATEMENT_CACHE do sqlite.sqlite3_finalize(stmt)
	defer sqlite.sqlite3_clear_bindings(stmt)
	defer sqlite.sqlite3_reset(stmt)
	pk_idx: c.int = 1
	col_idx: c.int = 2
	if m.kind == .Update {
		pk_idx = c.int(m.col_count) + 1
		col_idx = 1
	}
	if sqlite.sqlite3_bind_int64(stmt, pk_idx, i64(m.primary_key)) != sqlite.OK {
		return .Sqlite_Step_Failed
	}
	if m.kind != .Delete && !engine_bind_mutation_cols(stmt, m, col_idx) {
		return .Sqlite_Step_Failed
	}
	rc := sqlite.sqlite3_step(stmt)
	engine_capture_error(e)
	if rc == sqlite.CONSTRAINT do return .Sqlite_Constraint_Violation
	if rc != sqlite.DONE do return .Sqlite_Step_Failed
	return .None
}
