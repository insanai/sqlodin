package sqlite

import "core:c"
import "core:fmt"
import "core:strings"

foreign import sqlite_vec "libsqlite_vec.a"

@(default_calling_convention="c")
foreign sqlite_vec {
	sqlite3_vec_init :: proc(db: Sqlite3, pzErrMsg: ^cstring, pApi: rawptr) -> c.int ---
}

// Registers the sqlite-vec extension with a SQLite connection.
vec_register :: proc(db: Sqlite3) -> bool {
	if db == nil do return false
	err_msg: cstring
	rc := sqlite3_vec_init(db, &err_msg, nil)
	return rc == OK
}

// Formats a float32 slice into a sqlite-vec JSON array string: "[0.1,0.2,...]".
vec_format :: proc(vec: []f32, buf: []u8) -> string {
	if len(vec) == 0 do return "[]"
	b := strings.builder_from_slice(buf)
	strings.write_byte(&b, '[')
	for v, i in vec {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%f", v)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// Queries the loaded sqlite-vec extension version.
vec_version :: proc(db: Sqlite3) -> string {
	stmt: Sqlite3_Stmt
	rc := sqlite3_prepare_v2(db, "SELECT vec_version();", -1, &stmt, nil)
	if rc != OK do return ""
	defer sqlite3_finalize(stmt)

	if sqlite3_step(stmt) == ROW {
		txt := sqlite3_column_text(stmt, 0)
		if txt != nil do return string(txt)
	}
	return ""
}
