package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import snapshot "../src/snapshot"

@(test)
test_replicated_schema_keeps_hidden_rowids_snapshot_accessible :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root); defer os.remove_all(root)
	path := fmt.aprintf("%s/schema.db", root)
	defer delete(path)
	e, err := sql.engine_open(path, 1)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_install_function_policy(&e) == .None)
	m, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE ambiguous(rowid,_rowid_,oid)")
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &m) == .None)
	out, found, out_err := sql.engine_outcome(&e, 1)
	testing.expect(t, found && out_err == .None)
	testing.expect_value(t, out.kind, sql.Transaction_Outcome.Policy)
	sql.engine_close(&e)
	_, digest_err := snapshot.logical_digest(path, 1)
	testing.expect_value(t, digest_err, snapshot.Image_Error.None)
}
