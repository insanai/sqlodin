package durable

import "core:c"
import "core:strings"
import sql ".."
import db "../sqlite"

@(private)
image_retirement_candidate :: proc(catalog: db.Sqlite3, current, previous: string,
	sealed: sql.Slot) -> (Image_Inventory, bool, bool) {
	count, valid := migration_integer(catalog,
		"SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_image_inventory'")
	if !valid do return {}, false, false
	if count == 0 do return {}, false, true
	stmt: db.Sqlite3_Stmt
	query := "SELECT name,manifest,directory,prefix,received,digest FROM _sqlodin_image_inventory " +
		"WHERE name<>? AND name<>? AND (received=1 OR prefix<?) LIMIT 1"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return {}, false, false
	}
	defer db.sqlite3_finalize(stmt)
	for value, i in ([2]string{current, previous}) {
		pointer := cstring("") if value == "" else cstring(raw_data(value))
		if db.sqlite3_bind_text(stmt, c.int(i+1), pointer, c.int(len(value)), nil) != db.OK {
			return {}, false, false
		}
	}
	if db.sqlite3_bind_int64(stmt, 3, i64(sealed)) != db.OK do return {}, false, false
	rc := db.sqlite3_step(stmt)
	if rc == db.DONE do return {}, false, true
	if rc != db.ROW do return {}, false, false
	entry := Image_Inventory{name = string(db.sqlite3_column_text(stmt, 0)),
		manifest = string(db.sqlite3_column_text(stmt, 1)),
		directory = string(db.sqlite3_column_text(stmt, 2))}
	prefix, received := db.sqlite3_column_int64(stmt, 3), db.sqlite3_column_int64(stmt, 4)
	if prefix <= 0 || received < 0 || received > 1 ||
		!generation_image_name_valid(entry.name) || !generation_image_name_valid(entry.manifest) ||
		len(entry.directory) == 0 || strings.contains(entry.directory, "\x00") { return {}, false, false }
	entry.prefix, entry.received = sql.Slot(prefix), received == 1
	hash, actual := image_inventory_digest(entry), column_blob(stmt, 5)
	if len(actual) != len(hash) do return {}, false, false
	for byte, i in actual do if byte != hash[i] { return {}, false, false }
	entry.name, entry.manifest, entry.directory = strings.clone(entry.name),
		strings.clone(entry.manifest), strings.clone(entry.directory)
	return entry, true, true
}
