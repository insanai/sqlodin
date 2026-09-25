package durable

import "core:c"
import "core:crypto/sha2"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

Image_Inventory :: struct {
	name, manifest, directory: string,
	prefix: sql.Slot,
	received: bool,
}

// Managed store roots journal ownership before any image/manifest is created.
// Standalone hosts leave file ownership with their embedding caller.
register_snapshot_image :: proc(h: ^Host, image, manifest: string,
	prefix: sql.Slot, received: bool = false) -> Error {
	if h.poisoned do return .Poisoned
	if !h.store_guard_owned do return .None
	if h.snapshot == nil || prefix == 0 || prefix > u64(max(i64)) ||
		filepath.dir(image) != h.snapshot.directory || filepath.dir(manifest) != h.snapshot.directory {
		return .Invalid
	}
	entry := Image_Inventory{filepath.base(image), filepath.base(manifest), h.snapshot.directory,
		prefix, received}
	if !generation_image_name_valid(entry.name) || !generation_image_name_valid(entry.manifest) {
		return .Invalid
	}
	for path in ([2]string{image, manifest}) {
		name := strings.clone_to_cstring(path)
		info: posix.stat_t
		available := posix.lstat(name, &info) != nil && posix.errno() == .ENOENT
		delete(name)
		if !available do return .Storage
	}
	catalog, opened := open_catalog(h.store_root, verify = false)
	if !opened do return .Storage
	defer db.close(catalog)
	if !db.begin_tx(catalog) do return .Storage
	defer db.rollback_tx(catalog)
	if !db.exec(catalog, "CREATE TABLE IF NOT EXISTS _sqlodin_image_inventory(" +
		"name TEXT PRIMARY KEY,manifest TEXT NOT NULL,directory TEXT NOT NULL," +
		"prefix INTEGER NOT NULL,received INTEGER NOT NULL,digest BLOB NOT NULL)") { return .Storage }
	stmt: db.Sqlite3_Stmt
	query := "INSERT INTO _sqlodin_image_inventory VALUES(?,?,?,?,?,?)"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return .Storage
	}
	defer db.sqlite3_finalize(stmt)
	for value, i in ([3]string{entry.name, entry.manifest, entry.directory}) {
		if db.sqlite3_bind_text(stmt, c.int(i+1), cstring(raw_data(value)),
			c.int(len(value)), nil) != db.OK {
			return .Storage
		}
	}
	hash := image_inventory_digest(entry)
	if db.sqlite3_bind_int64(stmt, 4, i64(prefix)) != db.OK ||
		db.sqlite3_bind_int64(stmt, 5, i64(received)) != db.OK || !bind_blob(stmt, 6, hash[:]) ||
		db.sqlite3_step(stmt) != db.DONE || !db.commit_tx(catalog) { return .Storage }
	return .None
}

@(private)
image_inventory_digest :: proc(entry: Image_Inventory) -> (result: [32]u8) {
	h: sha2.Context_256
	sha2.init_256(&h)
	bytes: [9]u8
	for i in 0..<8 do bytes[i] = u8(entry.prefix >> uint(8*i))
	bytes[8] = u8(entry.received)
	sha2.update(&h, bytes[:])
	for value in ([3]string{entry.name, entry.manifest, entry.directory}) {
		sha2.update(&h, transmute([]u8)value)
		sha2.update(&h, []u8{0})
	}
	sha2.final(&h, result[:])
	return
}
