package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sqlodin "../src"
import host "../internal/inmemory"

Profile :: struct {
	mode: string,
	iterations, warmup, batch, payload_bytes: int,
}

Result :: struct {
	mode: string,
	iterations, warmup, batch, payload_bytes, replicas: int,
	seconds, ops_per_second: f64,
	batch_p50_us, batch_p95_us, batch_p99_us: f64,
	mutation_bytes, cluster_bytes, packet_bytes, peak_queued_packets: int,
	initial_queue_capacity: int,
	verified: bool,
}

profile_arg :: proc(arg, prefix: string, fallback: int) -> int {
	if !strings.has_prefix(arg, prefix) do return fallback
	n, ok := strconv.parse_int(arg[len(prefix):])
	if !ok || n < 0 do panic("Invalid benchmark integer")
	return n
}

main :: proc() {
	p := Profile{"multi", 12000, 1200, 1, 256}
	profile := false
	for arg in os.args[1:] {
		if arg == "--json" do profile = true
		if strings.has_prefix(arg, "--mode=") do p.mode = arg[7:]
		p.iterations = profile_arg(arg, "--iterations=", p.iterations)
		p.warmup = profile_arg(arg, "--warmup=", p.warmup)
		p.batch = profile_arg(arg, "--batch=", p.batch)
		p.payload_bytes = profile_arg(arg, "--payload-bytes=", p.payload_bytes)
	}
	if !profile {
		legacy_main()
		return
	}
	if p.iterations < 1 || p.batch < 1 || p.batch > 16 || p.payload_bytes > 256 ||
		p.iterations % p.batch != 0 || p.warmup % p.batch != 0 {
		panic("Use positive iterations, batch 1..16, payload 0..256 and whole batches")
	}
	if p.mode != "multi" && p.mode != "single" && p.mode != "sqlite" do panic("Invalid mode")
	result := profile_run(p)
	encoded, err := json.marshal(result)
	if err != nil do panic("JSON encoding failed")
	defer delete(encoded)
	fmt.println(string(encoded))
}

profile_mutation :: proc(i, idx: int, payload: string) -> sqlodin.Mutation {
	m, err := sqlodin.mutation_make_insert(sqlodin.Node_Id(idx + 1), 0, u64(i + 1), "bench")
	host.must(err)
	host.must(sqlodin.mutation_add_int(&m, "v", i64(i)))
	if len(payload) > 0 do host.must(sqlodin.mutation_add_text(&m, "p", payload))
	return m
}

profile_sqlite_batch :: proc(p: Profile, e: ^sqlodin.Engine, base: int, payload: string) {
	mutations: [16]sqlodin.Mutation
	entries: [16]sqlodin.Committed(sqlodin.Mutation)
	for j in 0..<p.batch {
		mutations[j] = profile_mutation(base + j, 0, payload)
		entries[j] = {sqlodin.Slot(base + j + 1), &mutations[j]}
	}
	host.must(sqlodin.engine_apply_batch(e, entries[:p.batch]))
}

profile_batch :: proc(p: Profile, c: ^host.Cluster, e: ^sqlodin.Engine, base: int, payload: string) {
	if c == nil {
		profile_sqlite_batch(p, e, base, payload)
		return
	}
	// Replicated proposals do not need the local-baseline's temporary batch storage.
	for j in 0..<p.batch {
		i := base + j
		idx := i % host.N if p.mode == "multi" else 0
		m := profile_mutation(i, idx, payload)
		_, err := sqlodin.node_propose(&c.nodes[idx], m, &c.effects[idx])
		host.must(err)
		host.flush(c, idx)
	}
	host.drain(c)
}

profile_verify :: proc(e: ^sqlodin.Engine, total, payload_bytes: int) {
	if e.applied_through != sqlodin.Slot(total) do panic("Applied prefix mismatch")
	buf: [512]u8
	condition := "p IS NULL"
	payload: [256]u8
	for &b in payload do b = 'x'
	if payload_bytes > 0 {
		condition = fmt.bprintf(buf[:], "p='%s'", string(payload[:payload_bytes]))
	}
	query := fmt.aprintf("SELECT id FROM bench WHERE v=id-1 AND %s;", condition)
	defer delete(query)
	rows, err := sqlodin.engine_read_snapshot(e, query)
	host.must(err)
	if rows != total do panic("Replica value verification failed")
	rows, err = sqlodin.engine_read_snapshot(e, "SELECT id FROM bench;")
	host.must(err)
	if rows != total do panic("Replica row count mismatch")
}

profile_run :: proc(p: Profile) -> Result {
	c: ^host.Cluster
	e: sqlodin.Engine
	if p.mode == "sqlite" {
		var_err: sqlodin.Error
		e, var_err = sqlodin.engine_open(":memory:", 1, memory = true)
		host.must(var_err)
	} else {
		c = host.create(p.mode == "multi")
	}
	defer {
		if c == nil do sqlodin.engine_close(&e)
		else do host.destroy(c)
	}
	engines := c.engines[:] if c != nil else slice.from_ptr(&e, 1)
	for &engine in engines {
		host.must(sqlodin.engine_exec(&engine,
			"CREATE TABLE bench (id INTEGER PRIMARY KEY, v INTEGER, p TEXT);"))
	}
	payload: [256]u8
	for &b in payload do b = 'x'
	data := string(payload[:p.payload_bytes])
	for i := 0; i < p.warmup; i += p.batch do profile_batch(p, c, &e, i, data)
	latencies := make([]f64, p.iterations / p.batch)
	defer delete(latencies)
	start := time.now()
	for &latency, i in latencies {
		batch_start := time.now()
		profile_batch(p, c, &e, p.warmup + i * p.batch, data)
		latency = time.duration_seconds(time.since(batch_start)) * 1e6
	}
	elapsed := time.duration_seconds(time.since(start))
	for &engine in engines do profile_verify(&engine, p.warmup + p.iterations, p.payload_bytes)
	slice.sort(latencies)
	r := Result{
		mode = p.mode, iterations = p.iterations, warmup = p.warmup,
		batch = p.batch, payload_bytes = p.payload_bytes, replicas = len(engines),
		seconds = elapsed, ops_per_second = f64(p.iterations) / elapsed,
		mutation_bytes = size_of(sqlodin.Mutation),
		cluster_bytes = size_of(host.Cluster), packet_bytes = size_of(host.Packet), verified = true,
		initial_queue_capacity = host.INITIAL_QUEUE_CAPACITY,
	}
	r.batch_p50_us = latencies[(len(latencies) * 50 - 1) / 100]
	r.batch_p95_us = latencies[(len(latencies) * 95 - 1) / 100]
	r.batch_p99_us = latencies[(len(latencies) * 99 - 1) / 100]
	if c != nil do r.peak_queued_packets = c.max_queued
	return r
}
