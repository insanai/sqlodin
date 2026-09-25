package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

generation_test_snapshot :: proc(t: ^testing.T, h: ^durable.Host, directory: string) {
	testing.expect(t, durable.snapshot_enable(h, h.application_path, directory) == .None)
	slot, err := durable.begin_snapshot(h, 0)
	testing.expect(t, err == .None && slot != 0)
	for _ in 0..<3000 {
		testing.expect(t, durable.snapshot_progress(h, 0) == .None)
		if h.snapshot_sealed.key.prefix >= slot do return
		if durable.snapshot_worker_failed(h.snapshot) do break
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "snapshot did not become certified")
}

@(test)
test_generation_publish_restart_suffix_and_fail_closed :: proc(t: ^testing.T) {
	directory, _ := os.make_directory_temp("", "sqlodin-generation-", context.allocator)
	defer delete(directory)
	defer os.remove_all(directory)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(directory, "test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	value, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v);")
	_, err = durable.propose(h, value)
	testing.expect(t, err == .None)
	for cycle in 0..<2 {
		images := fmt.aprintf("%s/images-%d", directory, cycle)
		generation_test_snapshot(t, h, images)
		delete(images)
		value, _ = sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(7);")
		slot, write_err := durable.propose(h, value)
		testing.expect(t, write_err == .None && durable.acknowledged(h, slot, &value))
		reserved, id_err := durable.next_id(h, 12)
		testing.expect(t, id_err == .None)
		old_prefix := h.snapshot_sealed.key.prefix
		next, compact_err := durable.compact_store(h, "test")
		testing.expect(t, compact_err == .None)
		if next == nil do return
		testing.expect(t, h.poisoned && next.generation_base.key.prefix == old_prefix)
		testing.expect(t, next.generation_previous == h.store_current)
		durable.close(h)
		h = next
		testing.expect(t, durable.acknowledged(h, slot, &value))
		expect_rows(t, &h.engine, "SELECT * FROM t;", cycle+1)
		durable.close(h)
		h, err = durable.open_store(directory, "test", 1, ids[:])
		testing.expect(t, err == .None)
		if h == nil do return
		next_id, next_err := durable.next_id(h, 0)
		testing.expect(t, next_err == .None && next_id > reserved)
		expect_rows(t, &h.engine, "SELECT * FROM t;", cycle+1)
	}
	// A corrupt active generation may never silently fall back to the intact old one.
	testing.expect(t, db.exec(h.consensus, "UPDATE _sqlodin_generation_base SET seal=1"))
	durable.close(h)
	h, err = durable.open_store(directory, "test", 1, ids[:])
	testing.expect(t, h == nil && err == .Storage)
}

@(test)
test_generation_preserves_unchosen_vote_and_global_promise :: proc(t: ^testing.T) {
	directory, _ := os.make_directory_temp("", "sqlodin-generation-vote-", context.allocator)
	defer delete(directory)
	defer os.remove_all(directory)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(directory, "test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	images := fmt.aprintf("%s/images", directory)
	defer delete(images)
	generation_test_snapshot(t, h, images)
	value, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE preserved(v);")
	future := h.engine.applied_through+5
	ballot := sql.ballot_make(33, 0, 1)
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Accept_Message(sql.Mutation){ballot, future, &value}}
	testing.expect(t, durable.step(h, env) == .None)
	env.message = sql.Prepare_Message{ballot, future, future, .Global}
	testing.expect(t, durable.step(h, env) == .None)
	promised := h.node.ledger.promised
	testing.expect(t, promised == ballot)
	next, compact_err := durable.compact_store(h, "test")
	testing.expect(t, compact_err == .None)
	if next == nil do return
	durable.close(h)
	h = next
	vote, accepted, found := sql.ledger_vote_at(&h.node.ledger, future)
	testing.expect(t, found && vote == ballot && accepted^ == value)
	testing.expect(t, h.node.ledger.promised == promised)
	// Obsolete history requests are snapshot work, not local storage corruption.
	testing.expect(t, durable.serve(h, {peer = 1, first = 1, count = 1}))
	testing.expect(t, !h.poisoned && h.snapshot_requests[0])
	other, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE conflicting(v);")
	env.message = sql.Accept_Message(sql.Mutation){sql.ballot_make(1, 0, 1), future, &other}
	testing.expect(t, durable.step(h, env) == .None)
	vote, accepted, found = sql.ledger_vote_at(&h.node.ledger, future)
	testing.expect(t, found && vote == ballot && accepted^ == value)
	// A config cannot turn a retained generation directory into a fresh store root.
	child, child_err := durable.open_store(filepath.dir(h.application_path), "test", 1, ids[:])
	testing.expect(t, child == nil && child_err == .Storage)
	durable.close(child)
	// The previous root is retained but cannot be opened as a fresh active acceptor.
	root_app := fmt.aprintf("%s/node.db", directory)
	root_consensus := fmt.aprintf("%s/consensus.db", directory)
	defer delete(root_app)
	defer delete(root_consensus)
	old, old_err := durable.open(root_app, "test", 1, ids[:], consensus_path = root_consensus)
	testing.expect(t, old == nil && old_err == .Storage)
	durable.close(old)
}

@(test)
test_generation_retires_slot_evidence_without_reviving_requests_or_reads :: proc(t: ^testing.T) {
	directory, _ := os.make_directory_temp("", "sqlodin-generation-fences-", context.allocator)
	defer delete(directory)
	defer os.remove_all(directory)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(directory, "test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	create, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	_, err = durable.propose(h, create)
	testing.expect(t, err == .None)
	session: [16]u8
	session[0] = 1
	value, _ := sql.mutation_make_transaction(1, {session, 1, 0}, "INSERT INTO t VALUES(7)")
	old_slot, write_err := durable.propose(h, value)
	testing.expect(t, write_err == .None && durable.acknowledged(h, old_slot, &value))
	ticket, read_err := durable.begin_read(h, 0)
	testing.expect(t, read_err == .None)
	images := fmt.aprintf("%s/images", directory)
	defer delete(images)
	generation_test_snapshot(t, h, images)
	next, compact_err := durable.compact_store(h, "test")
	testing.expect(t, compact_err == .None)
	if next == nil do return
	durable.close(h)
	h = next
	_, complete, out_err := durable.outcome(h, old_slot, &value)
	testing.expect(t, out_err == .None && !complete && !h.poisoned)
	read, poll_err := durable.poll_read(h, ticket, "SELECT * FROM t")
	testing.expect(t, poll_err == .None && read.status == .Displaced)
	retry_slot, retry_err := durable.propose(h, value)
	testing.expect(t, retry_err == .None && durable.acknowledged(h, retry_slot, &value))
	expect_rows(t, &h.engine, "SELECT * FROM t", 1)
	ticket, read_err = durable.begin_read(h, 0)
	testing.expect(t, read_err == .None)
	read, poll_err = durable.poll_read(h, ticket, "SELECT * FROM t")
	testing.expect(t, poll_err == .None && read.status == .Ready && read.rows == 1)
}
