// Matched in-process replication + SQLite benchmark. No durable consensus journal,
// transport serialization, sockets, fsync, client forwarding, or WAN latency.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sqlodin "../src"
import host "../internal/inmemory"

SAMPLES :: 3

bench_writes :: proc(iterations: int, ownership: bool) -> f64 {
	c := host.create(ownership)
	defer host.destroy(c)
	for &e in c.engines {
		host.must(sqlodin.engine_exec(&e, "CREATE TABLE bench (id INTEGER PRIMARY KEY, v INTEGER);"))
	}
	start := time.now()
	for i in 0..<iterations {
		idx := i % host.N if ownership else 0
		m, err := sqlodin.mutation_make_insert(sqlodin.Node_Id(idx + 1), 0, u64(i + 1), "bench")
		host.must(err)
		host.must(sqlodin.mutation_add_int(&m, "v", i64(i)))
		_, propose_err := sqlodin.node_propose(&c.nodes[idx], m, &c.effects[idx])
		host.must(propose_err)
		host.flush(c, idx)
		host.drain(c)
	}
	elapsed := time.duration_seconds(time.since(start))
	// Verify completed work outside the timing interval; never count rejected proposals.
	for &e in c.engines {
		if e.applied_through != sqlodin.Slot(iterations) do panic("Benchmark stalled")
		rows, err := sqlodin.engine_read_snapshot(&e, "SELECT id FROM bench WHERE v=id-1;")
		host.must(err)
		if rows != iterations do panic("Benchmark replicas lost or corrupted data")
	}
	return elapsed
}

bench_search :: proc(iterations: int, vector: bool) -> f64 {
	e, err := sqlodin.engine_open(":memory:", 1, memory = true)
	host.must(err)
	defer sqlodin.engine_close(&e)
	query: string
	if vector {
		host.must(sqlodin.engine_exec(&e, "CREATE VIRTUAL TABLE vtab USING vec0(emb float[4]);"))
		host.must(sqlodin.engine_exec(&e,
		"INSERT INTO vtab (rowid, emb) VALUES (1, '[0.1,0.2,0.3,0.4]');"))
		query = "SELECT rowid FROM vtab WHERE emb MATCH '[0.12,0.22,0.32,0.42]' " +
			"ORDER BY distance LIMIT 1;"
	} else {
		host.must(sqlodin.engine_exec(&e, "CREATE VIRTUAL TABLE ftab USING fts5(text);"))
		host.must(sqlodin.engine_exec(&e, "INSERT INTO ftab VALUES ('multi-master consensus');"))
		query = "SELECT * FROM ftab WHERE ftab MATCH 'consensus';"
	}
	start := time.now()
	for _ in 0..<iterations {
		rows, read_err := sqlodin.engine_read_snapshot(&e, query)
		host.must(read_err)
		if rows != 1 do panic("Search returned an unexpected result")
	}
	return time.duration_seconds(time.since(start))
}

legacy_main :: proc() {
	iterations := 10000
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--iterations=") {
			n, ok := strconv.parse_int(arg[13:])
			if !ok || n <= 0 do panic("--iterations must be positive")
			iterations = n
		}
	}
	fmt.println("SQLODIN IN-PROCESS BENCHMARK (3 SQLite replicas, median of 3 samples)")
	fmt.println("Includes payload copies, consensus, and all replica SQL applications.")
	fmt.println("Excludes journal/fsync, sockets, encoding, and WAN/client forwarding latency.")
	fmt.printf("Mutation: %d bytes; node (W=64,C=16): %d bytes; effects: %d bytes\n",
		size_of(sqlodin.Mutation),
		size_of(sqlodin.MultiMaster_Node(sqlodin.Mutation, 3, 64, 16, .Host_Managed)),
		size_of(sqlodin.Effects(sqlodin.Mutation, 3, 64, 16, .Host_Managed)))
	fmt.printf("Shared harness: %d bytes plus its packet queue and SQLite allocations.\n",
		size_of(host.Cluster))
	for ownership in ([?]bool{true, false}) {
		samples: [SAMPLES]f64
		for &sample in samples do sample = bench_writes(iterations, ownership)
		slice.sort(samples[:])
		label := "Multi-Master Writes" if ownership else "Single-Leader Writes"
		fmt.printf("%s: %.2f ops/sec (%.3f us/op); range %.2f..%.2f ops/sec\n",
			label, f64(iterations) / samples[1], samples[1] * 1e6 / f64(iterations),
			f64(iterations) / samples[2], f64(iterations) / samples[0])
	}
	fmt.printf("Vector search (one row, 4 dims): %.2f queries/sec\n",
		f64(iterations) / bench_search(iterations, true))
	fmt.printf("FTS5 search (one row): %.2f queries/sec\n",
		f64(iterations) / bench_search(iterations, false))
}
