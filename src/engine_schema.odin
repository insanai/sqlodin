package sqlodin

import "core:c"
import "sqlite"

// The logical image certificate binds hidden row identity. A rowid table with
// all three aliases shadowed cannot expose that identity through SQLite's SQL
// interface. Check the final schema inside the request transaction/savepoint;
// rejecting here rolls back its DDL and DML together, before acknowledgement.
// WITHOUT ROWID tables expose their complete identity through ordinary columns.
@(private)
engine_snapshot_schema_supported :: proc(e: ^Engine) -> (bool, Error) {
	query := "SELECT count(*) FROM pragma_table_list AS t WHERE t.schema='main' AND t.wr=0 " +
		"AND t.type IN ('table','shadow','virtual') AND " +
		"(SELECT count(*) FROM pragma_table_xinfo(t.name) " +
		"WHERE lower(name) IN ('rowid','_rowid_','oid'))=3"
	stmt: sqlite.Sqlite3_Stmt
	if sqlite.sqlite3_prepare_v2(e.db, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) !=
	   sqlite.OK {
		if stmt != nil do sqlite.sqlite3_finalize(stmt)
		return false, .Sqlite_Exec_Failed
	}
	defer sqlite.sqlite3_finalize(stmt)
	if sqlite.sqlite3_step(stmt) != sqlite.ROW do return false, .Sqlite_Exec_Failed
	return sqlite.sqlite3_column_int64(stmt, 0) == 0, .None
}
