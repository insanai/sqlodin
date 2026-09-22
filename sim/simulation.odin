package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sqlodin "../src"

MAX_NODES :: 5
SIM_WINDOW :: 64
SIM_CHUNK :: 16

Sim_Node :: sqlodin.MultiMaster_Node(
	sqlodin.Mutation, MAX_NODES, SIM_WINDOW, SIM_CHUNK, .Host_Managed,
)
Sim_Effects :: sqlodin.Effects(sqlodin.Mutation, MAX_NODES, SIM_WINDOW, SIM_CHUNK, .Host_Managed)

Sim_Packet :: struct {
	env: sqlodin.Envelope(sqlodin.Mutation),
	val: sqlodin.Mutation,
}

Prng :: struct {
	state: u64,
}

prng_init :: proc(p: ^Prng, seed: u64) {
	p.state = seed if seed != 0 else 0x853c49e6748fea9b
}

prng_next_u64 :: proc(p: ^Prng) -> u64 {
	p.state += 0x9e3779b97f4a7c15
	z := p.state
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

prng_int_max :: proc(p: ^Prng, max_val: int) -> int {
	if max_val <= 0 do return 0
	return int(prng_next_u64(p) % u64(max_val))
}

prng_chance :: proc(p: ^Prng, permille: int) -> bool {
	return prng_int_max(p, 1000) < permille
}

Simulation :: struct {
	node_count: int,
	nodes:      [MAX_NODES]Sim_Node,
	engines:    [MAX_NODES]sqlodin.Engine,
	effects:    [MAX_NODES]Sim_Effects,
	membership: sqlodin.Membership(MAX_NODES),
	packets:    [dynamic]Sim_Packet,
	prng:       Prng,
	seq:        u16,
	crashes:    int,
}

sim_init :: proc(s: ^Simulation, node_count: int, seed: u64) {
	s.node_count = node_count
	prng_init(&s.prng, seed)
	s.packets = make([dynamic]Sim_Packet)

	ids: [MAX_NODES]sqlodin.Node_Id
	for i in 0..<node_count {
		ids[i] = sqlodin.Node_Id(i + 1)
	}
	sqlodin.membership_init(&s.membership, ids[:node_count])

	noop := sqlodin.mutation_make_skip(0, 0)
	for i in 0..<node_count {
		node_id := sqlodin.Node_Id(i + 1)
		sqlodin.node_init(&s.nodes[i], node_id, s.membership, noop)
		e, _ := sqlodin.engine_open(":memory:", node_id, memory = true)
		s.engines[i] = e
		sqlodin.engine_exec(
			&s.engines[i],
			"CREATE TABLE items (id INTEGER PRIMARY KEY, v INTEGER);",
		)
	}
}

sim_close :: proc(s: ^Simulation) {
	for i in 0..<s.node_count {
		sqlodin.engine_close(&s.engines[i])
	}
	delete(s.packets)
}

sim_drain_node :: proc(s: ^Simulation, idx: int) {
	committed := sqlodin.effects_committed_slice(&s.effects[idx])
	for c in committed {
		sqlodin.engine_apply_slot(&s.engines[idx], c.slot, c.value)
	}
	msgs := sqlodin.effects_messages_slice(&s.effects[idx])
	for env in msgs {
		val: sqlodin.Mutation
		if v, ok := sqlodin.message_value(env.message); ok {
			val = v^
		}
		append(&s.packets, Sim_Packet{env = env, val = val})
	}
}

sim_propose_random :: proc(s: ^Simulation) {
	proposer := prng_int_max(&s.prng, s.node_count)
	node_id := sqlodin.Node_Id(proposer + 1)
	pk := sqlodin.snowflake_generate(node_id, prng_next_u64(&s.prng) % 1000000, &s.seq)

	m, _ := sqlodin.mutation_make_insert(node_id, 100, pk, "items")
	val := i64(prng_next_u64(&s.prng) % 1000)
	sqlodin.mutation_add_int(&m, "v", val)

	sqlodin.node_propose(&s.nodes[proposer], m, &s.effects[proposer])
	sim_drain_node(s, proposer)
}

sim_step_network :: proc(s: ^Simulation) {
	if len(s.packets) == 0 do return
	idx := prng_int_max(&s.prng, len(s.packets))
	pkt := s.packets[idx]
	unordered_remove(&s.packets, idx)

	// Simulated drop (5%)
	if prng_chance(&s.prng, 50) do return

	target := int(pkt.env.to - 1)
	if target < 0 || target >= s.node_count do return

	env := pkt.env
	#partial switch &m in env.message {
	case sqlodin.Accept_Message(sqlodin.Mutation):  m.value = &pkt.val
	case sqlodin.Commit_Message(sqlodin.Mutation):  m.value = &pkt.val
	case sqlodin.Promise_Message(sqlodin.Mutation): m.value = &pkt.val
	}

	sqlodin.effects_reset(&s.effects[target])
	sqlodin.node_step(&s.nodes[target], env, &s.effects[target])
	sim_drain_node(s, target)

	// Simulated duplicate (5%)
	if prng_chance(&s.prng, 50) {
		append(&s.packets, pkt)
	}
}

