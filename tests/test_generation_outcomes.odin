package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import durable "../src/durable"
import snapshot "../src/snapshot"
import db "../src/sqlite"

@(test)
test_logical_snapshot_normalizes_retired_outcomes_but_binds_retry_results :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	path := fmt.aprintf("%s/application.db", dir)
	defer delete(path)
	e, err := sql.engine_open(path, 1)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	create, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &create) == .None)
	request := sql.Request_Id{sequence = 1}
	request.session[0] = 1
	value, _ := sql.mutation_make_transaction(1, request, "INSERT INTO t VALUES(7)")
	testing.expect(t, sql.engine_apply_outcome(&e, 2, &value) == .None)
	before, before_err := snapshot.logical_digest(path, 2)
	testing.expect(t, before_err == .None)
	// Voters at the same SQL prefix may have compacted at different earlier
	// prefixes. Their disposable per-slot caches cannot split a certificate.
	testing.expect(t, db.exec(e.db, "DELETE FROM _sqlodin_outcomes WHERE slot=1"))
	partial, partial_err := snapshot.logical_digest(path, 2)
	testing.expect(t, partial_err == .None && partial == before)
	testing.expect(t, db.exec(e.db, "DELETE FROM _sqlodin_outcomes"))
	after, after_err := snapshot.logical_digest(path, 2)
	testing.expect(t, after_err == .None && after == before)
	testing.expect(t, db.exec(e.db, "UPDATE _sqlodin_sessions SET changes=changes+1"))
	changed, changed_err := snapshot.logical_digest(path, 2)
	testing.expect(t, changed_err == .None && changed != before)
}

@(test)
test_generation_trims_outcome_cache_and_preserves_rejected_request_after_restart :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(root, "test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	create, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v INTEGER UNIQUE)")
	_, err = durable.propose(h, create)
	testing.expect(t, err == .None)
	request := sql.Request_Id{sequence = 1}
	request.session[0] = 1
	value, _ := sql.mutation_make_transaction(1, request, "INSERT INTO t VALUES(7)")
	first, first_err := durable.propose(h, value)
	testing.expect(t, first_err == .None && durable.acknowledged(h, first, &value))
	value.request.sequence = 2
	rejected, reject_err := durable.propose(h, value)
	out, complete, out_err := durable.outcome(h, rejected, &value)
	testing.expect(t, reject_err == .None && out_err == .None && complete && out.kind == .Constraint)
	version, version_err := sql.engine_read_version(&h.engine)
	testing.expect(t, version_err == .None)
	images := fmt.aprintf("%s/images", root)
	defer delete(images)
	generation_test_snapshot(t, h, images)
	next, compact_err := durable.compact_store(h, "test")
	testing.expect(t, compact_err == .None)
	if next == nil do return
	durable.close(h)
	h = next
	_, found, missing_err := sql.engine_outcome(&h.engine, rejected)
	testing.expect(t, missing_err == .None && !found)
	durable.close(h)
	h, err = durable.open_store(root, "test", 1, ids[:])
	testing.expect(t, err == .None)
	if h == nil do return
	retry, retry_err := durable.propose(h, value)
	out, complete, out_err = durable.outcome(h, retry, &value)
	testing.expect(t, retry_err == .None && out_err == .None && complete && out.kind == .Constraint)
	current, current_err := sql.engine_read_version(&h.engine)
	testing.expect(t, current_err == .None && current == version)
	expect_rows(t, &h.engine, "SELECT * FROM t", 1)
}
