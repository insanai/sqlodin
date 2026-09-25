package durable

import "core:c"
import sql ".."
import db "../sqlite"

@(private)
restore_application_identity :: proc(h: ^Host, cluster: string, members: []sql.Node_Id) -> bool {
	if h.engine.applied_through != h.genesis.prefix do return false
	identity := store_identity(h, cluster, 0, members)
	defer delete(identity)
	if !db.begin_tx(h.engine.db) do return false
	defer db.rollback_tx(h.engine.db)
	if sql.engine_upgrade_session_epoch(&h.engine) != .None do return false
	if !db.exec(h.engine.db, "DELETE FROM _sqlodin_outcomes") ||
		!set_application_identity(h, identity) || !db.commit_tx(h.engine.db) { return false }
	h.configuration = digest(transmute([]u8)identity)
	return true
}

@(private)
restore_publish :: proc(h: ^Host, cluster: string, id: sql.Node_Id,
	members: []sql.Node_Id, checkpoint: proc(Restore_Phase)) -> bool {
	identity := store_identity(h, cluster, id, members)
	defer delete(identity)
	if !db.begin_tx(h.consensus) do return false
	defer db.rollback_tx(h.consensus)
	stmt, ok := prepare(h, "UPDATE _sqlodin_journal_meta SET identity=? WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_bind_text(stmt, 1, cstring(raw_data(identity)), c.int(len(identity)), nil) != db.OK ||
		db.sqlite3_step(stmt) != db.DONE || db.sqlite3_changes(h.consensus) != 1 { return false }
	if checkpoint != nil do checkpoint(.Before_Ready_Commit)
	return db.commit_tx(h.consensus)
}
