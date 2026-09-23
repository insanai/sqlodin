package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

@(test)
test_durable_batch_independent_outcomes_and_retry :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v UNIQUE);")
	values: [4]sql.Mutation
	for &m, i in values {
		m = transaction_test_request(t, u64(i + 1), "INSERT INTO t VALUES(?1);")
		testing.expect(t, sql.transaction_add_int(&m, i64(i / 2)) == .None)
	}
	slots: [4]sql.Slot
	assigned, err := durable.propose_batch(h, values[:], slots[:])
	testing.expect(t, err == .None && len(assigned) == 4)
	for slot, i in slots {
		out, complete, read_err := durable.outcome(h, slot, &values[i])
		want: sql.Transaction_Outcome = .Applied if i % 2 == 0 else .Constraint
		testing.expect(t, read_err == .None && complete && out.kind == want)
	}
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	expect_rows(t, &h.engine, "SELECT * FROM t;", 2)
	testing.expect(t, transaction_test_submit(t, h, values[3]).kind == .Constraint)
	testing.expect(t, transaction_test_submit(t, h, values[0]).kind == .Expired)
}

@(test)
test_durable_batch_validates_before_admission :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	values := [2]sql.Mutation{sql.mutation_make_skip(0, 0), {kind = .Transaction}}
	slots: [2]sql.Slot
	before := h.sequence
	_, err := durable.propose_batch(h, values[:], slots[:])
	testing.expect(t, err == .Invalid && h.sequence == before && h.engine.applied_through == 0)
	values[1] = values[0]
	_, err = durable.propose_batch(h, values[:], slots[:1])
	testing.expect(t, err == .Invalid && h.sequence == before)
	_, err = durable.propose_batch(h, values[:0], slots[:])
	testing.expect(t, err == .Invalid && h.sequence == before)
}

@(test)
test_durable_batch_crash_barrier_and_recovery :: proc(t: ^testing.T) {
	for fault in ([2]durable.Fault{.Before_Journal_Commit, .After_Journal_Commit}) {
		c := durable_test_open(t, 1)
		h := c.hosts[0]
		transaction_test_schema(t, h, "CREATE TABLE t(v);")
		values: [4]sql.Mutation
		for &m, i in values {
			m = transaction_test_request(t, u64(i + 1), "INSERT INTO t VALUES(1);")
		}
		slots: [4]sql.Slot
		h.fault = fault
		_, err := durable.propose_batch(h, values[:], slots[:])
		testing.expect(t, err == .Storage && h.poisoned)
		p: durable.Packet
		testing.expect(t, !durable.pop(h, &p))
		durable_test_reopen(t, c, 0, 1)
		h = c.hosts[0]
		want := 4 if fault == .After_Journal_Commit else 0
		expect_rows(t, &h.engine, "SELECT * FROM t;", want)
		durable_test_close(c)
	}
}

@(test)
test_durable_batch_all_masters_restart :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	setup, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(id PRIMARY KEY,v);")
	_, err := durable.propose(c.hosts[0], setup)
	testing.expect(t, err == .None)
	durable_test_drain(t, c)
	for h, node in c.hosts {
		values: [8]sql.Mutation
		slots: [8]sql.Slot
		for &m, i in values {
			m = transaction_test_request(t, u64(i + 1), "INSERT INTO t VALUES(?1,'batch');")
			m.request.session[0] = u8(node + 1)
			m.origin_node = sql.Node_Id(node + 1)
			testing.expect(t, sql.transaction_add_int(&m, i64(node * 8 + i)) == .None)
		}
		assigned, propose_err := durable.propose_batch(h, values[:], slots[:])
		testing.expect(t, propose_err == .None && len(assigned) == 8)
	}
	for _ in 0..<20 {
		for h in c.hosts do testing.expect(t, durable.tick(h) == .None)
		durable_test_drain(t, c)
	}
	for i in 0..<3 {
		durable_test_reopen(t, c, i, 3)
		expect_rows(t, &c.hosts[i].engine, "SELECT * FROM t WHERE v='batch';", 24)
	}
}
