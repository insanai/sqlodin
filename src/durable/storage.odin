package durable

import "core:c"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

foreign import libc "system:c"
foreign libc {
	@(link_name="flock")
	lock_file :: proc "c" (fd: posix.FD, operation: c.int) -> c.int ---
}

// Caller must retain the directory and database inode; never unlink an active database.
lock_database :: proc(path: string, create: bool) -> (posix.FD, bool) {
	lock_path := fmt.aprintf("%s.lock", path)
	defer delete(lock_path)
	p := strings.clone_to_cstring(lock_path)
	defer delete(p)
	fd := posix.open(p, {.RDWR, .CREAT, .NOFOLLOW}, posix.mode_t{.IRUSR, .IWUSR})
	if fd < 0 do return -1, false
	if lock_file(fd, 2 | 4) != 0 {
		posix.close(fd)
		return -1, false
	}
	name := strings.clone_to_cstring(path)
	defer delete(name)
	flags: posix.O_Flags = {.RDWR, .NOFOLLOW}
	if create do flags |= {.CREAT, .EXCL}
	database := posix.open(name, flags, posix.mode_t{.IRUSR, .IWUSR})
	if database < 0 {
		posix.close(fd)
		return -1, false
	}
	posix.close(database)
	return fd, true
}

sync_directory :: proc(path: string) -> bool {
	directory := filepath.dir(path)
	p := strings.clone_to_cstring(directory)
	defer delete(p)
	fd := posix.open(p, {.DIRECTORY})
	if fd < 0 do return false
	defer posix.close(fd)
	return posix.fsync(fd) == nil
}

prepare :: proc(h: ^Host, text: string) -> (db.Sqlite3_Stmt, bool) {
	s: db.Sqlite3_Stmt
	rc := db.sqlite3_prepare_v2(journal_db(h), cstring(raw_data(text)), c.int(len(text)), &s, nil)
	if rc != db.OK || s == nil {
		if s != nil do db.sqlite3_finalize(s)
		return nil, false
	}
	return s, true
}

bind_blob :: proc(s: db.Sqlite3_Stmt, index: c.int, bytes: []u8) -> bool {
	return db.sqlite3_bind_blob(s, index, raw_data(bytes), c.int(len(bytes)), nil) == db.OK
}

column_blob :: proc(s: db.Sqlite3_Stmt, index: c.int) -> []u8 {
	p := cast([^]u8)db.sqlite3_column_blob(s, index)
	n := int(db.sqlite3_column_bytes(s, index))
	return p[:n]
}

identity :: proc(cluster: string, id: sql.Node_Id, members: []sql.Node_Id,
	policy: int = sql.REPLICATION_POLICY) -> string {
	return fmt.aprintf("sqlodin-journal-v4;sql=4096;policy=%d;vec=%d;cluster=%s;node=%d;" +
		"members=%v;sqlite=%x", policy, sql.MAX_MUTATION_VEC_VALUES, cluster, id, members,
		sql.engine_build_fingerprint())
}

initialize :: proc(h: ^Host, ident: string) -> bool {
	ddl := "CREATE TABLE _sqlodin_journal_meta (id INTEGER PRIMARY KEY CHECK(id=1), " +
		"identity TEXT NOT NULL, seq INTEGER NOT NULL, digest BLOB NOT NULL); " +
		"CREATE TABLE _sqlodin_journal (seq INTEGER PRIMARY KEY, kind INTEGER NOT NULL, " +
		"slot INTEGER NOT NULL, data BLOB NOT NULL, digest BLOB NOT NULL); " +
		"CREATE INDEX _sqlodin_journal_slot ON _sqlodin_journal(kind,slot); " +
		"CREATE TABLE _sqlodin_ids(id INTEGER PRIMARY KEY CHECK(id=1), ms INTEGER NOT NULL); " +
		"INSERT INTO _sqlodin_ids VALUES(1,-1);"
	if !db.begin_tx(journal_db(h)) do return false
	defer db.rollback_tx(journal_db(h))
	if !db.exec(journal_db(h), ddl) || !store_genesis(h) do return false
	s, ok := prepare(h, "INSERT INTO _sqlodin_journal_meta VALUES(1,?,0,zeroblob(32))")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	if db.sqlite3_bind_text(s, 1, cstring(raw_data(ident)), c.int(len(ident)), nil) != db.OK {
		return false
	}
	return db.sqlite3_step(s) == db.DONE &&
		(h.consensus != nil || sql.engine_initialize_outcomes(&h.engine)) &&
		db.commit_tx(journal_db(h))
}

check_identity :: proc(h: ^Host, ident: string) -> bool {
	s, ok := prepare(h, "SELECT identity,seq,digest FROM _sqlodin_journal_meta WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	if db.sqlite3_step(s) != db.ROW do return false
	actual := db.sqlite3_column_text(s, 0)
	if string(actual) != ident do return false
	seq := db.sqlite3_column_int64(s, 1)
	bytes := column_blob(s, 2)
	if seq < 0 || len(bytes) != 32 do return false
	h.sequence = u64(seq)
	h.durable_sequence = h.sequence
	copy(h.head[:], bytes)
	return true
}

check_storage :: proc(h: ^Host) -> bool {
	if !check_database_storage(h.engine.db) do return false
	return h.consensus == nil || check_database_storage(h.consensus)
}

check_database_storage :: proc(database: db.Sqlite3) -> bool {
	if !db.exec(database, "PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON; " +
		"PRAGMA foreign_keys=ON;") { return false }
	wants := [3]string{"wal", "2", "ok"}
	for query, i in ([?]string{
		"PRAGMA journal_mode", "PRAGMA synchronous", "PRAGMA integrity_check",
	}) {
		s: db.Sqlite3_Stmt
		if db.sqlite3_prepare_v2(database, cstring(raw_data(query)), c.int(len(query)), &s, nil) != db.OK {
			if s != nil do db.sqlite3_finalize(s)
			return false
		}
		rc := db.sqlite3_step(s)
		value := string(db.sqlite3_column_text(s, 0))
		good := rc == db.ROW && value == wants[i] && db.sqlite3_step(s) == db.DONE
		db.sqlite3_finalize(s)
		if !good do return false
	}
	return true
}
