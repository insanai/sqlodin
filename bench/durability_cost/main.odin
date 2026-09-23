// Attribution experiment; preserves FULL durability and does not modify the product host.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import sql "../../src"
import durable "../../src/durable"
import db "../../src/sqlite"

foreign import profiler "../../build/durability-cost/libsync_profile.so"
Stats :: struct { calls, nanos, writes, bytes, write_nanos: u64 }
foreign profiler {
	sync_profile_begin :: proc "c" () ---
	sync_profile_end :: proc "c" (out: ^Stats) ---
}
Cluster :: struct {
	hosts: [3]^durable.Host,
	count: int,
	database: db.Sqlite3,
	requests: ^[3][durable.CHUNK]sql.Mutation,
	incoming: ^[3][durable.MAX_STEP_BATCH]durable.Packet,
}
Result :: struct {
	mode: string,
	rows, rows_per_transaction: int,
	proposal_batch: int,
	seconds, rows_per_second: f64,
	sync: Stats,
	verified: bool,
}

must :: proc(ok: bool) { if !ok do panic("durability cost check failed") }

drain :: proc(c: ^Cluster) {
	for _ in 0..<1000 {
		n := 0
		counts: [3]int
		for h in c.hosts[:c.count] {
			p: durable.Packet
			for durable.pop(h, &p) {
				destination := int(p.env.to) - 1
				c.incoming[destination][counts[destination]] = p
				counts[destination] += 1
				if counts[destination] == durable.MAX_STEP_BATCH {
					must(durable.step_batch(c.hosts[destination],
						c.incoming[destination][:counts[destination]]) == .None)
					counts[destination] = 0
				}
				n += 1
			}
		}
		for count, destination in counts {
			if count > 0 do must(durable.step_batch(c.hosts[destination],
				c.incoming[destination][:count]) == .None)
		}
		if n == 0 do return
	}
	panic("transport did not settle")
}

execute :: proc(c: ^Cluster, text: string, index: int) {
	if c.count == 0 {
		must(db.exec(c.database, text))
		return
	}
	h := c.hosts[index % c.count]
	m, err := sql.mutation_make_raw_sql(h.node.id, 0, text)
	must(err == .None)
	slot, e := durable.propose(h, m)
	must(e == .None)
	drain(c)
	for _ in 0..<200 {
		if durable.acknowledged(h, slot, &m) do return
		for host in c.hosts[:c.count] do must(durable.tick(host) == .None)
		drain(c)
	}
	panic("proposal not acknowledged")
}

open :: proc(dir: string, nodes: int) -> Cluster {
	c := Cluster{count = nodes}
	if nodes > 0 do c.incoming = new([3][durable.MAX_STEP_BATCH]durable.Packet)
	ids := [3]sql.Node_Id{1, 2, 3}
	for i in 0..<max(nodes, 1) {
		path := fmt.aprintf("%s/node-%d.db", dir, i)
		defer delete(path)
		if nodes == 0 {
			database, ok := db.open(path)
			must(ok && db.enable_wal(database))
			c.database = database
		} else {
			h, err := durable.open(path, "cost-review", ids[i], ids[:nodes], create = true)
			must(err == .None)
			c.hosts[i] = h
		}
	}
	execute(&c, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)", 0)
	return c
}

close :: proc(c: ^Cluster) {
	if c.count == 0 do db.close(c.database)
	for h in c.hosts[:c.count] do durable.close(h)
	if c.requests != nil do free(c.requests)
	if c.incoming != nil do free(c.incoming)
}

writes :: proc(c: ^Cluster, first, count, batch: int, payload: string) {
	for i in first..<first+count {
		if c.count == 0 && (i-first) % batch == 0 do must(db.begin_tx(c.database))
		text := fmt.aprintf("INSERT INTO t VALUES(%d,'%s')", i, payload)
		execute(c, text, i)
		delete(text)
		if c.count == 0 && ((i-first+1) % batch == 0 || i+1 == first+count) {
			must(db.commit_tx(c.database))
		}
	}
}

verify :: proc(c: ^Cluster, count: int, payload: string) {
	text := fmt.aprintf("SELECT count(*),count(*) FILTER (WHERE v='%s') FROM t", payload)
	defer delete(text)
	for i in 0..<max(c.count, 1) {
		e := sql.Engine{db = c.database}
		if c.count > 0 do e = c.hosts[i].engine
		s, err := sql.engine_prepare(&e, text)
		must(err == .None && db.sqlite3_step(s) == db.ROW)
		must(db.sqlite3_column_int64(s, 0) == i64(count))
		must(db.sqlite3_column_int64(s, 1) == i64(count))
		db.sqlite3_finalize(s)
	}
}

main :: proc() {
	must(len(os.args) == 5)
	mode, dir := os.args[1], os.args[2]
	rows, ok := strconv.parse_int(os.args[3]); must(ok)
	warmup, good := strconv.parse_int(os.args[4]); must(good)
	nodes, batch, proposal_batch := 0, 1, 1
	transactions := false
	switch mode {
	case "sqlite_full_1":
	case "sqlite_full_32": batch = 32
	case "durable_1": nodes = 1
	case "durable_3": nodes = 3
	case "transaction_1": nodes, transactions = 1, true
	case "transaction_1_batch16": nodes, transactions, proposal_batch = 1, true, 16
	case "transaction_3": nodes, transactions = 3, true
	case "transaction_3_batch16": nodes, transactions, proposal_batch = 3, true, 16
	case: panic("unknown mode")
	}
	payload := strings.repeat("x", 256)
	defer delete(payload)
	c := open(dir, nodes)
	defer close(&c)
	if transactions do c.requests = new([3][durable.CHUNK]sql.Mutation)
	if transactions { transaction_writes(&c, 0, warmup, proposal_batch, payload) }
	else { writes(&c, 0, warmup, batch, payload) }
	r := Result{mode = mode, rows = rows, rows_per_transaction = batch,
		proposal_batch = proposal_batch}
	sync_profile_begin()
	started := time.now()
	if transactions { transaction_writes(&c, warmup, rows, proposal_batch, payload) }
	else { writes(&c, warmup, rows, batch, payload) }
	r.seconds = time.duration_seconds(time.since(started))
	sync_profile_end(&r.sync)
	r.rows_per_second = f64(rows) / r.seconds
	verify(&c, warmup+rows, payload)
	r.verified = true
	encoded, err := json.marshal(r)
	must(err == nil)
	defer delete(encoded)
	fmt.println(string(encoded))
}
