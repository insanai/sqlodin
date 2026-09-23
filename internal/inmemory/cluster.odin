// Shared in-process integration harness. No sockets, journal or fsync: never a durable host.
package inmemory

import "core:container/queue"
import sqlodin "../../src"
import paxos "../../deps/paxos-odin/src"

Packet :: struct {
	env: sqlodin.Envelope(sqlodin.Mutation),
	value: sqlodin.Mutation,
}

N :: 3
W :: 64
C :: 16
INITIAL_QUEUE_CAPACITY :: #config(SQLODIN_QUEUE_INITIAL_CAPACITY, 32)

Cluster :: struct {
	nodes: [N]paxos.Node(sqlodin.Mutation, N, W, C, .Host_Managed),
	engines: [N]sqlodin.Engine,
	effects: [N]paxos.Effects(sqlodin.Mutation, N, W, C, .Host_Managed),
	membership: paxos.Membership(N),
	packets: queue.Queue(Packet),
	silent: sqlodin.Node_Id,
	max_queued: int,
}

must :: proc(err: $E) {
	if err != .None do panic(sqlodin.explain_error(err))
}

create :: proc(ownership: bool = true) -> ^Cluster {
	c := new(Cluster)
	alloc_err := queue.init(&c.packets, INITIAL_QUEUE_CAPACITY)
	if alloc_err != nil do panic("Network queue allocation failed")
	ids: [N]sqlodin.Node_Id
	for &id, i in ids do id = sqlodin.Node_Id(i + 1)
	must(sqlodin.membership_init(&c.membership, ids[:]))
	noop := sqlodin.mutation_make_skip(0, 0)
	for &node, i in c.nodes {
		if ownership {
			must(sqlodin.node_init(&node, ids[i], c.membership, noop))
		} else {
			must(paxos.node_init(&node, ids[i], c.membership))
			node.noop = noop
		}
		e, err := sqlodin.engine_open(":memory:", ids[i], memory = true)
		must(err)
		c.engines[i] = e
	}
	if !ownership {
		must(paxos.node_campaign(&c.nodes[0], noop, &c.effects[0]))
		flush(c, 0)
		drain(c)
	}
	return c
}

destroy :: proc(c: ^Cluster) {
	for &e in c.engines do sqlodin.engine_close(&e)
	queue.destroy(&c.packets)
	free(c)
}

packet_envelope :: proc(p: ^Packet) -> sqlodin.Envelope(sqlodin.Mutation) {
	env := p.env
	#partial switch &m in env.message {
	case sqlodin.Promise_Message(sqlodin.Mutation): m.value = &p.value
	case sqlodin.Accept_Message(sqlodin.Mutation): m.value = &p.value
	case sqlodin.Commit_Message(sqlodin.Mutation): m.value = &p.value
	}
	return env
}

// Copy borrowed payloads before another transition can modify the sender's ledger.
flush :: proc(c: ^Cluster, idx: int) {
	e := &c.effects[idx]
	must(sqlodin.engine_apply_batch(&c.engines[idx], sqlodin.effects_committed_slice(e)))
	for env in sqlodin.effects_messages_slice(e) {
		p := Packet{env = env}
		if value, ok := sqlodin.message_value(env.message); ok do p.value = value^
		ok, err := queue.push_back(&c.packets, p)
		if !ok || err != nil do panic("Network queue allocation failed")
	}
	c.max_queued = max(c.max_queued, queue.len(c.packets))
	sqlodin.effects_reset(e)
}

// Advance only the shared applied prefix. No replica can require evicted history here.
release :: proc(c: ^Cluster) {
	floor := max(sqlodin.Slot)
	for &e in c.engines do floor = min(floor, e.applied_through)
	for &node in c.nodes do must(sqlodin.node_advance_memory_floor(&node, floor))
}

drain :: proc(c: ^Cluster) -> int {
	delivered := 0
	for packet in queue.pop_front_safe(&c.packets) {
		p := packet
		if p.env.to == c.silent || p.env.from == c.silent do continue
		idx := int(p.env.to - 1)
		must(sqlodin.node_step(&c.nodes[idx], packet_envelope(&p), &c.effects[idx]))
		flush(c, idx)
		delivered += 1
		if delivered > 100000 do panic("Network did not settle")
	}
	release(c)
	return delivered
}

tick :: proc(c: ^Cluster) {
	for &node, i in c.nodes {
		if node.id == c.silent do continue
		must(sqlodin.node_tick(&node, &c.effects[i]))
		flush(c, i)
	}
	drain(c)
}
