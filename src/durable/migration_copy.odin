package durable

import "core:c"
import "core:time"
import sql ".."
import db "../sqlite"
import snapshot "../snapshot"

@(private)
migration_integer :: proc(database: db.Sqlite3, query: cstring) -> (i64, bool) {
	stmt: db.Sqlite3_Stmt
	if db.sqlite3_prepare_v2(database, query, -1, &stmt, nil) != db.OK do return 0, false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_step(stmt) != db.ROW || db.sqlite3_column_type(stmt, 0) != db.INTEGER_TYPE {
		return 0, false
	}
	value := db.sqlite3_column_int64(stmt, 0)
	return value, db.sqlite3_step(stmt) == db.DONE
}

@(private)
migration_copy_application :: proc(
	source: db.Sqlite3, destination: string, max_bytes: u64, started: time.Tick, seconds: u32,
	checkpoint: proc(Generation_Phase) = nil, backup_checkpoint: proc(Backup_Phase) = nil,
	cancel: ^u32 = nil,
) -> bool {
	page_size, size_ok := migration_integer(source, "PRAGMA page_size")
	pages, pages_ok := migration_integer(source, "PRAGMA page_count")
	if !size_ok || !pages_ok || page_size < 512 || page_size > 65536 || pages < 1 ||
		u64(pages) > max_bytes/u64(page_size) { return false }
	out, opened := db.open(destination)
	if !opened do return false
	defer db.close(out)
	if !db.exec(out, "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA cache_size=-8192;") {
		return false
	}
	backup := db.sqlite3_backup_init(out, "main", source, "main")
	if backup == nil do return false
	defer if backup != nil do db.sqlite3_backup_finish(backup)
	for {
		if snapshot.cancelled(cancel) ||
			time.tick_since(started) >= time.Duration(seconds)*time.Second { return false }
		if backup_checkpoint != nil do backup_checkpoint(.Before_Image_Step)
		if checkpoint != nil do checkpoint(.Before_Application_Step)
		rc := db.sqlite3_backup_step(backup, c.int(1024*1024/page_size))
		if checkpoint != nil do checkpoint(.After_Application_Step)
		if backup_checkpoint != nil do backup_checkpoint(.After_Image_Step)
		if rc == db.DONE do break
		if rc != db.OK do return false
	}
	rc := db.sqlite3_backup_finish(backup)
	backup = nil
	return rc == db.OK
}

@(private)
migration_copy_consensus :: proc(
	old, h: ^Host, cluster: string, id: sql.Node_Id, members: []sql.Node_Id,
	started: time.Tick, seconds: u32,
) -> bool {
	if !db.begin_tx(h.consensus) do return false
	defer db.rollback_tx(h.consensus)
	stmt, prepared := prepare(old, "SELECT seq,kind,slot,data,digest FROM _sqlodin_journal ORDER BY seq")
	if !prepared do return false
	defer db.sqlite3_finalize(stmt)
	for {
		if time.tick_since(started) >= time.Duration(seconds)*time.Second do return false
		rc := db.sqlite3_step(stmt)
		if rc == db.DONE do break
		if rc != db.ROW do return false
		record: Record
		if !decode_row(stmt, &record) || record.seq != h.sequence+1 || record.previous != h.head ||
			!persist_record(h, &record) { return false }
	}
	if h.sequence != old.sequence || h.head != old.head do return false
	ms, valid := migration_integer(old.consensus, "SELECT ms FROM _sqlodin_ids WHERE id=1")
	if !valid || ms < -1 || ms >= i64(1)<<42 do return false
	ids, ok := prepare(h, "UPDATE _sqlodin_ids SET ms=? WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(ids)
	if db.sqlite3_bind_int64(ids, 1, ms) != db.OK || db.sqlite3_step(ids) != db.DONE do return false
	ident := store_identity(h, cluster, id, members)
	defer delete(ident)
	meta, meta_ok := prepare(h, "UPDATE _sqlodin_journal_meta SET identity=?,seq=?,digest=? WHERE id=1")
	if !meta_ok do return false
	defer db.sqlite3_finalize(meta)
	if db.sqlite3_bind_text(meta, 1, cstring(raw_data(ident)), c.int(len(ident)), nil) != db.OK ||
		db.sqlite3_bind_int64(meta, 2, i64(h.sequence)) != db.OK || !bind_blob(meta, 3, h.head[:]) ||
		db.sqlite3_step(meta) != db.DONE || !db.commit_tx(h.consensus) { return false }
	h.durable_sequence = h.sequence
	return true
}
