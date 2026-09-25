package tests

import "core:encoding/json"
import "core:testing"
import service "../service"
import sql "../src"
import durable "../src/durable"

read_batch_client :: proc(c: ^service.Connection, statement: string = "SELECT 1") {
	id := sql.Request_Id{sequence = 1}
	id.session[0] = 1
	c.value, _ = sql.mutation_make_transaction(1, id, statement)
	c.state, c.pending = .Ready, .Read
}

// An authenticated peer link; enqueue only buffers frames, so no TLS is needed.
read_batch_peer :: proc(c: ^service.Connection, id: sql.Node_Id) {
	c.state, c.peer, c.hello = .Ready, id, true
}

read_batch_reply :: proc(s: ^service.Server, peer: ^service.Connection, token, frontier: u64) {
	_ = service.receive_frontier(s, peer, service.Request{op = "frontier_reply",
		sequence = token, frontier = frontier})
}

read_batch_free :: proc(s: ^service.Server) {
	for &c in s.connections do for frame in c.out do if frame != nil { delete(frame) }
	free(s)
}

read_batch_settle :: proc(t: ^testing.T, c: ^Durable_Test, silent: int = -1) {
	for _ in 0..<8 {
		durable_test_drain(t, c, silent)
		for h, i in c.hosts do if h != nil && i != silent {
			testing.expect(t, durable.progress(h) == .None)
		}
	}
	durable_test_drain(t, c, silent)
}

@(test)
test_read_cohort_requires_quorum_and_preserves_other_waiters_on_cancel :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	s := new(service.Server)
	defer read_batch_free(s)
	s.host = c.hosts[0]
	peer := &s.connections[20]
	read_batch_peer(peer, 2)
	read_batch_client(&s.connections[0])
	read_batch_client(&s.connections[1])
	testing.expect(t, service.begin_read_cohort(s))
	ticket := s.read_cohort
	testing.expect(t, ticket.token != 0 && s.connections[0].ticket == s.connections[1].ticket)
	testing.expect(t, peer.out_count == 1) // the frontier request
	// Without a peer frontier the cohort has no quorum and answers nobody.
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[0].out_count == 0 && s.connections[1].out_count == 0)
	read_batch_client(&s.connections[2])
	testing.expect(t, service.begin_read_cohort(s))
	testing.expect(t, s.connections[2].ticket.token == 0)
	service.release_read(s, &s.connections[0])
	s.connections[0].pending = .None
	testing.expect(t, s.read_cohort == ticket)
	// A reply for another cohort does not count.
	read_batch_reply(s, peer, ticket.token + 7, 0)
	testing.expect(t, !s.frontier_ready)
	read_batch_reply(s, peer, ticket.token, sql.node_highest_seen(&c.hosts[1].node))
	testing.expect(t, s.frontier_ready)
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[1].out_count == 1 && s.connections[2].out_count == 0)
	testing.expect(t, service.begin_read_cohort(s))
	testing.expect(t, s.read_cohort.token != 0 && s.read_cohort.token != ticket.token)
	service.release_read(s, &s.connections[2])
	s.connections[2].pending = .None
	testing.expect(t, s.read_cohort.token == 0)
}

@(test)
test_read_cohort_waits_for_frontier_above_write_acknowledged_elsewhere :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	schema, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE value(v); INSERT INTO value VALUES(0)")
	_, err := durable.propose(c.hosts[0], schema)
	testing.expect(t, err == .None)
	read_batch_settle(t, c)
	// Voters 2 and 3 choose and apply the write while voter 1 hears nothing.
	update, _ := sql.mutation_make_raw_sql(2, 0, "UPDATE value SET v=1")
	slot, write_err := durable.propose(c.hosts[1], update)
	testing.expect(t, write_err == .None)
	read_batch_settle(t, c, silent = 0)
	testing.expect(t, durable.acknowledged(c.hosts[1], slot, &update))
	testing.expect(t, c.hosts[0].engine.applied_through < slot)

	s := new(service.Server)
	defer read_batch_free(s)
	s.host = c.hosts[0]
	peer := &s.connections[20]
	read_batch_peer(peer, 2)
	read_batch_client(&s.connections[0], "SELECT v FROM value")
	testing.expect(t, service.begin_read_cohort(s))
	read_batch_reply(s, peer, s.read_cohort.token, sql.node_highest_seen(&c.hosts[1].node))
	testing.expect(t, s.frontier_ready && s.frontier_high >= slot)
	// The quorum frontier covers the acknowledged write: no stale answer.
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[0].out_count == 0)
	testing.expect(t, durable.catch_up(c.hosts[0], 2) == .None)
	read_batch_settle(t, c)
	testing.expect(t, c.hosts[0].engine.applied_through >= slot)
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[0].out_count == 1)
	response: service.Response
	testing.expect(t, json.unmarshal(s.connections[0].out[0][4:], &response,
		allocator = context.temp_allocator) == nil)
	testing.expect(t, len(response.rows) == 1 && response.rows[0][0].integer == 1)
}

@(test)
test_read_cohort_single_voter_needs_no_peer :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1, true)
	defer durable_test_close(c)
	transaction_test_schema(t, c.hosts[0], "CREATE TABLE value(v); INSERT INTO value VALUES(5)")
	s := new(service.Server)
	defer read_batch_free(s)
	s.host = c.hosts[0]
	read_batch_client(&s.connections[0], "SELECT v FROM value")
	testing.expect(t, service.begin_read_cohort(s))
	testing.expect(t, s.frontier_ready)
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[0].out_count == 1)
}
