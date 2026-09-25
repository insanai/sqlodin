package service

import durable "../src/durable"

// Only calls already accepted by the serialized owner can join this cohort.
// Membership closes before proposing its marker; later arrivals need a new one.
begin_read_cohort :: proc(s: ^Server) -> bool {
	if s.read_cohort.token != 0 do return true
	waiting := false
	for &c in s.connections {
		if c.state == .Ready && c.pending == .Read && !c.local_read { waiting = true; break }
	}
	if !waiting do return true
	ticket, err := durable.begin_read(s.host, 0)
	if err == .Backpressure do return true
	if err != .None { s.fatal = true; return false }
	s.read_cohort = ticket
	// begin_read does not dispatch connections; no new invocation can enter
	// between the membership scan above and these assignments.
	for &c in s.connections {
		if c.state == .Ready && c.pending == .Read && !c.local_read { c.ticket = ticket }
	}
	s.work_ready = true
	return true
}

finish_read_cohort :: proc(s: ^Server) -> bool {
	ticket := s.read_cohort
	if ticket.token == 0 do return true
	result, err := durable.poll_read(s.host, ticket, "SELECT 1")
	if err != .None { s.fatal = true; return false }
	if result.status == .Pending do return true
	s.read_cohort = {}
	for &c in s.connections {
		if c.ticket != ticket do continue
		c.ticket = {}
		if result.status == .Displaced do continue
		// No application/consensus transition interleaves these result snapshots.
		if result.sql_error != .None || !read_result(s, &c) do connection_close(s, &c)
	}
	s.work_ready = true
	return true
}

// Dropping one member cannot consume another member's barrier. If all members
// disappear, retire the wait, and require a fresh marker for subsequent calls.
release_read :: proc(s: ^Server, c: ^Connection) {
	ticket := c.ticket
	c.ticket = {}
	if ticket.token == 0 || ticket != s.read_cohort do return
	for &other in s.connections do if other.ticket == ticket { return }
	if s.host != nil do _ = durable.cancel_read(s.host, ticket)
	s.read_cohort = {}
}
