package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

// Each prepare reports sixteen borrowed values. Sixteen such transitions exceed
// the ownership workspace, so the host must commit a prefix before continuing.
@(test)
test_transition_group_flushes_before_effect_capacity :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	h := c.hosts[1]
	ballot := sql.ballot_make(1, 0, 1)
	prepare := sql.Envelope(sql.Mutation){from = 1, to = 2,
		message = sql.Prepare_Message{ballot, 1, 16, .Global}}
	testing.expect(t, durable.step(h, prepare) == .None)
	packets: [16]durable.Packet
	for &p, i in packets {
		p.value = sql.mutation_make_skip(1, u64(i + 101))
		p.env = {from = 1, to = 2,
			message = sql.Accept_Message(sql.Mutation){ballot, u64(i + 1), &p.value}}
	}
	testing.expect(t, durable.step_batch(h, packets[:]) == .None)
	packet: durable.Packet
	for durable.pop(h, &packet) {}
	for &p, i in packets {
		p.env = {from = 3, to = 2,
			message = sql.Prepare_Message{sql.ballot_make(u64(i + 2), 0, 3), 1, 16, .Global}}
	}
	testing.expect(t, durable.step_batch(h, packets[:]) == .None)
	reports := 0
	for durable.pop(h, &packet) {
		if p, ok := durable.envelope(&packet).message.(sql.Promise_Message(sql.Mutation)); ok {
			testing.expect_value(t, p.value.timestamp_ms, p.slot + 100)
			reports += 1
		}
	}
	testing.expect_value(t, reports, 16 * 16)
	durable_test_reopen(t, c, 1, 3)
	testing.expect_value(t, c.hosts[1].node.ledger.promised, sql.ballot_make(17, 0, 3))
}
