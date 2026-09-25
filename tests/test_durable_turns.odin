package tests

import "core:testing"
import "core:os"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

// SOD 0005 M1: every transition of a turn shares one journal barrier and
// nothing leaves the host before it.
@(test)
test_durable_turn_shares_one_barrier :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	h := c.hosts[0]
	values: [4]sql.Mutation
	slots: [4]sql.Slot
	for &value, i in values {
		value = transaction_test_request(t, u64(i + 1), "SELECT 1")
	}
	transition_group_host = h
	transition_group_barriers, transition_group_early_packet = 0, false
	h.checkpoint = transition_group_checkpoint
	testing.expect(t, durable.turn_begin(h) == .None)
	_, err := durable.propose_batch(h, values[:2], slots[:2])
	testing.expect(t, err == .None)
	_, err = durable.propose_batch(h, values[2:], slots[2:])
	testing.expect(t, err == .None)
	testing.expect(t, durable.progress(h) == .None)
	testing.expect(t, durable.tick(h) == .None)
	when durable.JOURNAL_GROUP_COMMIT {
		p: durable.Packet
		testing.expect(t, !durable.pop(h, &p))
	}
	testing.expect(t, durable.turn_commit(h) == .None)
	h.checkpoint = nil
	want := 1 if durable.JOURNAL_GROUP_COMMIT else 4
	testing.expect(t, transition_group_barriers <= want && transition_group_barriers >= 1)
	testing.expect(t, !transition_group_early_packet && h.sequence == h.durable_sequence)
	read_batch_settle(t, c)
	for slot, i in slots {
		testing.expect(t, durable.acknowledged(h, slot, &values[i]))
	}
	// A turn with no transitions writes nothing.
	sequence := h.sequence
	testing.expect(t, durable.turn_begin(h) == .None && durable.turn_commit(h) == .None)
	testing.expect_value(t, h.sequence, sequence)
}

// Deliver only host `from`'s Accept packets to host `to` in one step_batch.
turn_test_accepts :: proc(t: ^testing.T, c: ^Durable_Test, from, to: int, relay: sql.Node_Id = 0) {
	packets: [durable.MAX_STEP_BATCH]durable.Packet
	count := 0
	p: durable.Packet
	for durable.pop(c.hosts[from], &p) {
		if int(p.env.to) - 1 != to do continue
		if _, is_accept := p.env.message.(sql.Accept_Message(sql.Mutation)); !is_accept do continue
		if relay != 0 do p.env.from = relay
		packets[count] = p
		count += 1
	}
	testing.expect(t, count > 0)
	testing.expect(t, durable.step_batch(c.hosts[to], packets[:count]) == .None)
}

turn_test_decided :: proc(h: ^durable.Host, slot: sql.Slot) -> bool {
	_, chosen := sql.ledger_chosen_at(&h.node.ledger, slot)
	return chosen || h.engine.applied_through >= slot
}

// SOD 0005 M2: an owner's round-zero no-op is decided on receipt, before the
// owner has counted any vote or sent a Commit.
@(test)
test_durable_fast_learns_owner_noop :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	slot, err := durable.propose(c.hosts[1], sql.mutation_make_skip(0, 0))
	testing.expect(t, err == .None)
	turn_test_accepts(t, c, 1, 0)
	when durable.JOURNAL_GROUP_COMMIT {
		testing.expect(t, turn_test_decided(c.hosts[0], slot))
	}
	read_batch_settle(t, c)
}

// SOD 0005 M5: with three voters, this voter's durable round-zero vote plus
// the owner's is a write quorum, so the value is decided at this barrier.
@(test)
test_durable_fast_learns_owner_value_with_own_vote :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	value := transaction_test_request(t, 1, "SELECT 1")
	slot, err := durable.propose(c.hosts[1], value)
	testing.expect(t, err == .None)
	turn_test_accepts(t, c, 1, 2)
	when durable.JOURNAL_GROUP_COMMIT {
		testing.expect(t, turn_test_decided(c.hosts[2], slot))
	}
	testing.expect(t, !turn_test_decided(c.hosts[1], slot)) // the owner still needs a reply
	read_batch_settle(t, c)
	testing.expect(t, durable.acknowledged(c.hosts[1], slot, &value))
}

