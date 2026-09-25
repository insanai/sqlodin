package durable

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"
import db "../sqlite"

Backup_Budget :: struct { started: time.Tick, calls: u64 }

verify_backup :: proc(directory: string) -> (Backup_Manifest, Error) {
	name := strings.clone_to_cstring(directory)
	defer delete(name)
	fd := posix.open(name, {.DIRECTORY, .NOFOLLOW})
	if fd < 0 do return {}, .Storage
	defer posix.close(fd)
	m, valid := backup_read_manifest(fmt.tprintf("%s/backup.manifest", directory))
	if !valid do return {}, .Storage
	if !backup_check_image(fmt.tprintf("%s/application.db", directory), m) do return {}, .Storage
	return m, .None
}

@(private)
backup_check_image :: proc(path: string, m: Backup_Manifest) -> bool {
	budget := Backup_Budget{time.tick_now(), DEFAULT_MAINTENANCE_INSTRUCTIONS/1000}
	for suffix in ([3]string{"-wal", "-journal", "-shm"}) {
		name := strings.clone_to_cstring(fmt.tprintf("%s%s", path, suffix))
		info: posix.stat_t
		absent := posix.lstat(name, &info) != nil && posix.errno() == .ENOENT
		delete(name)
		if !absent do return false
	}
	hash, bytes, valid := backup_file_hash(path, budget.started)
	if !valid || bytes != m.bytes || hash != m.image do return false
	name := strings.clone_to_cstring(path)
	defer delete(name)
	image: db.Sqlite3
	if db.sqlite3_open_v2(name, &image, db.OPEN_READONLY | db.OPEN_NOFOLLOW, nil) != db.OK {
		if image != nil do db.close(image)
		return false
	}
	defer db.close(image)
	if !db.vec_register(image) || !db.exec(image,
		"PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA query_only=ON; BEGIN;") { return false }
	db.sqlite3_progress_handler(image, 1000, backup_progress, &budget)
	defer db.sqlite3_progress_handler(image, 0, nil, nil)
	prefix, prefix_ok := migration_integer(image, "SELECT applied FROM _sqlodin_state WHERE id=1")
	if !prefix_ok || prefix < 0 || u64(prefix) != m.prefix || !backup_identity(image, m) {
		return false
	}
	count, count_ok := migration_integer(image,
		"SELECT count(*) FROM sqlite_schema WHERE type='table' AND name GLOB '_sqlodin_*' " +
		"AND name NOT IN ('_sqlodin_state','_sqlodin_outcomes','_sqlodin_sessions','_sqlodin_tx_revision')")
	if !count_ok || count != 0 do return false
	count, count_ok = migration_integer(image,
		"SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN " +
		"('_sqlodin_state','_sqlodin_outcomes','_sqlodin_sessions','_sqlodin_tx_revision')")
	if !count_ok || count != 4 do return false
	return backup_pragma(image, "PRAGMA integrity_check", true) &&
		backup_pragma(image, "PRAGMA foreign_key_check", false) &&
		time.tick_since(budget.started) < DEFAULT_MAINTENANCE_DURATION
}

@(private)
backup_identity :: proc(image: db.Sqlite3, m: Backup_Manifest) -> bool {
	stmt: db.Sqlite3_Stmt
	query := "SELECT identity FROM _sqlodin_state WHERE id=1"
	if db.sqlite3_prepare_v2(image, cstring(raw_data(query)), -1, &stmt, nil) != db.OK {
		return false
	}
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_step(stmt) != db.ROW || db.sqlite3_column_type(stmt, 0) != db.TEXT_TYPE do return false
	identity := string(db.sqlite3_column_text(stmt, 0))
	return digest(transmute([]u8)identity) == m.configuration && db.sqlite3_step(stmt) == db.DONE
}

@(private)
backup_pragma :: proc(image: db.Sqlite3, query: cstring, integrity: bool) -> bool {
	stmt: db.Sqlite3_Stmt
	if db.sqlite3_prepare_v2(image, query, -1, &stmt, nil) != db.OK do return false
	defer db.sqlite3_finalize(stmt)
	if integrity && (db.sqlite3_step(stmt) != db.ROW ||
		string(db.sqlite3_column_text(stmt, 0)) != "ok") { return false }
	return db.sqlite3_step(stmt) == db.DONE
}

@(private)
backup_progress :: proc "c" (user: rawptr) -> c.int {
	context = runtime.default_context()
	budget := cast(^Backup_Budget)user
	if budget.calls == 0 || time.tick_since(budget.started) >= DEFAULT_MAINTENANCE_DURATION do return 1
	budget.calls -= 1
	return 0
}
