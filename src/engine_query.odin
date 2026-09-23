package sqlodin

import "core:c"
import "core:mem"
import "core:strings"
import "core:encoding/base64"
import "core:math"
import "sqlite"

Query_Kind :: enum { Null, Integer, Real, Text, Blob }
Query_Value :: struct { kind: Query_Kind, integer: i64, real: f64, text: string }
Query_Result :: struct { columns: [dynamic]string, rows: [dynamic][]Query_Value }
MAX_RESULT_BYTES :: 256 * 1024
MAX_RESULT_ROWS :: 4096

// Result strings and rows belong to allocator; release with query_result_free.
// Errors return no partial result. Host access and reader use must be serialized.
engine_query :: proc(
	e: ^Engine, text: string, parameters: ^Mutation = nil,
	allocator := context.allocator,
) -> (Query_Result, Error) {
	result: Query_Result
	err: Error
	e.authorization.restricted = true
	defer e.authorization.restricted = false
	db := e.read_db if e.read_db != nil else e.db
	budget := Read_Budget{remaining = MAX_READ_PROGRESS_CALLS}
	sqlite.sqlite3_progress_handler(db, READ_PROGRESS_INTERVAL, engine_read_progress, &budget)
	defer sqlite.sqlite3_progress_handler(db, 0, nil, nil)
	stmt, prepare_err := engine_prepare_read(db, text)
	if prepare_err != .None {
		return {}, .Query_Limit if budget.exhausted else prepare_err
	}
	defer sqlite.sqlite3_finalize(stmt)
	count := int(sqlite.sqlite3_bind_parameter_count(stmt))
	if parameters == nil && count != 0 || parameters != nil && count != int(parameters.col_count) {
		return {}, .Invalid_Mutation
	}
	if parameters != nil && !engine_bind_mutation_cols(stmt, parameters, 1, count) {
		return {}, .Sqlite_Step_Failed
	}
	result.columns = make([dynamic]string, 0, 16, allocator)
	result.rows = make([dynamic][]Query_Value, 0, 16, allocator)
	good := false
	defer if !good { query_result_free(&result, allocator); result = {} }
	used := 0
	columns := int(sqlite.sqlite3_column_count(stmt))
	for i in 0..<columns {
		name := string(sqlite.sqlite3_column_name(stmt, c.int(i)))
		used += len(name) + size_of(string)
		if used > MAX_RESULT_BYTES do return {}, .Query_Limit
		append(&result.columns, strings.clone(name, allocator))
	}
	for {
		rc := sqlite.sqlite3_step(stmt)
		if budget.exhausted do return {}, .Query_Limit
		if rc == sqlite.DONE { good = true; return result, .None }
		if rc != sqlite.ROW do return {}, .Sqlite_Step_Failed
		used += columns * size_of(Query_Value) + size_of([]Query_Value)
		if len(result.rows) == MAX_RESULT_ROWS || used > MAX_RESULT_BYTES {
			return {}, .Query_Limit
		}
		row := make([]Query_Value, columns, allocator)
		append(&result.rows, row)
		for &value, i in row {
			value, err = query_column(stmt, c.int(i), &used, allocator)
			if err != .None do return {}, err
		}
	}
}

@(private)
query_column :: proc(
	s: sqlite.Sqlite3_Stmt, i: c.int, used: ^int, allocator: mem.Allocator,
) -> (v: Query_Value, err: Error) {
	switch sqlite.sqlite3_column_type(s, i) {
	case sqlite.NULL_TYPE: v.kind = .Null
	case sqlite.INTEGER_TYPE: v.kind, v.integer = .Integer, sqlite.sqlite3_column_int64(s, i)
	case sqlite.FLOAT_TYPE:
		v.kind, v.real = .Real, sqlite.sqlite3_column_double(s, i)
		if math.is_nan(v.real) || math.is_inf(v.real) do return {}, .Invalid_Mutation
	case sqlite.TEXT_TYPE, sqlite.BLOB_TYPE:
		n := int(sqlite.sqlite3_column_bytes(s, i))
		used^ += n * 2
		if used^ > MAX_RESULT_BYTES do return {}, .Query_Limit
		p := cast([^]u8)sqlite.sqlite3_column_blob(s, i)
		if sqlite.sqlite3_column_type(s, i) == sqlite.TEXT_TYPE {
			v.kind, v.text = .Text, strings.clone(string(p[:n]), allocator)
		} else {
			v.kind, v.text = .Blob, base64.encode(p[:n], allocator = allocator)
		}
	case: return {}, .Sqlite_Corrupt
	}
	return
}

query_result_free :: proc(result: ^Query_Result, allocator := context.allocator) {
	for name in result.columns do delete(name, allocator)
	for row in result.rows {
		for value in row do if value.text != "" { delete(value.text, allocator) }
		delete(row, allocator)
	}
	delete(result.columns)
	delete(result.rows)
	result^ = {}
}
