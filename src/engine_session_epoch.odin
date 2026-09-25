package sqlodin

import "sqlite"

@(private)
SESSION_REVISION_SCHEMA :: "CREATE TABLE _sqlodin_tx_revision(id INTEGER PRIMARY KEY CHECK(id=1)," +
	"version INTEGER NOT NULL,epoch INTEGER NOT NULL CHECK(epoch>=0));"

// A durable scalar fences retired request IDs even after their rows are removed.
engine_session_epoch :: proc(e: ^Engine) -> (epoch: u64, err: Error) {
	s := engine_prepare(e, "SELECT epoch FROM _sqlodin_tx_revision WHERE id=1") or_return
	defer sqlite.sqlite3_finalize(s)
	if sqlite.sqlite3_step(s) != sqlite.ROW || sqlite.sqlite3_column_type(s, 0) != sqlite.INTEGER_TYPE {
		return 0, .Sqlite_Corrupt
	}
	value := sqlite.sqlite3_column_int64(s, 0)
	if value < 0 || sqlite.sqlite3_step(s) != sqlite.DONE do return 0, .Sqlite_Corrupt
	return u64(value), .None
}

mutation_make_session_retirement :: proc(origin: Node_Id, expected_epoch: u64) -> (Mutation, Error) {
	if expected_epoch >= u64(max(i64)) do return {}, .Invalid_Mutation
	return Mutation{kind = .Session_Epoch, origin_node = origin, primary_key = expected_epoch}, .None
}

// Called inside the same application transaction as outcome/revision/watermark.
// Retrying the immediately prior advancement cannot expire the new epoch again.
@(private)
engine_retire_sessions :: proc(e: ^Engine, expected: u64, out: ^Outcome) -> Error {
	current := engine_session_epoch(e) or_return
	if current == expected+1 do return .None
	if current != expected { out.kind = .Conflict; return .None }
	if !sqlite.exec(e.db, "DELETE FROM _sqlodin_sessions; " +
		"UPDATE _sqlodin_tx_revision SET epoch=epoch+1 WHERE id=1;") {
		return .Sqlite_Exec_Failed
	}
	return .None
}

// Explicit migration/restore only, on a private destination. Never called by
// ordinary startup: changing policy identity requires coordinated maintenance.
engine_upgrade_session_epoch :: proc(e: ^Engine) -> Error {
	s := engine_prepare(e, "SELECT count(*),sum(name='epoch'),sum(name IN ('id','version')) FROM " +
		"pragma_table_info('_sqlodin_tx_revision')") or_return
	defer sqlite.sqlite3_finalize(s)
	if sqlite.sqlite3_step(s) != sqlite.ROW do return .Sqlite_Corrupt
	columns, epochs := sqlite.sqlite3_column_int64(s, 0), sqlite.sqlite3_column_int64(s, 1)
	if sqlite.sqlite3_column_int64(s, 2) != 2 do return .Sqlite_Corrupt
	if columns == 3 && epochs == 1 { _, err := engine_session_epoch(e); return err }
	if columns != 2 || epochs != 0 do return .Sqlite_Corrupt
	// Finish the schema reader before changing the private schema.
	if sqlite.sqlite3_step(s) != sqlite.DONE do return .Sqlite_Corrupt
	// Rebuild with the identical canonical schema used by a fresh voter. ALTER
	// ADD COLUMN leaves different schema SQL, which would split logical digests.
	if !sqlite.exec(e.db, "ALTER TABLE _sqlodin_tx_revision RENAME TO _sqlodin_old_revision;" +
		SESSION_REVISION_SCHEMA + "INSERT INTO _sqlodin_tx_revision SELECT id,version,0 " +
		"FROM _sqlodin_old_revision; DROP TABLE _sqlodin_old_revision;") { return .Sqlite_Exec_Failed }
	return .None
}
