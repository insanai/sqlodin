package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sqlodin "../src"
import sqlite "../src/sqlite"
import host "../internal/inmemory"

MAX_NODES :: 5
SIM_WINDOW :: 64
SIM_CHUNK :: 16

Sim_Node :: sqlodin.MultiMaster_Node(
	sqlodin.Mutation, MAX_NODES, SIM_WINDOW, SIM_CHUNK, .Enforced,
)
Sim_Effects :: sqlodin.Effects(sqlodin.Mutation, MAX_NODES, SIM_WINDOW, SIM_CHUNK, .Enforced)

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
	crashes:    int,
	issued:     u64,
	admitted:   int,
	max_queued: int,
	durable:    [MAX_NODES]sqlodin.Ledger(sqlodin.Mutation, SIM_WINDOW),
	decisions:  [dynamic]sqlodin.Mutation,
	history:    [MAX_NODES][dynamic]sqlodin.Mutation,
}

sim_init :: proc(s: ^Simulation, node_count: int, seed: u64) {
	s.node_count = node_count
	prng_init(&s.prng, seed)
	s.packets = make([dynamic]Sim_Packet, 0, 512)
	s.decisions = make([dynamic]sqlodin.Mutation)

	ids: [MAX_NODES]sqlodin.Node_Id
	for i in 0..<node_count {
		ids[i] = sqlodin.Node_Id(i + 1)
	}
	host.must(sqlodin.membership_init(&s.membership, ids[:node_count]))

	noop := sqlodin.mutation_make_skip(0, 0)
	for i in 0..<node_count {
		node_id := sqlodin.Node_Id(i + 1)
		host.must(sqlodin.node_init(&s.nodes[i], node_id, s.membership, noop))
		e, open_err := sqlodin.engine_open(":memory:", node_id, memory = true)
		host.must(open_err)
		s.engines[i] = e
		host.must(sqlodin.engine_exec(
			&s.engines[i],
			"CREATE TABLE items (id INTEGER PRIMARY KEY, v INTEGER);",
		))
	}
}

sim_close :: proc(s: ^Simulation) {
	for i in 0..<s.node_count {
		sqlodin.engine_close(&s.engines[i])
	}
	delete(s.packets)
	delete(s.decisions)
	for history in s.history do delete(history)
}

sim_enqueue :: proc(s: ^Simulation, env: sqlodin.Envelope(sqlodin.Mutation)) {
	// Overflow models packet loss and bounds the transport, even during recovery bursts.
	if len(s.packets) >= 512 do return
	val: sqlodin.Mutation
	if value, ok := sqlodin.message_value(env.message); ok do val = value^
	append(&s.packets, Sim_Packet{env = env, val = val})
}

sim_serve_history :: proc(s: ^Simulation, idx: int) {
	for request in sqlodin.effects_requests_slice(&s.effects[idx]) {
		switch r in request {
		case sqlodin.Serve_Range_Request:
			for offset in 0..<int(r.count) {
				slot := r.first + sqlodin.Slot(offset)
				if slot > sqlodin.Slot(len(s.history[idx])) do break
				sim_enqueue(s, sqlodin.Envelope(sqlodin.Mutation){
					from = sqlodin.Node_Id(idx + 1), to = r.peer,
					message = sqlodin.Commit_Message(sqlodin.Mutation){
						slot = slot, value = &s.history[idx][int(slot) - 1],
					},
				})
			}
		}
	}
}

// Models a journal in memory. This tests ordering/replay, not power-loss durability.
sim_drain_node :: proc(s: ^Simulation, idx: int) {
	e := &s.effects[idx]
	for write in sqlodin.effects_writes_slice(e) {
		host.must(sqlodin.ledger_apply(&s.durable[idx], write))
	}
	sqlodin.effects_confirm_writes_durable(e)
	committed := sqlodin.effects_committed_slice(e)
	for entry in committed {
		if int(entry.slot) > len(s.decisions) {
			if int(entry.slot) != len(s.decisions) + 1 do panic("Decision gap")
			append(&s.decisions, entry.value^)
		} else if s.decisions[int(entry.slot) - 1] != entry.value^ {
			panic("Conflicting replicated decision")
		}
	}
	host.must(sqlodin.engine_apply_batch(&s.engines[idx], committed))
	for entry in committed {
		if int(entry.slot) != len(s.history[idx]) + 1 do panic("Host history gap")
		append(&s.history[idx], entry.value^)
	}
	for env in sqlodin.effects_messages_slice(e) do sim_enqueue(s, env)
	sim_serve_history(s, idx)
	s.max_queued = max(s.max_queued, len(s.packets))
	sqlodin.effects_reset(e)
	floor := s.engines[0].applied_through
	for &engine in s.engines[:s.node_count] do floor = min(floor, engine.applied_through)
	for &node in s.nodes[:s.node_count] do host.must(sqlodin.node_advance_memory_floor(&node, floor))
}

