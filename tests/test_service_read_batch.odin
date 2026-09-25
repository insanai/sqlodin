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

read_batch_free :: proc(s: ^service.Server) {
	for &c in s.connections do for frame in c.out do if frame != nil { delete(frame) }
	free(s)
}

@(test)
test_read_cohort_requires_quorum_and_preserves_other_waiters_on_cancel :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	s := new(service.Server)
	defer read_batch_free(s)
	s.host = c.hosts[0]
	read_batch_client(&s.connections[0])
	read_batch_client(&s.connections[1])
	testing.expect(t, service.begin_read_cohort(s))
	ticket := s.read_cohort
	testing.expect(t, ticket.token != 0 && s.connections[0].ticket == s.connections[1].ticket)
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[0].out_count == 0 && s.connections[1].out_count == 0)
	read_batch_client(&s.connections[2])
	testing.expect(t, service.begin_read_cohort(s))
	testing.expect(t, s.connections[2].ticket.token == 0)
	service.release_read(s, &s.connections[0])
	s.connections[0].pending = .None
	testing.expect(t, s.read_cohort == ticket && s.host.active_read == ticket)
	for _ in 0..<8 {
		durable_test_drain(t, c)
		for h in c.hosts do testing.expect(t, durable.progress(h) == .None)
	}
	durable_test_drain(t, c)
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[1].out_count == 1 && s.connections[2].out_count == 0)
	testing.expect(t, service.begin_read_cohort(s))
	testing.expect(t, s.read_cohort.token != 0 && s.read_cohort.token != ticket.token)
	service.release_read(s, &s.connections[2])
	s.connections[2].pending = .None
	testing.expect(t, s.read_cohort.token == 0 && s.host.active_read.token == 0)
}

@(test)
test_later_read_cannot_borrow_cohort_before_a_completed_write :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1, true)
	defer durable_test_close(c)
	transaction_test_schema(t, c.hosts[0], "CREATE TABLE value(v); INSERT INTO value VALUES(0)")
	s := new(service.Server)
	defer read_batch_free(s)
	s.host = c.hosts[0]
	read_batch_client(&s.connections[0], "SELECT v FROM value")
	testing.expect(t, service.begin_read_cohort(s))
	earlier := s.read_cohort
	m, _ := sql.mutation_make_raw_sql(1, 0, "UPDATE value SET v=1")
	out := transaction_test_submit(t, s.host, m)
	testing.expect(t, out.kind == .Applied)
	write_prefix := s.host.engine.applied_through
	read_batch_client(&s.connections[1], "SELECT v FROM value")
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[0].out_count == 1 && s.connections[1].out_count == 0)
	testing.expect(t, service.begin_read_cohort(s))
	testing.expect(t, s.read_cohort.slot > write_prefix && s.read_cohort.token != earlier.token)
	testing.expect(t, service.finish_read_cohort(s))
	testing.expect(t, s.connections[1].out_count == 1)
	response: service.Response
	testing.expect(t, json.unmarshal(s.connections[1].out[0][4:], &response,
		allocator = context.temp_allocator) == nil)
	testing.expect(t, len(response.rows) == 1 && response.rows[0][0].integer == 1)
}
