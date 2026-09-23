package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_multimaster_fastpath_1rtt :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)
	for &e in c.engines {
		err := sqlodin.engine_exec(&e, "CREATE TABLE t1 (x INT);")
		testing.expect(t, err == .None)
	}

	// Node 1 proposes into its owned slot 1
	m, _ := sqlodin.mutation_make_raw_sql(1, 100, "INSERT INTO t1 VALUES (1);")
	slot, err := sqlodin.node_propose(&c.nodes[0], m, &c.effects[0])
	testing.expect(t, err == .None)
	testing.expect_value(t, slot, sqlodin.Slot(1))

	// Outbound accept messages should be emitted to peer nodes 2 and 3
	msgs := sqlodin.effects_messages_slice(&c.effects[0])
	testing.expect_value(t, len(msgs), 2)
	testing.expect_value(t, msgs[0].to, sqlodin.Node_Id(2))
	testing.expect_value(t, msgs[1].to, sqlodin.Node_Id(3))

	// Deliver messages
	cluster_drain_messages(c, 0)
	delivered := cluster_route(c)
	testing.expect(t, delivered > 0)

	// After 1 RTT, slot 1 must be decided on Node 1
	testing.expect_value(t, sqlodin.node_decided_through(&c.nodes[0]), sqlodin.Slot(1))
}

@(test)
test_concurrent_multimaster_proposals :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)
	for &e in c.engines {
		err := sqlodin.engine_exec(&e, "CREATE TABLE t1 (x INT);")
		testing.expect(t, err == .None)
	}

	// All 3 nodes propose concurrently into their respective owned slots
	m1, _ := sqlodin.mutation_make_raw_sql(1, 100, "INSERT INTO t1 VALUES (1);")
	m2, _ := sqlodin.mutation_make_raw_sql(2, 100, "INSERT INTO t1 VALUES (2);")
	m3, _ := sqlodin.mutation_make_raw_sql(3, 100, "INSERT INTO t1 VALUES (3);")

	s1, e1 := sqlodin.node_propose(&c.nodes[0], m1, &c.effects[0])
	s2, e2 := sqlodin.node_propose(&c.nodes[1], m2, &c.effects[1])
	s3, e3 := sqlodin.node_propose(&c.nodes[2], m3, &c.effects[2])

	testing.expect(t, e1 == .None)
	testing.expect(t, e2 == .None)
	testing.expect(t, e3 == .None)

	// Proposer 1 gets slot 1, proposer 2 gets slot 2, proposer 3 gets slot 3
	testing.expect_value(t, s1, sqlodin.Slot(1))
	testing.expect_value(t, s2, sqlodin.Slot(2))
	testing.expect_value(t, s3, sqlodin.Slot(3))

	cluster_drain_messages(c, 0)
	cluster_drain_messages(c, 1)
	cluster_drain_messages(c, 2)

	cluster_route(c)

	// All three nodes must converge and decide through slot 3
	for i in 0..<TEST_MAX_MEMBERS {
		testing.expect_value(t, sqlodin.node_decided_through(&c.nodes[i]), sqlodin.Slot(3))
	}
}

@(test)
test_idle_skip_unblocks_contiguous_commit :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)
	for &e in c.engines {
		err := sqlodin.engine_exec(&e, "CREATE TABLE t1 (x INT);")
		testing.expect(t, err == .None)
	}

	// Node 1 proposes slot 1
	m1, _ := sqlodin.mutation_make_raw_sql(1, 100, "INSERT INTO t1 VALUES (10);")
	sqlodin.node_propose(&c.nodes[0], m1, &c.effects[0])
	cluster_drain_messages(c, 0)

	// Node 3 proposes slot 3 (leaving slot 2 unproposed)
	m3, _ := sqlodin.mutation_make_raw_sql(3, 100, "INSERT INTO t1 VALUES (30);")
	sqlodin.node_propose(&c.nodes[2], m3, &c.effects[2])
	cluster_drain_messages(c, 2)

	cluster_route(c)

	// Contiguous decided is only 1 because slot 2 is missing
	testing.expect_value(t, sqlodin.node_decided_through(&c.nodes[0]), sqlodin.Slot(1))

	// Node 2 ticks: detects highest_seen >= 3, emits skip in slot 2
	sqlodin.node_tick(&c.nodes[1], &c.effects[1])
	cluster_drain_messages(c, 1)

	cluster_route(c)

	// Now all nodes unblock and advance contiguous decided through slot 3!
	testing.expect_value(t, sqlodin.node_decided_through(&c.nodes[0]), sqlodin.Slot(3))
	testing.expect_value(t, sqlodin.node_decided_through(&c.nodes[1]), sqlodin.Slot(3))
	testing.expect_value(t, sqlodin.node_decided_through(&c.nodes[2]), sqlodin.Slot(3))
}
