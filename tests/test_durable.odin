package tests

import "core:testing"
import "core:os"
import "core:fmt"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

Durable_Test :: struct { dir: string, paths: [3]string, hosts: [3]^durable.Host }
durable_test_open :: proc(t: ^testing.T, count: int) -> ^Durable_Test {
	c := new(Durable_Test)
	c.dir, _ = os.make_directory_temp("", "sqlodin-durable-", context.allocator)
	ids := [3]sql.Node_Id{1, 2, 3}
	for i in 0..<count {
		c.paths[i] = fmt.aprintf("%s/node-%d.db", c.dir, i)
		h, err := durable.open(c.paths[i], "test", ids[i], ids[:count], create = true)
		testing.expect(t, err == .None)
		assert(h != nil)
		c.hosts[i] = h
	}
	return c
}

durable_test_close :: proc(c: ^Durable_Test) {
	for h in c.hosts do durable.close(h)
	os.remove_all(c.dir)
	for path in c.paths do if path != "" do delete(path)
	delete(c.dir)
	free(c)
}

durable_test_reopen :: proc(t: ^testing.T, c: ^Durable_Test, idx, count: int) {
	durable.close(c.hosts[idx])
	ids := [3]sql.Node_Id{1, 2, 3}
	h, err := durable.open(c.paths[idx], "test", ids[idx], ids[:count])
	testing.expect(t, err == .None)
	assert(h != nil)
	c.hosts[idx] = h
}

durable_test_drain :: proc(t: ^testing.T, c: ^Durable_Test, silent: int = -1) {
	for _ in 0..<1000 {
		count := 0
		for h, idx in c.hosts {
			if h == nil || idx == silent do continue
			p: durable.Packet
			for durable.pop(h, &p) {
				to := int(p.env.to) - 1
				if to == silent do continue
				testing.expect(t, durable.step(c.hosts[to], durable.envelope(&p)) == .None)
				count += 1
			}
		}
		if count == 0 do return
	}
	testing.expect(t, false, "durable network did not settle")
}

@(test)
test_durable_restart_and_identity :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	m, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE items(id PRIMARY KEY, v);")
	slot, err := durable.propose(h, m)
	testing.expect(t, err == .None && durable.acknowledged(h, slot, &m))
	for i in 0..<140 {
		text := fmt.aprintf("INSERT INTO items VALUES(%d, 'durable');", i)
		value, _ := sql.mutation_make_raw_sql(1, 0, text)
		delete(text)
		s, e := durable.propose(h, value)
		testing.expect(t, e == .None && durable.acknowledged(h, s, &value))
	}
	ids := [1]sql.Node_Id{1}
	duplicate, dup_err := durable.open(c.paths[0], "test", 1, ids[:])
	testing.expect(t, duplicate == nil && dup_err == .Locked)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	expect_rows(t, &h.engine, "SELECT * FROM items;", 140)
	testing.expect_value(t, h.engine.applied_through, sql.Slot(141))
	testing.expect(t, durable.acknowledged(h, slot, &m))
	durable.close(h)
	c.hosts[0] = nil
	wrong, wrong_err := durable.open(c.paths[0], "other", 1, ids[:])
	testing.expect(t, wrong == nil && wrong_err == .Storage)
}

@(test)
test_durable_commit_boundaries :: proc(t: ^testing.T) {
	for fault in ([?]durable.Fault{
		.Before_Journal_Commit, .After_Journal_Commit, .After_Application_Commit,
	}) {
		c := durable_test_open(t, 1)
		h := c.hosts[0]
		m, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE recovered(id PRIMARY KEY);")
		h.fault = fault
		slot, err := durable.propose(h, m)
		testing.expect(t, err == .Storage && h.poisoned)
		testing.expect(t, !durable.acknowledged(h, slot, &m))
		p: durable.Packet
		testing.expect(t, !durable.pop(h, &p))
		durable_test_reopen(t, c, 0, 1)
		want := sql.Slot(1)
		if fault == .Before_Journal_Commit do want = 0
		testing.expect_value(t, c.hosts[0].engine.applied_through, want)
		if want == 1 do expect_rows(t, &c.hosts[0].engine, "SELECT * FROM recovered;", 0)
		durable_test_close(c)
	}
}

