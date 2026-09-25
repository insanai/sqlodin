package sqlite

import "core:c"
import "core:strings"

// Built from the source/checksum lock by tools/build_native.py on every platform.
foreign import sqlite3 "../../build/native/libsqlite3.a"

Sqlite3      :: distinct rawptr
Sqlite3_Stmt :: distinct rawptr
Sqlite3_Context :: distinct rawptr
Sqlite3_Value :: distinct rawptr
Sqlite3_Backup :: distinct rawptr

OK         :: 0
ERROR      :: 1
INTERNAL   :: 2
PERM       :: 3
ABORT      :: 4
BUSY       :: 5
LOCKED     :: 6
NOMEM      :: 7
READONLY   :: 8
INTERRUPT  :: 9
IOERR      :: 10
CORRUPT    :: 11
NOTFOUND   :: 12
FULL       :: 13
CANTOPEN   :: 14
PROTOCOL   :: 15
EMPTY      :: 16
SCHEMA     :: 17
TOOBIG     :: 18
CONSTRAINT :: 19
MISMATCH   :: 20
MISUSE     :: 21
NOLFS      :: 22
AUTH       :: 23
FORMAT     :: 24
RANGE      :: 25
NOTADB     :: 26
NOTICE     :: 27
WARNING    :: 28
ROW        :: 100
DONE       :: 101

OPEN_READONLY      :: 0x00000001
OPEN_READWRITE     :: 0x00000002
OPEN_CREATE        :: 0x00000004
OPEN_URI           :: 0x00000040
OPEN_MEMORY        :: 0x00000080
OPEN_NOMUTEX       :: 0x00008000
OPEN_FULLMUTEX     :: 0x00010000
OPEN_SHAREDCACHE   :: 0x00020000
OPEN_PRIVATECACHE  :: 0x00040000
OPEN_NOFOLLOW      :: 0x01000000

INTEGER_TYPE :: 1
FLOAT_TYPE   :: 2
TEXT_TYPE    :: 3
BLOB_TYPE    :: 4
NULL_TYPE    :: 5

