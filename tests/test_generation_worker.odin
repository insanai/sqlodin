package tests

import "core:testing"
import "core:os"
import "core:time"
import "core:sync"
import sql "../src"
import service "../service"
import durable "../src/durable"
import db "../src/sqlite"

@(test)
test_background_generation_preserves_live_tail_votes_ids_and_restart :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	testing.expect(t, durable.begin_compaction(h, "test") == .None)
	testing.expect(t, durable.begin_compaction(h, "test") == .Backpressure)
	_, snapshot_err := durable.begin_snapshot(h, 0)
	testing.expect(t, snapshot_err == .Backpressure)
	// All these writes occur after the worker's pinned journal frontier.
	insert, _ := sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(8)")
	for slot in 5..<145 do install_test_commit(t, h, sql.Slot(slot), insert)
	future := sql.Slot(150)
	ballot := sql.ballot_make(34, 0, 1)
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Prepare_Message{ballot, future, future, .Global}}
	testing.expect(t, durable.step(h, env) == .None)
	env.message = sql.Accept_Message(sql.Mutation){ballot, future, &insert}
	testing.expect(t, durable.step(h, env) == .None)
	reserved, id_err := durable.next_id(h, 100)
	testing.expect(t, id_err == .None)
	next: ^durable.Host
	replayed := 0
	for _ in 0..<3000 {
		// Once the background build is handed back, a service turn may replay
		// at most one SQL transaction. Large INSERT SELECTs must not be
		// multiplied into a long uninterrupted replay batch.
		work := h.compaction
		if sync.atomic_load(&work.done) == 0 { time.sleep(time.Millisecond); continue }
		ready := work.next != nil
		before: sql.Slot
		if ready do before = work.next.engine.applied_through
		err: durable.Error
		next, err = durable.poll_compaction(h)
		testing.expect(t, err == .None)
		if ready && err == .None {
			after := next.engine.applied_through if next != nil else
				h.compaction.next.engine.applied_through
			testing.expect(t, after >= before && after-before <= 1)
			replayed += int(after-before)
		}
		if next != nil || err != .None do break
		time.sleep(time.Millisecond)
	}
	testing.expect(t, next != nil && h.poisoned && replayed == 140)
	if next == nil do return
	durable.close(h)
	c.hosts[0], h = next, next
	testing.expect(t, h.engine.applied_through == 144 && h.generation_base.key.prefix == 3)
	vote, value, found := sql.ledger_vote_at(&h.node.ledger, future)
	testing.expect(t, found && vote == ballot && value^ == insert && h.node.ledger.promised == ballot)
	expect_rows(t, &h.engine, "SELECT * FROM t", 141)
	ids := [3]sql.Node_Id{1, 2, 3}
	durable.close(h)
	err: durable.Error
	c.hosts[0], err = durable.open_store(c.directories[0], "test", 1, ids[:])
	h = c.hosts[0]
	testing.expect(t, err == .None)
	if h == nil do return
	id, reserve_err := durable.next_id(h, 0)
	testing.expect(t, reserve_err == .None && id > reserved)
	expect_rows(t, &h.engine, "SELECT * FROM t", 141)
}

@(test)
test_maintenance_default_dirty_interval_starts_ordered_snapshot :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	create, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	install_test_commit(t, c.hosts[0], 1, create)
	s := new(service.Server)
	defer free(s)
	s.host, s.config.node, s.config.cluster = c.hosts[0], 1, "test"
	s.maintenance_dirty = time.tick_add(time.tick_now(), -16*time.Minute)
	testing.expect(t, service.drive_maintenance(s))
	testing.expect(t, s.host.snapshot.pending_token != 0 && s.host.compaction == nil)
}

@(test)
test_unpublished_background_generation_never_replaces_live_source :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	testing.expect(t, durable.begin_compaction(h, "test") == .None)
	insert, _ := sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(9)")
	install_test_commit(t, h, 5, insert)
	durable.generation_release_worker(h)
	testing.expect(t, h.compaction == nil && !h.snapshot_busy && !h.poisoned && h.store_current == "")
	durable.close(h)
	ids := [3]sql.Node_Id{1, 2, 3}
	err: durable.Error
	c.hosts[0], err = durable.open_store(c.directories[0], "test", 1, ids[:])
	h = c.hosts[0]
	testing.expect(t, err == .None)
	if h == nil do return
	testing.expect(t, h.engine.applied_through == 5 && h.generation_base.key.prefix == 0)
	expect_rows(t, &h.engine, "SELECT * FROM t", 2)
}

@(test)
test_generation_predecessor_descriptor_corruption_fails_closed :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	next, err := durable.compact_store(h, "test")
	testing.expect(t, err == .None)
	if next == nil do return
	testing.expect(t, next.generation_previous == "" && next.store_current != "")
	durable.close(h)
	c.hosts[0] = next
	testing.expect(t, db.exec(next.consensus,
		"UPDATE _sqlodin_generation_base SET previous='generation-9-9'"))
	durable.close(next)
	ids := [3]sql.Node_Id{1, 2, 3}
	c.hosts[0], err = durable.open_store(c.directories[0], "test", 1, ids[:])
	testing.expect(t, c.hosts[0] == nil && err == .Storage)
}

@(test)
test_maintenance_copy_failure_stops_acknowledgements_and_repeated_jobs :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	bytes, read_err := os.read_entire_file(h.snapshot.worker.image, context.temp_allocator)
	testing.expect(t, read_err == nil && len(bytes) > 0)
	bytes[0] ~= 1
	testing.expect(t, os.write_entire_file(h.snapshot.worker.image, bytes) == nil)
	s := new(service.Server)
	defer free(s)
	s.host, s.config.node, s.config.cluster = h, 1, "test"
	for _ in 0..<3000 {
		if !service.drive_maintenance(s) do break
		time.sleep(time.Millisecond)
	}
	testing.expect(t, s.fatal && h.poisoned && h.compaction == nil && h.store_current == "")
	testing.expect(t, s.maintenance_error == "Compaction_Failed")
	insert, _ := sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(9)")
	_, err := durable.propose(h, insert)
	testing.expect(t, err == .Poisoned)
}
