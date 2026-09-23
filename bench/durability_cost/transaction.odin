package main

import sql "../../src"
import durable "../../src/durable"

// Each row is an independent, retry-safe transaction, including in batch-16.
// Hosts run serially here. This isolates proposal batching, not network concurrency.
transaction_writes :: proc(c: ^Cluster, first, count, batch: int, payload: string) {
	values := c.requests
	slots: [3][durable.CHUNK]sql.Slot
	for start := first; start < first + count; start += batch * c.count {
		counts: [3]int
		for i in start..<min(start + batch * c.count, first + count) {
			node := (i - start) % c.count
			id := sql.Request_Id{sequence = 1}
			for j in 0..<8 do id.session[j] = u8(u64(i + 1) >> uint(j * 8))
			m, err := sql.mutation_make_transaction(sql.Node_Id(node + 1), id,
				"INSERT INTO t VALUES(?1,?2)")
			must(err == .None)
			must(sql.transaction_add_int(&m, i64(i)) == .None)
			must(sql.transaction_add_text(&m, payload) == .None)
			values[node][counts[node]] = m
			counts[node] += 1
		}
		for h, node in c.hosts[:c.count] {
			if counts[node] == 0 do continue
			assigned, err := durable.propose_batch(h, values[node][:counts[node]], slots[node][:])
			must(err == .None && len(assigned) == counts[node])
		}
		drain(c)
		for retry in 0..<200 {
			complete := true
			for h, node in c.hosts[:c.count] {
				for slot, i in slots[node][:counts[node]] {
					if !durable.acknowledged(h, slot, &values[node][i]) do complete = false
				}
			}
			if complete do break
			must(retry < 199)
			for h in c.hosts[:c.count] do must(durable.tick(h) == .None)
			drain(c)
		}
	}
}
