package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

@(test)
test_read_barrier_is_fresh_and_single_use :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	forged := sql.mutation_make_skip(1, 0)
	forged.primary_key = 4096
	_, rejected := durable.propose(h, forged)
	testing.expect(t, rejected == .Invalid)
	transaction_test_schema(t, h, "CREATE TABLE t(v); INSERT INTO t VALUES(1);")
	ticket, err := durable.begin_read(h, 100)
	testing.expect(t, err == .None)
	_, err = durable.begin_read(h, 100)
	testing.expect(t, err == .Backpressure)
	result: durable.Read_Result
	result, err = durable.poll_read(h, ticket, "SELECT * FROM t WHERE v=1;")
	testing.expect(t, err == .None && result.status == .Ready && result.rows == 1)
	testing.expect(t, result.sql_error == .None)
	_, err = durable.poll_read(h, ticket, "SELECT * FROM t;")
	testing.expect(t, err == .Invalid)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	next: durable.Read_Ticket
	next, err = durable.begin_read(h, 99)
	testing.expect(t, err == .None && next.token != ticket.token && next.slot > ticket.slot)
	_, err = durable.poll_read(h, ticket, "SELECT * FROM t;")
	testing.expect(t, err == .Invalid)
	testing.expect(t, durable.cancel_read(h, next) == .None)
	_, err = durable.poll_read(h, next, "SELECT * FROM t;")
	testing.expect(t, err == .Invalid)
}

@(test)
test_read_barrier_waits_for_quorum_and_prior_writes :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	setup, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v); INSERT INTO t VALUES(42);")
	slot, err := durable.propose(c.hosts[0], setup)
	testing.expect(t, err == .None)
	durable_test_drain(t, c)
	testing.expect(t, durable.acknowledged(c.hosts[0], slot, &setup))
	ticket: durable.Read_Ticket
	ticket, err = durable.begin_read(c.hosts[1], 100)
	testing.expect(t, err == .None)
	result: durable.Read_Result
	result, err = durable.poll_read(c.hosts[1], ticket, "SELECT * FROM t;")
	testing.expect(t, err == .None && result.status == .Pending)
	// With no delivery a minority cannot turn its local snapshot into a fenced read.
	for _ in 0..<4 do testing.expect(t, durable.tick(c.hosts[1]) == .None)
	result, err = durable.poll_read(c.hosts[1], ticket, "SELECT * FROM t;")
	testing.expect(t, err == .None && result.status == .Pending)
	durable_test_drain(t, c)
	for _ in 0..<12 {
		for h in c.hosts do testing.expect(t, durable.tick(h) == .None)
		durable_test_drain(t, c)
	}
	result, err = durable.poll_read(c.hosts[1], ticket, "SELECT * FROM t WHERE v=42;")
	testing.expect(t, err == .None && result.status == .Ready && result.rows == 1)
	testing.expect(t, result.sql_error == .None)
}

@(test)
test_local_read_budget_does_not_poison_writer :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v); INSERT INTO t VALUES(1);")
	_, err := sql.engine_read_snapshot(&h.engine,
		"WITH RECURSIVE x(v) AS (VALUES(1) UNION ALL SELECT v+1 FROM x) SELECT count(*) FROM x;")
	testing.expect(t, err == .Query_Limit && !h.poisoned)
	expect_rows(t, &h.engine, "SELECT * FROM t; -- trailing comment", 1)
	_, err = sql.engine_read_snapshot(&h.engine, "SELECT * FROM t; DELETE FROM t;")
	testing.expect(t, err == .Invalid_Mutation)
	_, err = sql.engine_read_snapshot(&h.engine, "SELECT * FROM t; SELECT 1;")
	testing.expect(t, err == .Invalid_Mutation)
	m := transaction_test_request(t, 1, "INSERT INTO t VALUES(2);")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
	expect_rows(t, &h.engine, "SELECT * FROM t;", 2)
}
