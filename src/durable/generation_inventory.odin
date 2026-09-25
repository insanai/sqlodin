package durable

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import db "../sqlite"

// A FULL inventory entry precedes directory creation. Recovery can therefore
// reclaim interrupted private builds without guessing ownership from filenames.
@(private)
create_generation_directory :: proc(h: ^Host, name: string) -> bool {
	if !h.store_guard_owned || h.poisoned || !valid_generation_name(name) do return false
	path := fmt.aprintf("%s/%s", h.store_root, name)
	defer delete(path)
	path_text := strings.clone_to_cstring(path)
	defer delete(path_text)
	info: posix.stat_t
	// The root guard serializes all supported writers. Never adopt a preexisting
	// directory or symlink merely because it has a prospective generation name.
	if posix.lstat(path_text, &info) == nil || posix.errno() != .ENOENT do return false
	catalog, opened := open_catalog(h.store_root, verify = false)
	if !opened do return false
	defer db.close(catalog)
	if !db.begin_tx(catalog) do return false
	defer db.rollback_tx(catalog)
	if !db.exec(catalog, "CREATE TABLE IF NOT EXISTS _sqlodin_generation_inventory(" +
		"name TEXT PRIMARY KEY,digest BLOB NOT NULL)") { return false }
	stmt: db.Sqlite3_Stmt
	query := "INSERT INTO _sqlodin_generation_inventory VALUES(?,?)"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return false
	}
	defer db.sqlite3_finalize(stmt)
	hash := digest(transmute([]u8)name)
	if db.sqlite3_bind_text(stmt, 1, cstring(raw_data(name)), c.int(len(name)), nil) != db.OK ||
		!bind_blob(stmt, 2, hash[:]) || db.sqlite3_step(stmt) != db.DONE || !db.commit_tx(catalog) {
		return false
	}
	return os.make_directory(path, {.Read_User, .Write_User, .Execute_User}) == nil
}

@(private)
retirement_candidate :: proc(catalog: db.Sqlite3, current, previous: string) -> (string, bool) {
	count, valid := migration_integer(catalog,
		"SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_generation_inventory'")
	if !valid do return "", false
	if count == 0 do return "", true
	stmt: db.Sqlite3_Stmt
	query := "SELECT name,digest FROM _sqlodin_generation_inventory WHERE name<>? AND name<>? LIMIT 1"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return "", false
	}
	defer db.sqlite3_finalize(stmt)
	for text, i in ([2]string{current, previous}) {
		pointer := cstring("") if text == "" else cstring(raw_data(text))
		if db.sqlite3_bind_text(stmt, c.int(i+1), pointer, c.int(len(text)), nil) != db.OK {
			return "", false
		}
	}
	rc := db.sqlite3_step(stmt)
	if rc == db.DONE do return "", true
	if rc != db.ROW do return "", false
	name := string(db.sqlite3_column_text(stmt, 0))
	if !valid_generation_name(name) do return "", false
	hash, actual := digest(transmute([]u8)name), column_blob(stmt, 1)
	if len(actual) != len(hash) do return "", false
	for byte, i in actual do if byte != hash[i] { return "", false }
	return strings.clone(name), true
}
