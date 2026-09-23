package sqlodin

import "core:strings"
import "sqlite"

// Replicated function restrictions belong to the writer. A separate read-only
// connection preserves local aggregates/window functions and cannot change state.
// The owner serializes access and reads after checking its committed watermark;
// a new SQLite statement acquires a snapshot no earlier than those completed commits.
engine_open_reader :: proc(e: ^Engine, path: string) -> Error {
	if e.read_db != nil do return .Invalid_Mutation
	name := strings.clone_to_cstring(path)
	defer delete(name)
	db: sqlite.Sqlite3
	if sqlite.sqlite3_open_v2(name, &db, sqlite.OPEN_READONLY, nil) != sqlite.OK {
		if db != nil do sqlite.close(db)
		return .Sqlite_Open_Failed
	}
	reader := Engine{db = db}
	if !sqlite.vec_register(db) || engine_install_limits(&reader) != .None ||
	   sqlite.sqlite3_set_authorizer(db, engine_sql_authorize, e.authorization) != sqlite.OK {
		sqlite.close(db)
		return .Sqlite_Open_Failed
	}
	e.read_db = db
	return .None
}
