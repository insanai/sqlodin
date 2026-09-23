// Embedded durable-host measurement, not a network database-server benchmark.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"
import sql "../../src"
import durable "../../src/durable"
import db "../../src/sqlite"

Operation :: struct { kind, sql: string }
Manifest :: struct {
	setup: []string,
	warmup: []Operation,
	operations: []Operation,
	invariant_sql: string,
	expected: []i64,
}
Result :: struct {
	operations, writes, reads: int,
	seconds, operations_per_second: f64,
	latencies_ms: []f64,
	reopen_ms: f64,
	verified: bool,
}

must :: proc(ok: bool) { if !ok do panic("durable workload check failed") }

drain :: proc(hosts: [3]^durable.Host) {
	for _ in 0..<1000 {
		count := 0
		for h in hosts {
			p: durable.Packet
			for durable.pop(h, &p) {
				must(durable.step(hosts[int(p.env.to) - 1], durable.envelope(&p)) == .None)
				count += 1
			}
		}
		if count == 0 do return
	}
	panic("network did not settle")
}

execute :: proc(hosts: [3]^durable.Host, operation: Operation, index: int) {
	h := hosts[index % 3]
	if operation.kind == "read" {
		_, err := sql.engine_read_snapshot(&h.engine, operation.sql)
		must(err == .None)
		return
	}
	m, err := sql.mutation_make_raw_sql(h.node.id, 0, operation.sql)
	must(err == .None)
	slot, e := durable.propose(h, m)
	must(e == .None)
	drain(hosts)
	for _ in 0..<200 {
		out, complete, read_err := durable.outcome(h, slot, &m)
		must(read_err == .None)
		if complete {
			if out.kind != .Applied {
				fmt.eprintf("workload operation %d rejected: %v, sqlite=%d\n",
					index, out.kind, out.sqlite_code)
			}
			must(out.kind == .Applied)
			return
		}
		for node in hosts do must(durable.tick(node) == .None)
		drain(hosts)
	}
	panic("proposal was not acknowledged")
}

verify :: proc(hosts: [3]^durable.Host, m: Manifest) {
	for h in hosts {
		reader := sql.Engine{db = h.engine.read_db}
		s, err := sql.engine_prepare(&reader, m.invariant_sql)
		must(err == .None)
		must(db.sqlite3_step(s) == db.ROW)
		for expected, i in m.expected {
			must(db.sqlite3_column_int64(s, i32(i)) == expected)
		}
		db.sqlite3_finalize(s)
	}
}

run :: proc(dir: string, m: Manifest) -> Result {
	ids := [3]sql.Node_Id{1, 2, 3}
	hosts: [3]^durable.Host
	paths: [3]string
	defer for h in hosts do durable.close(h)
	defer for path in paths do delete(path)
	for id, i in ids {
		paths[i] = fmt.aprintf("%s/node-%d.db", dir, i)
		h, err := durable.open(paths[i], "realworld", id, ids[:], create = true)
		must(err == .None)
		hosts[i] = h
	}
	for text, i in m.setup do execute(hosts, {"write", text}, i)
	for op, i in m.warmup do execute(hosts, op, i)
	r := Result{operations = len(m.operations), latencies_ms = make([]f64, len(m.operations))}
	started := time.now()
	for op, i in m.operations {
		before := time.now()
		execute(hosts, op, i)
		r.latencies_ms[i] = time.duration_seconds(time.since(before)) * 1000
		if op.kind == "write" do r.writes += 1
		else do r.reads += 1
	}
	r.seconds = time.duration_seconds(time.since(started))
	r.operations_per_second = f64(r.operations) / r.seconds
	verify(hosts, m)
	for h in hosts do durable.close(h)
	started = time.now()
	for id, i in ids {
		h, err := durable.open(paths[i], "realworld", id, ids[:])
		must(err == .None)
		hosts[i] = h
	}
	verify(hosts, m)
	r.reopen_ms = time.duration_seconds(time.since(started)) * 1000
	r.verified = true
	return r
}

main :: proc() {
	must(len(os.args) == 3)
	data, ok := os.read_entire_file(os.args[1], context.allocator)
	must(ok == nil)
	defer delete(data)
	manifest: Manifest
	must(json.unmarshal(data, &manifest) == nil)
	r := run(os.args[2], manifest)
	encoded, err := json.marshal(r)
	must(err == nil)
	fmt.println(string(encoded))
}
