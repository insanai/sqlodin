package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

@(test)
test_skip_prefix_atomic_with_journal :: proc(t: ^testing.T) {
	for fault in ([?]durable.Fault{.None, .Before_Journal_Commit, .After_Journal_Commit}) {
		c := durable_test_open(t, 1)
		h := c.hosts[0]
		values: [4]sql.Mutation
		for &v in values do v = sql.mutation_make_skip(0, 0)
		slots: [4]sql.Slot
		h.fault = fault
		_, err := durable.propose_batch(h, values[:], slots[:])
		want := sql.Slot(0) if fault == .Before_Journal_Commit else 4
		testing.expect_value(t, h.engine.applied_through, want)
		if fault == .None {
			testing.expect(t, err == .None)
		} else {
			testing.expect(t, err == .Storage && h.poisoned)
			packet: durable.Packet
			testing.expect(t, !durable.pop(h, &packet))
		}
		durable_test_reopen(t, c, 0, 1)
		h = c.hosts[0]
		testing.expect_value(t, h.engine.applied_through, want)
		for slot in 1..=want {
			out, found, outcome_err := sql.engine_outcome(&h.engine, slot)
			testing.expect(t, found && outcome_err == .None && out.kind == .Applied && out.changes == 0)
		}
		durable_test_close(c)
	}
}

@(test)
test_skip_prefix_does_not_group_sql_rollback :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v UNIQUE); INSERT INTO t VALUES(1);")
	values := [3]sql.Mutation{
		sql.mutation_make_skip(0, 0),
		transaction_test_request(t, 1, "INSERT OR ROLLBACK INTO t VALUES(1);"),
		sql.mutation_make_skip(0, 0),
	}
	slots: [3]sql.Slot
	_, err := durable.propose_batch(h, values[:], slots[:])
	testing.expect(t, err == .None)
	durable_test_reopen(t, c, 0, 1)
	for slot, i in slots {
		out, complete, read_err := durable.outcome(c.hosts[0], slot, &values[i])
		want: sql.Transaction_Outcome = .Constraint if i == 1 else .Applied
		testing.expect(t, read_err == .None && complete && out.kind == want)
	}
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t WHERE v=1;", 1)
}
