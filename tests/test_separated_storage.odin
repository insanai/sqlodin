package tests

import "core:testing"
import "core:os"
import sql "../src"
import durable "../src/durable"
import snapshot "../src/snapshot"
import db "../src/sqlite"

@(test)
test_separated_store_journal_application_crash_boundary :: proc(t: ^testing.T) {
	for fault in ([3]durable.Fault{
		.Before_Journal_Commit, .After_Journal_Commit, .After_Application_Commit,
	}) {
		c := durable_test_open(t, 1, separated = true)
		h := c.hosts[0]
		m, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE recovered(id PRIMARY KEY);")
		h.fault = fault
		slot, err := durable.propose(h, m)
		testing.expect(t, err == .Storage && h.poisoned)
		testing.expect(t, !durable.acknowledged(h, slot, &m))
		p: durable.Packet
		testing.expect(t, !durable.pop(h, &p))
		if fault == .After_Journal_Commit {
			// The separate application store cannot have crossed its barrier yet.
			testing.expect(t, h.engine.applied_through == 0 && h.durable_sequence > 0)
		}
		durable_test_reopen(t, c, 0, 1)
		want := sql.Slot(0) if fault == .Before_Journal_Commit else 1
		testing.expect_value(t, c.hosts[0].engine.applied_through, want)
		if want == 1 do expect_rows(t, &c.hosts[0].engine, "SELECT * FROM recovered;", 0)
		durable_test_close(c)
	}
}

@(test)
test_separated_store_group_recovery_and_exportable_application :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, separated = true)
	defer durable_test_close(c)
	packets: [16]durable.Packet
	transition_group_packets(t, packets[:])
	c.hosts[1].fault = .After_Journal_Commit
	testing.expect(t, durable.step_batch(c.hosts[1], packets[:]) == .Storage)
	testing.expect(t, c.hosts[1].engine.applied_through == 0)
	durable_test_reopen(t, c, 1, 3)
	h := c.hosts[1]
	want := 16 if durable.JOURNAL_GROUP_COMMIT else 1
	testing.expect_value(t, h.engine.applied_through, sql.Slot(want))
	expect_rows(t, &h.engine, "SELECT * FROM t;", want-1)
	// A retry after replay returns its original outcome without a second INSERT.
	if want == 16 {
		old, complete, err := sql.engine_outcome(&h.engine, 16)
		testing.expect(t, complete && err == .None)
		retry := durable.Packet{value = packets[15].value}
		retry.env = {from = 1, to = 2, message = sql.Commit_Message(sql.Mutation){17, &retry.value}}
		testing.expect(t, durable.step(h, durable.envelope(&retry)) == .None)
		again, found, read_err := sql.engine_outcome(&h.engine, 17)
		testing.expect(t, found && read_err == .None && again == old)
		expect_rows(t, &h.engine, "SELECT * FROM t;", 15)
	}
	path, path_err := os.get_absolute_path(c.paths[1], context.allocator)
	defer delete(path)
	testing.expect(t, path_err == nil)
	_, hash_err := snapshot.logical_digest(path, h.engine.applied_through)
	testing.expect_value(t, hash_err, snapshot.Image_Error.None)
	// Acceptor state lives only in the local consensus database.
	stmt, prepare_err := sql.engine_prepare(&h.engine,
		"SELECT name FROM sqlite_schema WHERE name IN ('_sqlodin_journal','_sqlodin_ids')")
	testing.expect(t, prepare_err == .None)
	defer db.sqlite3_finalize(stmt)
	testing.expect(t, db.sqlite3_step(stmt) == db.DONE)
}

@(test)
test_separated_store_identity_and_reserved_ids :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1, separated = true)
	defer durable_test_close(c)
	id, err := durable.next_id(c.hosts[0], 100)
	testing.expect(t, err == .None)
	durable_test_reopen(t, c, 0, 1)
	next, next_err := durable.next_id(c.hosts[0], 1)
	testing.expect(t, next_err == .None && next > id)
	durable.close(c.hosts[0]); c.hosts[0] = nil
	members := [1]sql.Node_Id{1}
	wrong, wrong_err := durable.open(c.paths[0], "other", 1, members[:],
		consensus_path = c.consensus_paths[0])
	testing.expect(t, wrong == nil && wrong_err == .Storage)
	// Losing local promises must not silently recreate an empty acceptor.
	testing.expect(t, os.remove(c.consensus_paths[0]) == nil)
	missing, missing_err := durable.open(c.paths[0], "test", 1, members[:],
		consensus_path = c.consensus_paths[0])
	testing.expect(t, missing == nil && missing_err == .Storage)
}