sim_restart :: proc(s: ^Simulation) {
	idx := prng_int_max(&s.prng, s.node_count)
	noop := sqlodin.mutation_make_skip(0, 0)
	host.must(sqlodin.node_restore(&s.nodes[idx], sqlodin.Node_Id(idx + 1),
		s.membership, s.durable[idx], noop, s.engines[idx].applied_through))
	s.crashes += 1
}

sim_propose_random :: proc(s: ^Simulation) {
	proposer := prng_int_max(&s.prng, s.node_count)
	node_id := sqlodin.Node_Id(proposer + 1)
	s.issued += 1
	m, err := sqlodin.mutation_make_insert(node_id, 100, s.issued, "items")
	host.must(err)
	host.must(sqlodin.mutation_add_int(&m, "v", i64(s.issued % 1000)))
	_, propose_err := sqlodin.node_propose(&s.nodes[proposer], m, &s.effects[proposer])
	if propose_err == .None {
		s.admitted += 1
	} else if propose_err != .Window_Full && propose_err != .Not_Leader {
		host.must(propose_err)
	}
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
	host.must(sqlodin.node_step(&s.nodes[target], env, &s.effects[target]))
	sim_drain_node(s, target)

	// Simulated duplicate (5%)
	if prng_chance(&s.prng, 50) && len(s.packets) < 512 {
		append(&s.packets, pkt)
	}
}

sim_step_network_reliable :: proc(s: ^Simulation) {
	if len(s.packets) == 0 do return
	pkt := pop(&s.packets)

	target := int(pkt.env.to - 1)
	if target < 0 || target >= s.node_count do return

	env := pkt.env
	#partial switch &m in env.message {
	case sqlodin.Accept_Message(sqlodin.Mutation):  m.value = &pkt.val
	case sqlodin.Commit_Message(sqlodin.Mutation):  m.value = &pkt.val
	case sqlodin.Promise_Message(sqlodin.Mutation): m.value = &pkt.val
	}

	sqlodin.effects_reset(&s.effects[target])
	host.must(sqlodin.node_step(&s.nodes[target], env, &s.effects[target]))
	sim_drain_node(s, target)
}

sim_tick_nodes :: proc(s: ^Simulation) {
	for i in 0..<s.node_count {
		host.must(sqlodin.node_tick(&s.nodes[i], &s.effects[i]))
		sim_drain_node(s, i)
	}
}

sim_quiesce :: proc(s: ^Simulation) {
	rounds := 0
	for (len(s.packets) > 0 || rounds < 100) && rounds < 1000 {
		rounds += 1
		sim_tick_nodes(s)
		for len(s.packets) > 0 {
			sim_step_network_reliable(s)
		}
	}
}

// Hash actual stored values in primary-key order, not the one-row count(*) result.
sim_digest :: proc(e: ^sqlodin.Engine) -> (count: int, hash: u64) {
	stmt, err := sqlodin.engine_prepare(e, "SELECT id, v FROM items ORDER BY id;")
	host.must(err)
	defer sqlite.sqlite3_finalize(stmt)
	hash = 14695981039346656037
	for {
		rc := sqlite.sqlite3_step(stmt)
		if rc == sqlite.DONE do break
		if rc != sqlite.ROW do panic("Digest query failed")
		id := u64(sqlite.sqlite3_column_int64(stmt, 0))
		value := u64(sqlite.sqlite3_column_int64(stmt, 1))
		if value != id % 1000 do panic("Corrupt mutation data")
		hash = (hash ~ id) * 1099511628211
		hash = (hash ~ value) * 1099511628211
		count += 1
	}
	return
}

sim_verify :: proc(s: ^Simulation) {
	watermark := s.engines[0].applied_through
	count, hash := sim_digest(&s.engines[0])
	if s.admitted == 0 || count == 0 do panic("Simulation made no progress")
	for i in 0..<s.node_count {
		rows, digest := sim_digest(&s.engines[i])
		if s.engines[i].applied_through != watermark || rows != count || digest != hash {
			fmt.eprintf("node=%d applied=%d expected=%d rows=%d/%d hash=%d/%d highest=%d floor=%d\n",
				i+1, s.engines[i].applied_through, watermark, rows, count, digest, hash,
				s.nodes[i].highest_seen, s.nodes[i].memory_floor)
			panic("Replica state diverged")
		}
		if s.nodes[i].highest_seen > watermark do panic("Replica stalled after network recovery")
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
			for _ in 0..<8 do sim_step_network(sim)
		case action == 8:
			sim_restart(sim)
		case:
			sim_tick_nodes(sim)
		}
	}

	sim_quiesce(sim)
	sim_verify(sim)

	fmt.printf(
		"PASS simulation: nodes=%d, seed=%d, steps=%d, applied=%d, restarts=%d, max_queue=%d\n",
		node_count, seed, steps, sqlodin.engine_applied_through(&sim.engines[0]),
		sim.crashes, sim.max_queued,
	)
}
