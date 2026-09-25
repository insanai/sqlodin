package tests

import "core:fmt"
import "core:testing"
import sql "../src"
import db "../src/sqlite"

@(test)
test_catalog_rowids_must_not_become_replicated_application_values :: proc(t: ^testing.T) {
	for shifted in ([2]bool{false, true}) {
		e, err := sql.engine_open(":memory:", 1)
		testing.expect(t, err == .None)
		defer sql.engine_close(&e)
		testing.expect(t, sql.engine_initialize_outcomes(&e))
		// Same final schema and user data, with a different catalog row allocation.
		if shifted do testing.expect(t, sql.engine_exec(&e, "CREATE TABLE discarded(v)") == .None)
		testing.expect(t, sql.engine_exec(&e, "CREATE TABLE catalog_values(v INTEGER)") == .None)
		if shifted do testing.expect(t, sql.engine_exec(&e, "DROP TABLE discarded") == .None)
		testing.expect(t, sql.engine_install_function_policy(&e) == .None)
		m := transaction_test_request(t, 1,
			"INSERT INTO catalog_values SELECT rowid FROM sqlite_schema")
		testing.expect(t, sql.engine_apply_outcome(&e, 1, &m) == .None)
		out, found, out_err := sql.engine_outcome(&e, 1)
		testing.expect(t, found && out_err == .None)
		s, prepared := sql.engine_prepare(&e, "SELECT count(*) FROM catalog_values")
		testing.expect(t, prepared == .None && db.sqlite3_step(s) == db.ROW)
		fmt.printf("catalog allocation shifted=%v outcome=%v copied-rowid-count=%d\n",
			shifted, out.kind, db.sqlite3_column_int64(s, 0))
		db.sqlite3_finalize(s)
		testing.expect_value(t, out.kind, sql.Transaction_Outcome.Policy)
	}
}
