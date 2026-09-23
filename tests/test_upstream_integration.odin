package tests

import "core:testing"
import "core:container/queue"
import host "../internal/inmemory"
import sqlodin "../src"

@(test)
test_pinned_paxos_recovers_unavailable_owner :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)
	for &e in c.engines {
		host.must(sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY);"))
	}
	c.silent = 3
	// Owner 3 is unavailable; proposals at 1, 2 and 4 require recovery of the hole at 3.
	for idx, i in ([?]int{0, 1, 0}) {
		m, _ := sqlodin.mutation_make_insert(sqlodin.Node_Id(idx + 1), 0, u64(i + 1), "t")
		_, err := sqlodin.node_propose(&c.nodes[idx], m, &c.effects[idx])
		testing.expect(t, err == .None)
		host.flush(c, idx)
		host.drain(c)
	}
	for _ in 0..<40 do host.tick(c)
	for &e in c.engines[:2] {
		testing.expect(t, e.applied_through >= 4)
		expect_rows(t, &e, "SELECT id FROM t;", 3)
	}
	c.silent = 0
	for _ in 0..<40 do host.tick(c)
	for &e in c.engines do expect_rows(t, &e, "SELECT id FROM t;", 3)
}

@(test)
test_pinned_paxos_retries_lost_accepts :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)
	m, _ := sqlodin.mutation_make_raw_sql(1, 0, "CREATE TABLE t (id INTEGER);")
	_, err := sqlodin.node_propose(&c.nodes[0], m, &c.effects[0])
	testing.expect(t, err == .None)
	host.flush(c, 0)
	// Drop every initial Accept packet. A later tick must retransmit the proposal.
	queue.clear(&c.packets)
	for _ in 0..<40 do host.tick(c)
	for &e in c.engines {
		testing.expect(t, e.applied_through >= 1)
		expect_rows(t, &e, "SELECT name FROM sqlite_master WHERE name='t';", 1)
	}
}

@(test)
test_more_than_one_consensus_window_applies_every_write :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)
	for &e in c.engines {
		host.must(sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER);"))
	}
	for i in 0..<TEST_WINDOW * 3 {
		idx := i % TEST_MAX_MEMBERS
		m, _ := sqlodin.mutation_make_insert(sqlodin.Node_Id(idx + 1), 0, u64(i), "t")
		sqlodin.mutation_add_int(&m, "v", i64(i * 2))
		_, err := sqlodin.node_propose(&c.nodes[idx], m, &c.effects[idx])
		testing.expect(t, err == .None)
		host.flush(c, idx)
		host.drain(c)
	}
	for &e in c.engines {
		testing.expect_value(t, e.applied_through, sqlodin.Slot(TEST_WINDOW * 3))
		expect_rows(t, &e, "SELECT id FROM t WHERE v=id*2;", TEST_WINDOW * 3)
	}
}

@(test)
test_concurrent_masters_resolve_conflicts_by_slot :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)
	for &e in c.engines {
		host.must(sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER);"))
	}
	// Four writes per master, all proposed before delivering any network message.
	for i in 0..<12 {
		idx := i % 3
		m, _ := sqlodin.mutation_make_insert(sqlodin.Node_Id(idx + 1), 0, 42, "t")
		host.must(sqlodin.mutation_add_int(&m, "v", i64(i)))
		_, err := sqlodin.node_propose(&c.nodes[idx], m, &c.effects[idx])
		testing.expect(t, err == .None)
		host.flush(c, idx)
	}
	host.drain(c)
	for &e in c.engines {
		testing.expect_value(t, e.applied_through, sqlodin.Slot(12))
		expect_rows(t, &e, "SELECT id FROM t WHERE id=42 AND v=11;", 1)
	}
}
