package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import snapshot "../src/snapshot"

@(test)
test_replicated_schema_keeps_hidden_rowids_snapshot_accessible :: proc(t: ^testing.T) {
	for grouped in ([2]bool{false, true}) do schema_snapshot_history(t, grouped)
}

schema_snapshot_history :: proc(t: ^testing.T, grouped: bool) {
	root := snapshot_test_directory(t)
	defer delete(root); defer os.remove_all(root)
	path := fmt.aprintf("%s/schema.db", root)
	defer delete(path)
	e, err := sql.engine_open(path, 1)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_install_function_policy(&e) == .None)
	texts := [?]string{
		"CREATE TABLE ambiguous(rowid,_rowid_,oid)",
		"CREATE TABLE supported(rowid,_rowid_)",
		"ALTER TABLE supported ADD COLUMN oid",
		"CREATE TABLE keyed(rowid TEXT PRIMARY KEY,_rowid_,oid) WITHOUT ROWID",
		"CREATE TABLE transient(rowid,_rowid_,oid); DROP TABLE transient",
		"CREATE TABLE bad(rowid,_rowid_,oid); INSERT INTO supported VALUES(1,2)",
		"CREATE TABLE scratch(v); CREATE TABLE captures(v)",
		"DROP TABLE scratch; INSERT INTO captures SELECT name FROM sqlite_schema",
		"ALTER TABLE captures ADD COLUMN extra; INSERT INTO captures(v) SELECT name FROM sqlite_schema",
		"DROP TABLE scratch",
		"CREATE TABLE prefixed AS SELECT name FROM sqlite_schema",
		"CREATE INDEX more ON captures(v); DROP INDEX more",
	}
	expected := [?]sql.Transaction_Outcome{
		.Policy, .Applied, .Policy, .Applied, .Applied, .Policy,
		.Applied, .Policy, .Policy, .Applied, .Policy, .Applied,
	}
	values: [len(texts)]sql.Mutation
	entries: [len(texts)]sql.Committed(sql.Mutation)
	for text, i in texts {
		values[i], _ = sql.mutation_make_raw_sql(1, 0, text)
		entries[i] = {slot = u64(i+1), value = &values[i]}
	}
	if grouped {
		testing.expect(t, sql.engine_apply_outcomes(&e, entries[:]) == .None)
	} else {
		for entry in entries {
			testing.expect(t, sql.engine_apply_outcome(&e, entry.slot, entry.value) == .None)
		}
	}
	for kind, i in expected {
		out, found, out_err := sql.engine_outcome(&e, u64(i+1))
		testing.expect(t, found && out_err == .None)
		if out.kind != kind do fmt.printf("schema case %d grouped=%v: %s\n", i, grouped, texts[i])
		testing.expect_value(t, out.kind, kind)
	}
	rows, read_err := sql.engine_read_snapshot(&e, "SELECT * FROM supported", u64(len(texts)))
	testing.expect(t, rows == 0 && read_err == .None)
	sql.engine_close(&e)
	_, digest_err := snapshot.logical_digest(path, u64(len(texts)))
	testing.expect_value(t, digest_err, snapshot.Image_Error.None)
}

@(test)
test_legacy_hidden_rowid_schema_requires_explicit_repair_before_open :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root); defer os.remove_all(root)
	path := fmt.aprintf("%s/legacy.db", root)
	defer delete(path)
	e, err := sql.engine_open(path, 1)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_exec(&e,
		"CREATE TABLE legacy(rowid,_rowid_,oid); INSERT INTO legacy VALUES(1,2,3)") == .None)
	testing.expect_value(t, sql.engine_install_function_policy(&e), sql.Error.Invalid_Mutation)
	sql.engine_close(&e)
	// An explicit offline operator repair preserves values and exposes an alias.
	// Policy installation itself never renames a user's columns or drops data.
	e, err = sql.engine_open(path, 1)
	testing.expect(t, err == .None)
	testing.expect(t, sql.engine_exec(&e,
		"ALTER TABLE legacy RENAME COLUMN oid TO application_oid") == .None)
	testing.expect(t, sql.engine_install_function_policy(&e) == .None)
	rows, query_err := sql.engine_read_snapshot(&e,
		"SELECT * FROM legacy WHERE rowid=1 AND _rowid_=2 AND application_oid=3", 0)
	testing.expect(t, rows == 1 && query_err == .None)
}
