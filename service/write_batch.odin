package service

import sql "../src"
import durable "../src/durable"

// At most sixteen already-received requests share a durability transition.
// There is no batching timer and no extra queue: connections own their values.
// Paxos admits each attempted batch atomically; shrink on window pressure so
// a small available suffix still makes progress. A Busy response is sent only
// for requests that have not been proposed, preserving retry/unknown semantics:
// immediately for history-space pressure, at the request timeout for a full window.
admit_writes :: proc(s: ^Server) -> bool {
	values: [durable.CHUNK]sql.Mutation
	slots: [durable.CHUNK]sql.Slot
	clients: [durable.CHUNK]^Connection
	indexes: [durable.CHUNK]int
	count := 0
	for offset in 0..<len(s.connections) {
		index := (s.write_cursor + offset) % len(s.connections)
		c := &s.connections[index]
		if c.state != .Ready || c.pending != .Write || c.slot != 0 do continue
		values[count], clients[count], indexes[count] = c.value, c, index
		count += 1
		if count == len(values) do break
	}
	if count == 0 do return true
	for count > 0 {
		assigned, err := durable.propose_batch(s.host, values[:count], slots[:count])
		if err == .Backpressure {
			if count > 1 { count /= 2; continue }
			// A full window is transient: keep the unproposed request pending.
			// drive_connection still answers Busy if its own timeout expires.
			if durable.backpressure_transient(s.host) do return true
			clients[0].pending = .None
			s.write_cursor = (indexes[0] + 1) % len(s.connections)
			if !respond(s, clients[0], "Busy") do connection_close(s, clients[0])
			s.work_ready = true
			return true
		}
		if err != .None || len(assigned) != count { s.fatal = true; return false }
		for slot, i in assigned do clients[i].slot = slot
		s.write_cursor = (indexes[count-1] + 1) % len(s.connections)
		s.work_ready = true
		return true
	}
	return true
}
