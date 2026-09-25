package service

import "core:time"
import sql "../src"
import durable "../src/durable"

// SOD 0005 M6: a fresh-read cohort crosses a quorum-read barrier instead of
// proposing a marker (after Charapko, Ailijiang and Demirbas, "Linearizable
// Quorum Reads in Paxos"). Membership closes before any frontier is observed.
// This voter's highest seen slot and those of read_quorum - 1 peers, each
// observed after closing, bound every slot chosen before any member's
// invocation: a chosen slot has durable votes from a write quorum, which
// intersects the queried set, and highest_seen is at least every slot this
// voter has durably voted or decided (after restart it resumes above the
// ledger). Members are answered once the contiguous applied prefix reaches
// that bound. No journal write or sync barrier is needed.
FRONTIER_RETRY :: 200 * time.Millisecond

begin_read_cohort :: proc(s: ^Server) -> bool {
	if s.read_cohort.token != 0 do return true
	waiting := false
	for &c in s.connections {
		if c.state == .Ready && c.pending == .Read && !c.local_read { waiting = true; break }
	}
	if !waiting do return true
	s.frontier_token += 1
	ticket := durable.Read_Ticket{token = s.frontier_token}
	s.read_cohort = ticket
	// No connection is dispatched between the membership scan and these assignments.
	for &c in s.connections {
		if c.state == .Ready && c.pending == .Read && !c.local_read { c.ticket = ticket }
	}
	s.frontier_high = sql.node_highest_seen(&s.host.node)
	s.frontier_replies = 0
	s.frontier_ready = sql.membership_read_quorum(&s.host.node.membership) <= 1
	for &c in s.connections do c.frontier_replied = 0
	send_frontier_requests(s)
	s.work_ready = true
	return true
}

send_frontier_requests :: proc(s: ^Server) {
	s.frontier_sent = time.tick_now()
	for &c in s.connections {
		if c.state != .Ready || !c.hello || c.peer == 0 || c.snapshot_sending ||
		   c.frontier_replied == s.read_cohort.token { continue }
		_ = enqueue(&c, Request{op = "frontier", cluster = s.config.cluster, protocol = PROTOCOL,
			sequence = s.read_cohort.token})
	}
}

// A peer reports its frontier at the time it handles the request, which is
// after the requesting cohort closed.
respond_frontier :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	return enqueue(c, Request{op = "frontier_reply", cluster = s.config.cluster, protocol = PROTOCOL,
		sequence = r.sequence, frontier = sql.node_highest_seen(&s.host.node)})
}

receive_frontier :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	token := s.read_cohort.token
	if token == 0 || r.sequence != token || s.frontier_ready || c.frontier_replied == token {
		return true // A reply for a finished or cancelled cohort is harmless.
	}
	c.frontier_replied = token
	s.frontier_high = max(s.frontier_high, r.frontier)
	s.frontier_replies += 1
	if s.frontier_replies >= sql.membership_read_quorum(&s.host.node.membership) - 1 {
		s.frontier_ready = true
	}
	s.work_ready = true
	return true
}

finish_read_cohort :: proc(s: ^Server) -> bool {
	ticket := s.read_cohort
	if ticket.token == 0 do return true
	if !s.frontier_ready {
		if time.tick_since(s.frontier_sent) >= FRONTIER_RETRY do send_frontier_requests(s)
		return true
	}
	if s.host.poisoned { s.fatal = true; return false }
	if s.host.engine.applied_through < s.frontier_high do return true
	s.read_cohort = {}
	for &c in s.connections {
		if c.ticket != ticket do continue
		c.ticket = {}
		// No application/consensus transition interleaves these result snapshots.
		if !read_result(s, &c) do connection_close(s, &c)
	}
	s.work_ready = true
	return true
}

// Dropping one member cannot consume another member's barrier. If all members
// disappear, retire the cohort; subsequent calls need a new frontier.
release_read :: proc(s: ^Server, c: ^Connection) {
	ticket := c.ticket
	c.ticket = {}
	if ticket.token == 0 || ticket != s.read_cohort do return
	for &other in s.connections do if other.ticket == ticket { return }
	s.read_cohort = {}
}