@(default_calling_convention="c")
foreign sqlite3 {
	sqlite3_backup_init :: proc(destination: Sqlite3, destination_name: cstring,
		source: Sqlite3, source_name: cstring) -> Sqlite3_Backup ---
	sqlite3_backup_step :: proc(backup: Sqlite3_Backup, pages: c.int) -> c.int ---
	sqlite3_backup_finish :: proc(backup: Sqlite3_Backup) -> c.int ---
	sqlite3_db_config :: proc(db: Sqlite3, op: c.int, #c_vararg args: ..any) -> c.int ---
	sqlite3_limit :: proc(db: Sqlite3, id, value: c.int) -> c.int ---
	sqlite3_progress_handler :: proc(
		db: Sqlite3, instructions: c.int, callback: proc "c" (rawptr) -> c.int, user: rawptr,
	) ---
	sqlite3_sourceid :: proc() -> cstring ---
	sqlite3_compileoption_get :: proc(index: c.int) -> cstring ---
	sqlite3_db_status :: proc(db: Sqlite3, op: c.int, current, highwater: ^c.int, reset: c.int) -> c.int ---
	sqlite3_free :: proc(p: rawptr) ---
	sqlite3_open_v2 :: proc(
		filename: cstring,
		ppDb: ^Sqlite3,
		flags: c.int,
		zVfs: cstring,
	) -> c.int ---
	sqlite3_close_v2 :: proc(pDb: Sqlite3) -> c.int ---
	sqlite3_exec :: proc(
		db: Sqlite3,
		sql: cstring,
		callback: rawptr,
		arg: rawptr,
		errmsg: ^cstring,
	) -> c.int ---
	sqlite3_prepare_v2 :: proc(
		db: Sqlite3,
		zSql: cstring,
		nByte: c.int,
		ppStmt: ^Sqlite3_Stmt,
		pzTail: ^cstring,
	) -> c.int ---
	sqlite3_step :: proc(pStmt: Sqlite3_Stmt) -> c.int ---
	sqlite3_finalize :: proc(pStmt: Sqlite3_Stmt) -> c.int ---
	sqlite3_reset :: proc(pStmt: Sqlite3_Stmt) -> c.int ---
	sqlite3_clear_bindings :: proc(pStmt: Sqlite3_Stmt) -> c.int ---
	sqlite3_create_function_v2 :: proc(
		db: Sqlite3, name: cstring, argc, flags: c.int, user: rawptr,
		function: proc "c" (Sqlite3_Context, c.int, ^Sqlite3_Value),
		step, final, destroy: rawptr,
	) -> c.int ---
	sqlite3_user_data :: proc(ctx: Sqlite3_Context) -> rawptr ---
	sqlite3_result_error :: proc(ctx: Sqlite3_Context, message: cstring, length: c.int) ---
	sqlite3_result_error_code :: proc(ctx: Sqlite3_Context, code: c.int) ---
	sqlite3_update_hook :: proc(
		db: Sqlite3, callback: proc "c" (rawptr, c.int, cstring, cstring, i64), user: rawptr,
	) -> rawptr ---
	sqlite3_stmt_readonly :: proc(pStmt: Sqlite3_Stmt) -> c.int ---
	sqlite3_get_autocommit :: proc(db: Sqlite3) -> c.int ---
	sqlite3_set_authorizer :: proc(
		db: Sqlite3,
		callback: proc "c" (rawptr, c.int, cstring, cstring, cstring, cstring) -> c.int,
		user: rawptr,
	) -> c.int ---
	sqlite3_bind_blob :: proc(
		stmt: Sqlite3_Stmt, i: c.int, data: rawptr, n: c.int, destructor: rawptr,
	) -> c.int ---

	sqlite3_bind_int64 :: proc(pStmt: Sqlite3_Stmt, i: c.int, v: i64) -> c.int ---
	sqlite3_bind_double :: proc(pStmt: Sqlite3_Stmt, i: c.int, v: f64) -> c.int ---
	sqlite3_bind_text :: proc(
		pStmt: Sqlite3_Stmt,
		i: c.int,
		z: cstring,
		n: c.int,
		destructor: rawptr,
	) -> c.int ---
	sqlite3_bind_null :: proc(pStmt: Sqlite3_Stmt, i: c.int) -> c.int ---

	sqlite3_column_count :: proc(pStmt: Sqlite3_Stmt) -> c.int ---
	sqlite3_column_type :: proc(pStmt: Sqlite3_Stmt, iCol: c.int) -> c.int ---
	sqlite3_column_name :: proc(pStmt: Sqlite3_Stmt, iCol: c.int) -> cstring ---
	sqlite3_column_int64 :: proc(pStmt: Sqlite3_Stmt, iCol: c.int) -> i64 ---
	sqlite3_column_double :: proc(pStmt: Sqlite3_Stmt, iCol: c.int) -> f64 ---
	sqlite3_column_text :: proc(pStmt: Sqlite3_Stmt, iCol: c.int) -> cstring ---
	sqlite3_column_bytes :: proc(pStmt: Sqlite3_Stmt, iCol: c.int) -> c.int ---
	sqlite3_column_blob :: proc(pStmt: Sqlite3_Stmt, iCol: c.int) -> rawptr ---

	sqlite3_changes :: proc(db: Sqlite3) -> c.int ---
	sqlite3_last_insert_rowid :: proc(db: Sqlite3) -> i64 ---
	sqlite3_extended_errcode :: proc(db: Sqlite3) -> c.int ---
	sqlite3_status64 :: proc(op: c.int, current, highwater: ^i64, reset: c.int) -> c.int ---
	sqlite3_bind_parameter_count :: proc(stmt: Sqlite3_Stmt) -> c.int ---
	sqlite3_total_changes64 :: proc(db: Sqlite3) -> i64 ---
	sqlite3_errmsg :: proc(db: Sqlite3) -> cstring ---
	sqlite3_wal_checkpoint_v2 :: proc(
		db: Sqlite3,
		zDb: cstring,
		eMode: c.int,
		pnLog: ^c.int,
		pnCkpt: ^c.int,
	) -> c.int ---
}

// Opens a SQLite database handle.
open :: proc(path: string, memory: bool = false) -> (Sqlite3, bool) {
	db: Sqlite3
	flags := c.int(OPEN_READWRITE | OPEN_CREATE)
	if memory do flags |= OPEN_MEMORY

	path_cstr := strings.clone_to_cstring(path)
	defer delete(path_cstr)

	rc := sqlite3_open_v2(path_cstr, &db, flags, nil)
	if rc != OK {
		if db != nil do sqlite3_close_v2(db)
		return nil, false
	}
	return db, true
}

close :: proc(db: Sqlite3) -> bool {
	if db == nil do return true
	return sqlite3_close_v2(db) == OK
}

exec :: proc(db: Sqlite3, sql: string) -> bool {
	sql_cstr := strings.clone_to_cstring(sql)
	defer delete(sql_cstr)
	rc := sqlite3_exec(db, sql_cstr, nil, nil, nil)
	return rc == OK
}

enable_wal :: proc(db: Sqlite3) -> bool {
	wal_sql := "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;"
	return exec(db, wal_sql)
}

begin_tx :: proc(db: Sqlite3) -> bool {
	return exec(db, "BEGIN IMMEDIATE;")
}

commit_tx :: proc(db: Sqlite3) -> bool {
	return exec(db, "COMMIT;")
}

rollback_tx :: proc(db: Sqlite3) -> bool {
	return exec(db, "ROLLBACK;")
}

last_error :: proc(db: Sqlite3) -> string {
	msg := sqlite3_errmsg(db)
	if msg == nil do return ""
	return string(msg)
}