sim_step_network_reliable :: proc(s: ^Simulation) {
	if len(s.packets) == 0 do return
	pkt := s.packets[0]
	ordered_remove(&s.packets, 0)

	target := int(pkt.env.to - 1)
	if target < 0 || target >= s.node_count do return

	env := pkt.env
	#partial switch &m in env.message {
	case sqlodin.Accept_Message(sqlodin.Mutation):  m.value = &pkt.val
	case sqlodin.Commit_Message(sqlodin.Mutation):  m.value = &pkt.val
	case sqlodin.Promise_Message(sqlodin.Mutation): m.value = &pkt.val
	}

	sqlodin.effects_reset(&s.effects[target])
	sqlodin.node_step(&s.nodes[target], env, &s.effects[target])
	sim_drain_node(s, target)
}

sim_tick_nodes :: proc(s: ^Simulation) {
	for i in 0..<s.node_count {
		sqlodin.node_tick(&s.nodes[i], &s.effects[i])
		sim_drain_node(s, i)
	}
}

sim_quiesce :: proc(s: ^Simulation) {
	rounds := 0
	for (len(s.packets) > 0 || rounds < 20) && rounds < 200 {
		rounds += 1
		sim_tick_nodes(s)
		for len(s.packets) > 0 {
			sim_step_network_reliable(s)
		}
	}
}

sim_verify :: proc(s: ^Simulation) {
	base_watermark := sqlodin.engine_applied_through(&s.engines[0])
	base_rows, _ := sqlodin.engine_read_snapshot(&s.engines[0], "SELECT count(*) FROM items;")

	for i in 1..<s.node_count {
		w := sqlodin.engine_applied_through(&s.engines[i])
		rows, _ := sqlodin.engine_read_snapshot(&s.engines[i], "SELECT count(*) FROM items;")
		assert(w == base_watermark, "Replica applied watermark mismatch")
		assert(rows == base_rows, "Replica table row count mismatch")
	}
}

main :: proc() {
	node_count := 3
	steps := 1000
	seed: u64 = 42

	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--nodes=") {
			n, _ := strconv.parse_int(arg[8:])
			if n >= 1 && n <= MAX_NODES do node_count = n
		}
		if strings.has_prefix(arg, "--steps=") {
			s, _ := strconv.parse_int(arg[8:])
			if s > 0 do steps = s
		}
		if strings.has_prefix(arg, "--seed=") {
			sd, _ := strconv.parse_u64(arg[7:])
			if sd != 0 do seed = sd
		}
	}

	sim := new(Simulation)
	defer free(sim)

	sim_init(sim, node_count, seed)
	defer sim_close(sim)

	for _ in 0..<steps {
		action := prng_int_max(&sim.prng, 10)
		switch {
		case action < 4:
			sim_propose_random(sim)
		case action < 8:
			sim_step_network(sim)
		case:
			sim_tick_nodes(sim)
		}
	}

	sim_quiesce(sim)
	sim_verify(sim)

	fmt.printf(
		"PASS simulation: nodes=%d, seed=%d, steps=%d, applied=%d, Crashes=%d\n",
		node_count, seed, steps, sqlodin.engine_applied_through(&sim.engines[0]), sim.crashes,
	)
}
