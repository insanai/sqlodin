package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

transition_group_host: ^durable.Host
transition_group_barriers: int
transition_group_early_packet: bool
transition_group_checkpoint :: proc(point: durable.Fault) {
	if point == .Before_Journal_Commit {
		transition_group_barriers += 1
		p: durable.Packet
		if durable.pop(transition_group_host, &p) do transition_group_early_packet = true
	}
}

transition_group_packets :: proc(t: ^testing.T, packets: []durable.Packet) {
	for &p, i in packets {
		m, err := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v UNIQUE);")
		if i > 0 {
			m = transaction_test_request(t, u64(i), "INSERT INTO t VALUES(?1);")
			testing.expect(t, sql.transaction_add_int(&m, i64(i)) == .None)
		}
		testing.expect(t, err == .None)
		p.value = m
		p.env = {from = 1, to = 2,
			message = sql.Commit_Message(sql.Mutation){u64(i + 1), &p.value}}
	}
}

@(test)
test_transition_group_commit_and_owned_values :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	h := c.hosts[1]
	packets: [16]durable.Packet
	transition_group_packets(t, packets[:])
	transition_group_host = h
	transition_group_barriers, transition_group_early_packet = 0, false
	h.checkpoint = transition_group_checkpoint
	testing.expect(t, durable.step_batch(h, packets[:]) == .None)
	want := 1 if durable.JOURNAL_GROUP_COMMIT else 16
	testing.expect_value(t, transition_group_barriers, want)
	testing.expect(t, !transition_group_early_packet && h.sequence == h.durable_sequence)
	packets = {} // Neither pending messages nor durable records may borrow this input.
	durable_test_reopen(t, c, 1, 3)
	h = c.hosts[1]
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE v BETWEEN 1 AND 15;", 15)
	testing.expect_value(t, h.engine.applied_through, sql.Slot(16))
	for i in 1..<16 {
		out, found, err := sql.engine_outcome(&h.engine, u64(i + 1))
		testing.expect(t, found && err == .None && out.kind == .Applied && out.changes == 1)
	}
}

@(test)
test_transition_group_failure_atomicity :: proc(t: ^testing.T) {
	for fault in ([?]durable.Fault{
		.Before_Journal_Commit, .After_Journal_Commit, .After_Application_Commit,
	}) {
		c := durable_test_open(t, 3)
		h := c.hosts[1]
		packets: [16]durable.Packet
		transition_group_packets(t, packets[:])
		h.fault = fault
		testing.expect(t, durable.step_batch(h, packets[:]) == .Storage && h.poisoned)
		p: durable.Packet
		testing.expect(t, !durable.pop(h, &p))
		durable_test_reopen(t, c, 1, 3)
		want := 16 if durable.JOURNAL_GROUP_COMMIT else 1
		if fault == .Before_Journal_Commit do want = 0
		testing.expect_value(t, c.hosts[1].engine.applied_through, sql.Slot(want))
		if want > 0 do expect_rows(t, &c.hosts[1].engine, "SELECT * FROM t;", want - 1)
		durable_test_close(c)
	}
}

@(test)
test_transition_group_validation_and_storage_failure :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	h := c.hosts[1]
	packets: [16]durable.Packet
	transition_group_packets(t, packets[:])
	packets[15].env.from = 99
	testing.expect(t, durable.step_batch(h, packets[:]) == .Invalid && h.sequence == 0)
	packets[15].env.from = 1
	testing.expect(t, durable.step_batch(h, packets[:0]) == .Invalid)
	testing.expect(t, db.exec(h.engine.db, "PRAGMA query_only=ON"))
	testing.expect(t, durable.step_batch(h, packets[:]) == .Storage && h.poisoned)
	durable_test_reopen(t, c, 1, 3)
	testing.expect_value(t, c.hosts[1].engine.applied_through, sql.Slot(0))
}

@(test)
test_transition_group_copies_borrowed_promise_before_next_vote :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	h := c.hosts[1]
	old := sql.mutation_make_skip(1, 17)
	env := sql.Envelope(sql.Mutation){from = 1, to = 2,
		message = sql.Accept_Message(sql.Mutation){sql.ballot_make(0, 0, 1), 1, &old}}
	testing.expect(t, durable.step(h, env) == .None)
	p: durable.Packet
	for durable.pop(h, &p) {}
	ballot := sql.ballot_make(1, 0, 3)
	packets: [2]durable.Packet
	packets[0].env = {from = 3, to = 2,
		message = sql.Prepare_Message{ballot, 1, 1, .Bounded}}
	packets[1].value = sql.mutation_make_skip(3, 29)
	packets[1].env = {from = 3, to = 2,
		message = sql.Accept_Message(sql.Mutation){ballot, 1, &packets[1].value}}
	testing.expect(t, durable.step_batch(h, packets[:]) == .None)
	packets = {}
	found := false
	for durable.pop(h, &p) {
		if promise, ok := durable.envelope(&p).message.(sql.Promise_Message(sql.Mutation)); ok {
			testing.expect_value(t, promise.value^, old)
			found = true
		}
	}
	testing.expect(t, found)
	durable_test_reopen(t, c, 1, 3)
	vote, value, voted := sql.ledger_vote_at(&c.hosts[1].node.ledger, 1)
	testing.expect(t, voted && vote == ballot)
	if voted do testing.expect_value(t, value^, sql.mutation_make_skip(3, 29))
}
