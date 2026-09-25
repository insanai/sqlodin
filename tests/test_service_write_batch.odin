package tests

import "core:testing"
import service "../service"
import sql "../src"
import durable "../src/durable"

@(test)
test_service_write_batch_shrinks_without_early_acknowledgement :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	initial: [16]sql.Mutation
	slots: [16]sql.Slot
	for &value in initial do value = sql.mutation_make_skip(0, 0)
	_, err := durable.propose_batch(c.hosts[0], initial[:], slots[:])
	testing.expect(t, err == .None)
	s := new(service.Server)
	defer {
		for &conn in s.connections do for data in conn.out do if data != nil { delete(data) }
		free(s)
	}
	s.host = c.hosts[0]
	for &conn, i in s.connections[:16] {
		id := sql.Request_Id{sequence = 1}
		id.session[0] = u8(i+1)
		conn.value, _ = sql.mutation_make_transaction(1, id, "SELECT 1")
		conn.state, conn.pending = .Ready, .Write
	}
	// Only six owner slots remain in the 64-slot window. The first attempt
	// shrinks 16 -> 8 -> 4, then fills the remainder. A full window is
	// transient: unproposed requests stay pending instead of receiving Busy.
	testing.expect(t, service.admit_writes(s))
	for conn, i in s.connections[:16] {
		testing.expect(t, (conn.slot != 0) == (i < 4))
		testing.expect(t, conn.out_count == 0)
	}
	testing.expect(t, service.admit_writes(s))
	testing.expect(t, service.admit_writes(s))
	testing.expect(t, service.admit_writes(s))
	for &conn, i in s.connections[:16] {
		testing.expect(t, (conn.slot != 0) == (i < 6))
		if i < 6 {
			testing.expect(t, !durable.acknowledged(s.host, conn.slot, &conn.value))
			testing.expect(t, conn.out_count == 0)
		}
	}
	for conn in s.connections[6:16] {
		testing.expect(t, conn.pending == .Write && conn.slot == 0 && conn.out_count == 0)
	}
	for _ in 0..<32 {
		durable_test_drain(t, c)
		for h in c.hosts do testing.expect(t, durable.progress(h) == .None)
	}
	durable_test_drain(t, c)
	for &conn in s.connections[:6] {
		testing.expect(t, durable.acknowledged(s.host, conn.slot, &conn.value))
	}
	testing.expect(t, service.admit_writes(s))
	for conn in s.connections[6:16] do testing.expect(t, conn.slot != 0)
}

@(test)
test_service_write_batch_rotates_before_readmitting_busy_clients :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1, true)
	defer durable_test_close(c)
	s := new(service.Server)
	defer free(s)
	s.host = c.hosts[0]
	for &conn, i in s.connections[:service.MAX_CLIENT_CONNECTIONS] {
		id := sql.Request_Id{sequence = 1}
		id.session[0] = u8(i+1)
		conn.value, _ = sql.mutation_make_transaction(1, id, "SELECT 1")
		conn.state, conn.pending = .Ready, .Write
	}
	testing.expect(t, service.admit_writes(s))
	for &conn in s.connections[:16] {
		testing.expect(t, durable.acknowledged(s.host, conn.slot, &conn.value))
		conn.pending = .None
	}
	// A fast low-index client returns while higher-index clients await admission.
	s.connections[0].value.request.sequence = 2
	s.connections[0].slot, s.connections[0].pending = 0, .Write
	testing.expect(t, service.admit_writes(s))
	for &conn in s.connections[16:service.MAX_CLIENT_CONNECTIONS] {
		testing.expect(t, conn.slot > 0 && conn.slot < s.connections[0].slot)
		testing.expect(t, durable.acknowledged(s.host, conn.slot, &conn.value))
		testing.expect(t, conn.out_count == 0)
	}
}
