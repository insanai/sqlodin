package tests

import "core:testing"
import "core:container/small_array"
import sqlodin "../src"

TEST_MAX_MEMBERS :: 3
TEST_WINDOW      :: 64
TEST_CHUNK       :: 16

Test_Node :: sqlodin.MultiMaster_Node(
	sqlodin.Mutation,
	TEST_MAX_MEMBERS,
	TEST_WINDOW,
	TEST_CHUNK,
	.Host_Managed,
)

Test_Effects :: sqlodin.Effects(
	sqlodin.Mutation,
	TEST_MAX_MEMBERS,
	TEST_WINDOW,
	TEST_CHUNK,
	.Host_Managed,
)

Packet :: struct {
	env: sqlodin.Envelope(sqlodin.Mutation),
}

Cluster :: struct {
	nodes:       [TEST_MAX_MEMBERS]Test_Node,
	engines:     [TEST_MAX_MEMBERS]sqlodin.Engine,
	effects:     [TEST_MAX_MEMBERS]Test_Effects,
	membership:  sqlodin.Membership(TEST_MAX_MEMBERS),
	packets:     small_array.Small_Array(512, Packet),
}

cluster_create :: proc() -> ^Cluster {
	c := new(Cluster)
	ids := [?]sqlodin.Node_Id{1, 2, 3}
	sqlodin.membership_init(&c.membership, ids[:])

	noop := sqlodin.mutation_make_skip(0, 0)
	for i in 0..<TEST_MAX_MEMBERS {
		node_id := sqlodin.Node_Id(i + 1)
		sqlodin.node_init(&c.nodes[i], node_id, c.membership, noop)
		engine, err := sqlodin.engine_open(":memory:", node_id, memory = true)
		testing.expect(nil, err == .None)
		c.engines[i] = engine
	}
	return c
}

cluster_destroy :: proc(c: ^Cluster) {
	for i in 0..<TEST_MAX_MEMBERS {
		sqlodin.engine_close(&c.engines[i])
	}
	free(c)
}

cluster_apply_effects :: proc(c: ^Cluster, idx: int) {
	committed := sqlodin.effects_committed_slice(&c.effects[idx])
	for entry in committed {
		sqlodin.engine_apply_slot(&c.engines[idx], entry.slot, entry.value)
	}
}

cluster_drain_messages :: proc(c: ^Cluster, sender_idx: int) {
	cluster_apply_effects(c, sender_idx)
	msgs := sqlodin.effects_messages_slice(&c.effects[sender_idx])
	for env in msgs {
		small_array.push_back(&c.packets, Packet{env = env})
	}
}

// Routes in-flight network packets between nodes until quiescence.
cluster_route :: proc(c: ^Cluster) -> int {
	delivered := 0
	for small_array.len(c.packets) > 0 {
		pkt := small_array.get(c.packets, 0)
		small_array.ordered_remove(&c.packets, 0)

		target_idx := int(pkt.env.to - 1)
		if target_idx >= 0 && target_idx < TEST_MAX_MEMBERS {
			sqlodin.effects_reset(&c.effects[target_idx])
			sqlodin.node_step(&c.nodes[target_idx], pkt.env, &c.effects[target_idx])
			cluster_drain_messages(c, target_idx)
			delivered += 1
		}
	}
	return delivered
}

cluster_apply_all :: proc(c: ^Cluster) {
	for i in 0..<TEST_MAX_MEMBERS {
		cluster_apply_effects(c, i)
	}
}