@(test)
test_durable_corruption_and_write_failure :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	m, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v);")
	durable.propose(h, m)
	testing.expect(t, db.exec(h.engine.db, "PRAGMA query_only=ON;"))
	_, err := durable.propose(h, m)
	testing.expect(t, err == .Storage && h.poisoned)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	testing.expect(t, db.exec(h.engine.db, "DELETE FROM _sqlodin_journal WHERE seq=1;"))
	durable.close(h)
	c.hosts[0] = nil
	ids := [1]sql.Node_Id{1}
	bad, bad_err := durable.open(c.paths[0], "test", 1, ids[:])
	testing.expect(t, bad == nil && bad_err == .Storage)
}

@(test)
test_durable_multimaster_restart_and_old_history :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	// All three masters admit proposals before any messages are delivered.
	for h, i in c.hosts {
		text := fmt.aprintf("CREATE TABLE t%d(id PRIMARY KEY);", i)
		m, _ := sql.mutation_make_raw_sql(sql.Node_Id(i + 1), 0, text)
		delete(text)
		_, err := durable.propose(h, m)
		testing.expect(t, err == .None)
	}
	durable_test_drain(t, c)
	for i in 0..<3 do durable_test_reopen(t, c, i, 3)
	// A voter misses more than a memory window; retained disk history must repair it.
	for i in 0..<80 {
		text := fmt.aprintf("INSERT INTO t0 VALUES(%d);", i)
		m, _ := sql.mutation_make_raw_sql(1, 0, text)
		delete(text)
		_, err := durable.propose(c.hosts[0], m)
		testing.expect(t, err == .None)
		for _ in 0..<5 {
			for h in c.hosts[:2] do testing.expect(t, durable.tick(h) == .None)
			durable_test_drain(t, c, silent = 2)
		}
	}
	for i in 0..<3 do durable_test_reopen(t, c, i, 3)
	for _ in 0..<100 {
		for h in c.hosts do testing.expect(t, durable.tick(h) == .None)
		durable_test_drain(t, c)
	}
	for h in c.hosts do expect_rows(t, &h.engine, "SELECT * FROM t0;", 80)
}

@(test)
test_durable_disk_full_and_promises :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	h := c.hosts[1]
	m, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE pending(v);")
	ballot := sql.ballot_make(3, 0, 1)
	prepare := sql.Envelope(sql.Mutation){from = 1, to = 2,
		message = sql.Prepare_Message{ballot = ballot, first = 1, last = 1, scope = .Bounded}}
	testing.expect(t, durable.step(h, prepare) == .None)
	accept := sql.Envelope(sql.Mutation){from = 1, to = 2,
		message = sql.Accept_Message(sql.Mutation){ballot, 1, &m}}
	testing.expect(t, durable.step(h, accept) == .None)
	durable_test_reopen(t, c, 1, 3)
	h = c.hosts[1]
	testing.expect_value(t, h.node.ledger.promised_at[0], ballot)
	testing.expect_value(t, h.node.ledger.vote_ballot[0], ballot)
	testing.expect_value(t, h.node.ledger.value[0], m)
	lower := sql.Envelope(sql.Mutation){from = 1, to = 2,
		message = sql.Accept_Message(sql.Mutation){sql.ballot_make(2, 0, 1), 1, &m}}
	testing.expect(t, durable.step(h, lower) == .None)
	testing.expect_value(t, h.node.ledger.vote_ballot[0], ballot)
	testing.expect(t, db.exec(h.engine.db, "PRAGMA max_page_count=1;"))
	// Force a nonzero retained payload larger than a page, even with zero-run packing.
	// Inactive tails are part of Paxos equality and must still be persisted verbatim.
	m2, _ := sql.mutation_make_raw_sql(3, 0, "CREATE TABLE blocked(v);")
	for &b in m2.sql_bytes[m2.sql_len:] do b = 0xbb
	for &v in m2.col_values do for &b in v.text_val do b = 0xaa
	_, err := durable.propose(h, m2)
	testing.expect(t, err == .Storage && h.poisoned)
	durable_test_reopen(t, c, 1, 3)
	testing.expect_value(t, c.hosts[1].node.ledger.vote_ballot[0], ballot)
}

@(test)
test_durable_ids_survive_clock_rollback_and_restart :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	first, err := durable.next_id(c.hosts[0], 100)
	testing.expect(t, err == .None)
	last := first
	for _ in 0..<4097 {
		id, e := durable.next_id(c.hosts[0], 99)
		testing.expect(t, e == .None && id > last)
		last = id
	}
	durable_test_reopen(t, c, 0, 1)
	id, e := durable.next_id(c.hosts[0], 98)
	testing.expect(t, e == .None && id > last)
}
