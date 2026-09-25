package durable

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

// The root consensus database is also the durable generation catalog. Its FULL
// transaction publishes exactly one complete generation, avoiding a second
// filesystem-pointer atomicity protocol. No generation is deleted by publication.
open_store :: proc(directory, cluster: string, id: sql.Node_Id, members: []sql.Node_Id,
	create: bool = false) -> (^Host, Error) {
	root, path_err := os.get_absolute_path(directory, context.allocator)
	if path_err != nil do return nil, .Storage
	defer delete(root)
	guard := fmt.aprintf("%s/store.lock", root)
	defer delete(guard)
	name := strings.clone_to_cstring(guard)
	defer delete(name)
	fd := posix.open(name, {.RDWR, .CREAT, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if fd < 0 do return nil, .Storage
	owned := true
	defer if owned do posix.close(fd)
	if lock_file(fd, 2 | 4) != 0 do return nil, .Locked
	generation := ""
	if !create {
		catalog, ok := open_catalog(root)
		if !ok do return nil, .Storage
		valid: bool
		generation, valid = read_generation(catalog, cluster, id, members)
		db.close(catalog)
		if !valid do return nil, .Storage
	}
	defer delete(generation)
	base := root if generation == "" else fmt.tprintf("%s/%s", root, generation)
	application := fmt.aprintf("%s/node.db", base)
	consensus := fmt.aprintf("%s/consensus.db", base)
	defer delete(application)
	defer delete(consensus)
	h, err := open(application, cluster, id, members, create, consensus)
	if err != .None do return nil, err
	expected := fmt.tprintf("generation-%d-", h.generation_base.key.prefix)
	if generation != "" && !strings.has_prefix(generation, expected) {
		close(h)
		return nil, .Storage
	}
	h.store_root = strings.clone(root)
	h.store_current = strings.clone(generation)
	h.store_guard, h.store_guard_owned = fd, true
	owned = false
	return h, .None
}

@(private)
open_catalog :: proc(root: string, verify: bool = true) -> (db.Sqlite3, bool) {
	path := fmt.aprintf("%s/consensus.db", root)
	defer delete(path)
	name := strings.clone_to_cstring(path)
	defer delete(name)
	catalog: db.Sqlite3
	if db.sqlite3_open_v2(name, &catalog, db.OPEN_READWRITE | db.OPEN_NOFOLLOW, nil) != db.OK {
		if catalog != nil do db.close(catalog)
		return nil, false
	}
	if !db.enable_wal(catalog) || verify && !check_database_storage(catalog) {
		db.close(catalog)
		return nil, false
	}
	return catalog, true
}

@(private)
generation_redirected :: proc(h: ^Host) -> bool {
	count, ok := migration_integer(journal_db(h),
		"SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_current_generation'")
	return !ok || count != 0
}

@(private)
read_generation :: proc(catalog: db.Sqlite3, cluster: string, id: sql.Node_Id,
	members: []sql.Node_Id) -> (string, bool) {
	h := new(Host)
	defer free(h)
	h.consensus = catalog
	if !load_genesis(h, cluster) do return "", false
	// A generation directory is never a new store root. Otherwise retargeting a
	// config at a retained predecessor could reopen a voter with stale promises.
	bases, valid := migration_integer(catalog,
		"SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_generation_base'")
	if !valid || bases != 0 do return "", false
	ident := store_identity(h, cluster, id, members)
	defer delete(ident)
	redirected := generation_redirected(h)
	want := ident if !redirected else fmt.tprintf("sqlodin-generation-catalog-v1;%s", ident)
	if !check_identity(h, want) do return "", false
	if !redirected do return "", true
	stmt, ok := prepare(h, "SELECT name,digest FROM _sqlodin_current_generation WHERE id=1")
	if !ok do return "", false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_step(stmt) != db.ROW do return "", false
	name := string(db.sqlite3_column_text(stmt, 0))
	if !valid_generation_name(name) do return "", false
	expected := digest(transmute([]u8)name)
	actual := column_blob(stmt, 1)
	if len(actual) != len(expected) do return "", false
	for byte, i in actual do if byte != expected[i] { return "", false }
	result := strings.clone(name)
	if db.sqlite3_step(stmt) != db.DONE { delete(result); return "", false }
	return result, true
}

valid_generation_name :: proc(name: string) -> bool {
	if !strings.has_prefix(name, "generation-") || len(name) < 12 || len(name) > 64 do return false
	separator := false
	for ch, i in name[len("generation-"):] {
		if ch == '-' {
			if separator || i == 0 || i == len(name)-len("generation-")-1 do return false
			separator = true
		} else if ch < '0' || ch > '9' { return false }
	}
	if !separator do return false
	return true
}

@(private)
write_generation :: proc(catalog: db.Sqlite3, name: string,
	checkpoint: proc(Generation_Phase)) -> bool {
	if !valid_generation_name(name) || !db.begin_tx(catalog) do return false
	defer db.rollback_tx(catalog)
	if !db.exec(catalog, "UPDATE _sqlodin_journal_meta SET identity=" +
		"'sqlodin-generation-catalog-v1;'||identity WHERE id=1 AND " +
		"identity NOT LIKE 'sqlodin-generation-catalog-v1;%'; " +
		"CREATE TABLE IF NOT EXISTS _sqlodin_current_generation(" +
		"id INTEGER PRIMARY KEY CHECK(id=1),name TEXT NOT NULL,digest BLOB NOT NULL)") { return false }
	stmt: db.Sqlite3_Stmt
	query := "INSERT OR REPLACE INTO _sqlodin_current_generation VALUES(1,?,?)"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return false
	}
	defer db.sqlite3_finalize(stmt)
	hash := digest(transmute([]u8)name)
	if !bind_blob(stmt, 2, hash[:]) ||
		db.sqlite3_bind_text(stmt, 1, cstring(raw_data(name)), c.int(len(name)), nil) != db.OK ||
		db.sqlite3_step(stmt) != db.DONE { return false }
	if checkpoint != nil do checkpoint(.Before_Catalog_Commit)
	return db.commit_tx(catalog)
}
