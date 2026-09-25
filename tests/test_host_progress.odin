package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

@(test)
test_idle_owners_finish_without_timer_ticks :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	m, _ := sql.mutation_make_raw_sql(3, 0, "CREATE TABLE immediate(v);")
	slot, err := durable.propose(c.hosts[2], m)
	testing.expect(t, err == .None)
	for _ in 0..<8 {
		durable_test_drain(t, c)
		for h in c.hosts do testing.expect(t, durable.progress(h) == .None)
	}
	durable_test_drain(t, c)
	testing.expect(t, durable.acknowledged(c.hosts[2], slot, &m))
	for h in c.hosts {
		testing.expect(t, h.engine.applied_through >= slot)
		testing.expect_value(t, h.node.election_ticks, u32(0))
		testing.expect_value(t, h.node.stall_ticks, u32(0))
	}
}

@(test)
test_rejoin_beyond_window_without_new_client_traffic :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	// Keep voter 3 disconnected through several complete ring-buffer turns.
	for _ in 0..<90 {
		_, err := durable.propose(c.hosts[0], sql.mutation_make_skip(0, 0))
		testing.expect(t, err == .None)
		for _ in 0..<16 {
			for h in c.hosts[:2] do testing.expect(t, durable.tick(h) == .None)
			durable_test_drain(t, c, 2)
		}
	}
	target := c.hosts[0].engine.applied_through
	testing.expect(t, target > 2 * durable.WINDOW)
	durable_test_reopen(t, c, 2, 3)
	// Catch-up is driven explicitly, with no new proposal and no logical tick.
	for _ in 0..<100 {
		if c.hosts[2].engine.applied_through >= target do break
		testing.expect(t, durable.catch_up(c.hosts[2], 1) == .None)
		durable_test_drain(t, c)
	}
	testing.expect(t, c.hosts[2].engine.applied_through >= target)
	durable_test_reopen(t, c, 2, 3)
	testing.expect(t, c.hosts[2].engine.applied_through >= target)
}
