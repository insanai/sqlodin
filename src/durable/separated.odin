package durable

import "core:c"
import "core:fmt"
import "core:strings"
import sql ".."
import db "../sqlite"

journal_db :: proc(h: ^Host) -> db.Sqlite3 {
	return h.consensus if h.consensus != nil else h.engine.db
}

// Format 4 co-locates no-op application outcomes with the journal. Format 5
// commits only consensus here: finish applies the chosen prefix afterwards.
// The extra barrier is intentional until a separately verified optimization exists.
stage_journal_skips :: proc(h: ^Host, entries: []sql.Committed(sql.Mutation)) -> (sql.Slot, sql.Error) {
	if h.consensus != nil do return h.engine.applied_through, .None
	return sql.engine_stage_skip_prefix(&h.engine, entries)
}

@(private)
open_consensus :: proc(h: ^Host, path: string, create: bool) -> bool {
	if path == "" || path == ":memory:" || strings.has_prefix(path, "file:") ||
		strings.contains(path, "\x00") { return false }
	fd, locked := lock_database(path, create)
	if !locked do return false
	h.consensus_lock = fd
	h.consensus_path = strings.clone(path)
	opened: bool
	h.consensus, opened = db.open(path)
	return opened && db.enable_wal(h.consensus) &&
		db.exec(h.consensus, "PRAGMA cache_size=-2048; PRAGMA cache_spill=ON;")
}

@(private)
store_identity :: proc(h: ^Host, cluster: string, id: sql.Node_Id, members: []sql.Node_Id) -> string {
	legacy := identity(cluster, id, members)
	if h.consensus == nil do return legacy
	defer delete(legacy)
	identity := fmt.aprintf("sqlodin-separated-v5;%s", legacy)
	if h.genesis_hash == ([32]u8{}) do return identity
	defer delete(identity)
	return genesis_identity(h, identity)
}

// Exportable application identity has no voter ID. Every voter in this fixed
// configuration must produce the same logical image for the same applied prefix.
// Consensus identity, promises and ID reservations remain exclusively local.
@(private)
application_identity :: proc(h: ^Host, cluster: string, members: []sql.Node_Id, create: bool) -> bool {
	if h.consensus == nil do return true
	ident := store_identity(h, cluster, 0, members)
	defer delete(ident)
	if create {
		if !db.begin_tx(h.engine.db) do return false
		defer db.rollback_tx(h.engine.db)
		if !sql.engine_initialize_outcomes(&h.engine) || !db.exec(h.engine.db,
			"ALTER TABLE _sqlodin_state ADD COLUMN identity TEXT NOT NULL DEFAULT '';") { return false }
		if !set_application_identity(h, ident) || !db.commit_tx(h.engine.db) do return false
	}
	stmt, err := sql.engine_prepare(&h.engine, "SELECT identity FROM _sqlodin_state WHERE id=1")
	if err != .None do return false
	defer db.sqlite3_finalize(stmt)
	return db.sqlite3_step(stmt) == db.ROW && string(db.sqlite3_column_text(stmt, 0)) == ident &&
		db.sqlite3_step(stmt) == db.DONE
}

@(private)
set_application_identity :: proc(h: ^Host, ident: string) -> bool {
	stmt, err := sql.engine_prepare(&h.engine, "UPDATE _sqlodin_state SET identity=? WHERE id=1")
	if err != .None do return false
	defer db.sqlite3_finalize(stmt)
	return db.sqlite3_bind_text(stmt, 1, cstring(raw_data(ident)), c.int(len(ident)), nil) == db.OK &&
		db.sqlite3_step(stmt) == db.DONE && db.sqlite3_changes(h.engine.db) == 1
}
