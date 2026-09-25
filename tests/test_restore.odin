package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

restore_test_backup :: proc(t: ^testing.T) -> (root, backup: string, value: sql.Mutation) {
	root = snapshot_test_directory(t)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(root, "old", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	defer durable.close(h)
	schema, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	_, err = durable.propose(h, schema)
	testing.expect(t, err == .None)
	request := sql.Request_Id{sequence = 1}
	request.session[0] = 1
	value, _ = sql.mutation_make_transaction(1, request, "INSERT INTO t VALUES(7)")
	slot, write_err := durable.propose(h, value)
	testing.expect(t, write_err == .None && durable.acknowledged(h, slot, &value))
	ballot := sql.ballot_make(33, 0, 1)
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Prepare_Message{ballot, 10, 10, .Global}}
	testing.expect(t, durable.step(h, env) == .None)
	env.message = sql.Accept_Message(sql.Mutation){ballot, 10, &value}
	testing.expect(t, durable.step(h, env) == .None)
	backup = fmt.aprintf("%s/backup", root)
	_, err = durable.backup_store(h, "old", backup)
	testing.expect(t, err == .None)
	return
}

@(test)
test_restore_preserves_retry_fences_and_restarts_after_compaction :: proc(t: ^testing.T) {
	root, backup, value := restore_test_backup(t)
	defer delete(root)
	defer delete(backup)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/restored", root)
	defer delete(path)
	ids := [1]sql.Node_Id{1}
	testing.expect(t, durable.restore_backup(backup, path, "old", 1, ids[:]) == .Invalid)
	testing.expect(t, !os.exists(path))
	testing.expect(t, durable.restore_backup(backup, path, "fresh", 1, ids[:]) == .None)
	testing.expect(t, durable.restore_backup(backup, path, "fresh", 1, ids[:]) == .Storage)
	h, err := durable.open_store(path, "fresh", 1, ids[:])
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	testing.expect(t, h.genesis.prefix == 2 && h.genesis_hash != ([32]u8{}))
	testing.expect(t, h.engine.applied_through == 2 && h.sequence == 0 &&
		h.node.ledger.promised == (sql.Ballot{}))
	_, _, found := sql.ledger_vote_at(&h.node.ledger, 10)
	testing.expect(t, !found)
	hash := h.genesis_hash
	slot, proposal_err := durable.propose(h, value)
	testing.expect(t, proposal_err == .None && durable.acknowledged(h, slot, &value))
	expect_rows(t, &h.engine, "SELECT * FROM t", 1)
	ticket, read_err := durable.begin_read(h, 0)
	testing.expect(t, read_err == .None)
	result, poll_err := durable.poll_read(h, ticket, "SELECT * FROM t")
	testing.expect(t, poll_err == .None && result.status == .Ready && result.rows == 1)
	images := fmt.aprintf("%s/images", path)
	defer delete(images)
	generation_test_snapshot(t, h, images)
	next, compact_err := durable.compact_store(h, "fresh")
	testing.expect(t, compact_err == .None)
	if next == nil do return
	durable.close(h)
	h = next
	testing.expect(t, h.genesis_hash == hash && h.generation_base.key.prefix > h.genesis.prefix)
	durable.close(h)
	h, err = durable.open_store(path, "fresh", 1, ids[:])
	testing.expect(t, err == .None)
	if h == nil do return
	slot, proposal_err = durable.propose(h, value)
	testing.expect(t, proposal_err == .None && durable.acknowledged(h, slot, &value))
	expect_rows(t, &h.engine, "SELECT * FROM t", 1)
	old, old_err := durable.open_store(root, "fresh", 1, ids[:])
	testing.expect(t, old == nil && old_err == .Storage)
	old, old_err = durable.open_store(root, "old", 1, ids[:])
	testing.expect(t, old_err == .None && old.node.ledger.promised == sql.ballot_make(33, 0, 1))
	durable.close(old)
}

@(test)
test_empty_restore_binds_genesis_and_rejects_descriptor_corruption :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(root, "old", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	backup, restored, empty := fmt.aprintf("%s/backup", root), fmt.aprintf("%s/restored", root),
		fmt.aprintf("%s/empty", root)
	defer delete(backup)
	defer delete(restored)
	defer delete(empty)
	manifest, backup_err := durable.backup_store(h, "old", backup)
	testing.expect(t, backup_err == .None && manifest.prefix == 0)
	testing.expect(t, durable.restore_backup(backup, restored, "fresh", 1, ids[:]) == .None)
	r, restored_err := durable.open_store(restored, "fresh", 1, ids[:])
	testing.expect(t, restored_err == .None)
	if r == nil do return
	defer durable.close(r)
	testing.expect(t, r.genesis_hash != ([32]u8{}) && r.engine.applied_through == 0)
	testing.expect(t, os.make_directory(empty) == nil)
	e, empty_err := durable.open_store(empty, "fresh", 1, ids[:], create = true)
	testing.expect(t, empty_err == .None)
	if e == nil do return
	testing.expect(t, e.configuration != r.configuration && e.genesis_hash == ([32]u8{}))
	durable.close(e)
	value, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	slot, write_err := durable.propose(r, value)
	testing.expect(t, write_err == .None && slot == 1 && durable.acknowledged(r, slot, &value))
	testing.expect(t, db.exec(r.consensus, "UPDATE _sqlodin_genesis SET digest=zeroblob(32)"))
	durable.close(r)
	r, restored_err = durable.open_store(restored, "fresh", 1, ids[:])
	testing.expect(t, restored_err == .Storage && r == nil)
}