// A relayed Accept is not the owner's own suggestion and never learns early.
@(test)
test_durable_no_fast_learning_from_relayed_accept :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, true)
	defer durable_test_close(c)
	slot, err := durable.propose(c.hosts[1], sql.mutation_make_skip(0, 0))
	testing.expect(t, err == .None)
	turn_test_accepts(t, c, 1, 0, relay = 3)
	testing.expect(t, !turn_test_decided(c.hosts[0], slot))
}

turn_test_synchronous :: proc(t: ^testing.T, database: db.Sqlite3) -> i64 {
	query := "PRAGMA synchronous"
	stmt: db.Sqlite3_Stmt
	testing.expect(t, db.sqlite3_prepare_v2(database, cstring(raw_data(query)), i32(len(query)),
		&stmt, nil) == db.OK)
	defer db.sqlite3_finalize(stmt)
	testing.expect(t, db.sqlite3_step(stmt) == db.ROW)
	return db.sqlite3_column_int64(stmt, 0)
}

// SOD 0005 M4: only the separated application database is a journal-backed cache.
@(test)
test_durable_application_cache_mode :: proc(t: ^testing.T) {
	separated := durable_test_open(t, 1, true)
	defer durable_test_close(separated)
	testing.expect_value(t, turn_test_synchronous(t, separated.hosts[0].engine.db), 1)
	testing.expect_value(t, turn_test_synchronous(t, separated.hosts[0].consensus), 2)
	durable_test_reopen(t, separated, 0, 1)
	testing.expect_value(t, turn_test_synchronous(t, separated.hosts[0].engine.db), 1)
	combined := durable_test_open(t, 1)
	defer durable_test_close(combined)
	testing.expect_value(t, turn_test_synchronous(t, combined.hosts[0].engine.db), 2)
}

// A returned ID is externally usable even if the surrounding service turn aborts.
@(test)
test_durable_id_reservation_survives_aborted_turn :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1, true)
	defer durable_test_close(c)
	h := c.hosts[0]
	testing.expect(t, durable.turn_begin(h) == .None)
	_, err := durable.propose(h, transaction_test_request(t, 1, "SELECT 1"))
	testing.expect(t, err == .None)
	first, first_err := durable.next_id(h, 0)
	testing.expect(t, first_err == .None)
	// Closing without turn_commit abandons any open journal transaction.
	durable_test_reopen(t, c, 0, 1)
	next, next_err := durable.next_id(c.hosts[0], 0)
	testing.expect(t, next_err == .None && next > first)
}

// Model loss of an acknowledged NORMAL application suffix, retaining the FULL
// journal. Replaying must recover both data and deduplication, not just a watermark.
@(test)
test_durable_cache_replays_acknowledged_lost_suffix :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1, true)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE value(v); INSERT INTO value VALUES(0)")
	testing.expect(t, db.exec(h.engine.db, "PRAGMA wal_checkpoint(TRUNCATE)"))
	prefix, read_err := os.read_entire_file(c.paths[0], context.allocator)
	testing.expect(t, read_err == nil)
	defer delete(prefix)
	value := transaction_test_request(t, 1, "UPDATE value SET v=v+1")
	slot, err := durable.propose(h, value)
	testing.expect(t, err == .None && durable.acknowledged(h, slot, &value))
	durable.close(h)
	c.hosts[0] = nil
	testing.expect(t, os.write_entire_file(c.paths[0], prefix) == nil)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	testing.expect(t, durable.acknowledged(h, slot, &value))
	_, retry_err := durable.propose(h, value)
	testing.expect(t, retry_err == .None)
	result, query_err := sql.engine_query(&h.engine, "SELECT v FROM value")
	testing.expect(t, query_err == .None)
	defer sql.query_result_free(&result)
	testing.expect(t, len(result.rows) == 1 && result.rows[0][0].integer == 1)
}
