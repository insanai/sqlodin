package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

transaction_test_request :: proc(t: ^testing.T, seq: u64, text: string) -> sql.Mutation {
	id := sql.Request_Id{sequence = seq}
	id.session[0] = 1
	m, err := sql.mutation_make_transaction(1, id, text)
	testing.expect(t, err == .None)
	return m
}

transaction_test_submit :: proc(t: ^testing.T, h: ^durable.Host, m: sql.Mutation) -> sql.Outcome {
	slot, err := durable.propose(h, m)
	testing.expect(t, err == .None && !h.poisoned)
	out, found, read_err := sql.engine_outcome(&h.engine, slot)
	testing.expect(t, found && read_err == .None)
	return out
}

transaction_test_schema :: proc(t: ^testing.T, h: ^durable.Host, text: string) {
	m, err := sql.mutation_make_raw_sql(1, 0, text)
	testing.expect(t, err == .None)
	out := transaction_test_submit(t, h, m)
	testing.expect(t, out.kind == .Applied)
}

@(test)
test_transaction_constraint_outcome_and_restart :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT UNIQUE);")
	m := transaction_test_request(t, 1,
		"INSERT INTO t VALUES(1,'same'); INSERT INTO t VALUES(2,'same');")
	out := transaction_test_submit(t, h, m)
	testing.expect(t, out.kind == .Constraint && out.changes == 0)
	testing.expect(t, !durable.acknowledged(h, out.slot, &m))
	expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	old := transaction_test_submit(t, h, m)
	testing.expect_value(t, old, out)
	m = transaction_test_request(t, 2, "INSERT INTO t VALUES(?1,?2);")
	testing.expect(t, sql.transaction_add_int(&m, 7) == .None)
	testing.expect(t, sql.transaction_add_text(&m, "durable") == .None)
	good := transaction_test_submit(t, h, m)
	testing.expect(t, good.kind == .Applied && good.changes == 1)
	durable_test_reopen(t, c, 0, 1)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t WHERE id=7 AND v='durable';", 1)
}

@(test)
test_transaction_rollback_conflict_isolated :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(id PRIMARY KEY,v UNIQUE);")
	good := transaction_test_request(t, 1, "INSERT INTO t VALUES(1,1);")
	testing.expect(t, transaction_test_submit(t, h, good).kind == .Applied)
	bad := transaction_test_request(t, 2,
		"INSERT INTO t VALUES(2,2); INSERT OR ROLLBACK INTO t VALUES(3,1);")
	testing.expect(t, transaction_test_submit(t, h, bad).kind == .Constraint)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE id=1;", 1)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE id=2;", 0)
	good = transaction_test_request(t, 3, "INSERT INTO t VALUES(4,4);")
	testing.expect(t, transaction_test_submit(t, h, good).kind == .Applied)
	durable_test_reopen(t, c, 0, 1)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t;", 2)
}

@(test)
test_transaction_deferred_foreign_key_outcome :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	testing.expect(t, sql.engine_exec(&h.engine, "PRAGMA foreign_keys=ON") == .None)
	transaction_test_schema(t, h,
		"CREATE TABLE p(id PRIMARY KEY); CREATE TABLE c(id PRIMARY KEY,pid REFERENCES p(id) " +
		"DEFERRABLE INITIALLY DEFERRED);")
	bad := transaction_test_request(t, 1, "INSERT INTO c VALUES(1,99);")
	testing.expect(t, transaction_test_submit(t, h, bad).kind == .Constraint)
	expect_rows(t, &h.engine, "SELECT * FROM c;", 0)
	good := transaction_test_request(t, 2,
		"INSERT INTO c VALUES(2,99); INSERT INTO p VALUES(99);")
	testing.expect(t, transaction_test_submit(t, h, good).kind == .Applied)
	durable_test_reopen(t, c, 0, 1)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM c WHERE id=2;", 1)
}

@(test)
test_transaction_retry_identity_and_expiry :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v); INSERT INTO t VALUES(0);")
	m := transaction_test_request(t, 1, "UPDATE t SET v=v+1;")
	first := transaction_test_submit(t, h, m)
	m.origin_node = 2
	testing.expect_value(t, transaction_test_submit(t, h, m), first)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	testing.expect_value(t, transaction_test_submit(t, h, m), first)
	conflict := transaction_test_request(t, 1, "UPDATE t SET v=v+100;")
	testing.expect(t, transaction_test_submit(t, h, conflict).kind == .Identity_Conflict)
	m.request.sequence = 2
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
	m.request.sequence = 1
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Expired)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE v=2;", 1)
}

@(test)
test_transaction_sequence_gap_burns_identity :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v);")
	m := transaction_test_request(t, 3, "INSERT INTO t VALUES(1);")
	gap := transaction_test_submit(t, h, m)
	testing.expect(t, gap.kind == .Sequence_Gap)
	m.request.sequence = 2
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Expired)
	m.request.sequence = 3
	testing.expect_value(t, transaction_test_submit(t, h, m), gap)
	m.request.sequence = 4
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
	expect_rows(t, &h.engine, "SELECT * FROM t;", 1)
}

@(test)
test_transaction_function_policy_rejects_local_state :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v);")
	for text, i in ([?]string{
		"INSERT INTO t VALUES(random());",
		"INSERT INTO t VALUES(CURRENT_TIMESTAMP);",
		"INSERT INTO t VALUES(datetime('now'));",
		"INSERT INTO t VALUES(last_insert_rowid());",
		"INSERT INTO t VALUES(sqlite_version());",
		"INSERT INTO t VALUES(1); COMMIT;",
		"DELETE FROM _sqlodin_sessions;",
		"CREATE TEMP TABLE ephemeral(v);",
		"PRAGMA user_version=5;",
		"SELECT * FROM pragma_compile_options;",
		"SELECT sql FROM sqlite_schema;",
	}) {
		m := transaction_test_request(t, u64(i + 1), text)
		testing.expect(t, transaction_test_submit(t, h, m).kind == .Policy, text)
	}
	expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
	m := transaction_test_request(t, 12, "INSERT INTO t VALUES('random()');")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
}

@(test)
test_transaction_invalid_sql_is_durable_rejection :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v);")
	for text, i in ([?]string{
		"INSERT INTO t VALUES(1); this is not SQL;",
		"INSERT INTO absent VALUES(1);",
		"INSERT INTO t(missing) VALUES(1);",
	}) {
		m := transaction_test_request(t, u64(i + 1), text)
		out := transaction_test_submit(t, h, m)
		testing.expect(t, out.kind == .Invalid_SQL && out.changes == 0)
		durable_test_reopen(t, c, 0, 1)
		h = c.hosts[0]
		testing.expect_value(t, transaction_test_submit(t, h, m), out)
	}
	expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
	m := transaction_test_request(t, 4, "INSERT INTO t VALUES(2);")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
}

@(test)
test_transaction_missing_outcome_prevents_reopen :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v);")
	testing.expect(t, sql.engine_exec(&h.engine, "DELETE FROM _sqlodin_outcomes;") == .None)
	durable.close(h)
	c.hosts[0] = nil
	ids := [1]sql.Node_Id{1}
	reopened, err := durable.open(c.paths[0], "test", 1, ids[:])
	defer durable.close(reopened)
	testing.expect(t, err == .Storage && reopened == nil)
}

@(test)
test_transaction_prevents_random_rowid_fallback :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(id INTEGER PRIMARY KEY,v);")
	for text, i in ([?]string{
		"INSERT INTO t VALUES(9223372036854775807,1); INSERT INTO t(v) VALUES(2);",
		"INSERT INTO t VALUES(1,1); UPDATE t SET id=9223372036854775807;",
	}) {
		m := transaction_test_request(t, u64(i + 1), text)
		testing.expect(t, transaction_test_submit(t, h, m).kind == .Policy)
		expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
	}
	durable_test_reopen(t, c, 0, 1)
	m := transaction_test_request(t, 3, "INSERT INTO t(v) VALUES(7);")
	testing.expect(t, transaction_test_submit(t, c.hosts[0], m).kind == .Applied)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t WHERE id=1 AND v=7;", 1)
}

@(test)
test_transaction_raw_sql_cannot_bind_inactive_fields :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	m, err := sql.mutation_make_raw_sql(1, 0, "SELECT ?17;")
	testing.expect(t, err == .None)
	// Legacy raw SQL does not validate its inactive column metadata. It must
	// never index those fields while preparing a SQL body with parameters.
	m.col_count = 255
	out := transaction_test_submit(t, c.hosts[0], m)
	testing.expect(t, out.kind == .Policy)
}

@(test)
test_transaction_local_aggregates_use_readonly_connection :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h,
		"CREATE TABLE t(v); INSERT INTO t VALUES(1),(2),(3); CREATE INDEX ix ON t(v);")
	expect_rows(t, &h.engine, "SELECT * FROM t INDEXED BY ix WHERE v=2;", 1)
	expect_rows(t, &h.engine, "SELECT sum(v) FROM t HAVING sum(v)=6;", 1)
	expect_rows(t, &h.engine, "SELECT row_number() OVER (ORDER BY v) FROM t;", 3)
	m := transaction_test_request(t, 1, "INSERT INTO t SELECT sum(v) FROM t;")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Policy)
	_, err := sql.engine_read_snapshot(&h.engine, "DELETE FROM t;")
	testing.expect(t, err != .None)
	_, err = sql.engine_read_snapshot(&h.engine, "SELECT * FROM _sqlodin_sessions;")
	testing.expect(t, err != .None)
	durable_test_reopen(t, c, 0, 1)
	expect_rows(t, &c.hosts[0].engine, "SELECT sum(v) FROM t HAVING sum(v)=6;", 1)
}

@(test)
test_transaction_default_and_trigger_policy :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	// Privileged setup deliberately introduces unsafe schemas to exercise the
	// application-time check, not just request-text function scanning.
	testing.expect(t, sql.engine_exec(&h.engine,
		"CREATE TABLE t(id,v DEFAULT CURRENT_TIMESTAMP); CREATE TABLE audit(v); " +
		"CREATE TRIGGER bad AFTER INSERT ON audit BEGIN " +
		"INSERT INTO t VALUES(new.v,random()); END;") == .None)
	for text, i in ([?]string{"INSERT INTO t(id) VALUES(1);", "INSERT INTO audit VALUES(1);"}) {
		m := transaction_test_request(t, u64(i + 1), text)
		testing.expect(t, transaction_test_submit(t, h, m).kind == .Policy, text)
	}
	expect_rows(t, &h.engine, "SELECT * FROM audit;", 0)
	expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
}

@(test)
test_transaction_crash_after_choice_replays_once :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v); INSERT INTO t VALUES(0);")
	m := transaction_test_request(t, 1, "UPDATE t SET v=v+1;")
	h.fault = .After_Journal_Commit
	_, err := durable.propose(h, m)
	testing.expect(t, err == .Storage && h.poisoned)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE v=1;", 1)
}

@(test)
test_transaction_multimaster_duplicate_and_distinct_requests :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	setup, _ := sql.mutation_make_raw_sql(1, 0,
		"CREATE TABLE t(v); INSERT INTO t VALUES(0);")
	_, err := durable.propose(c.hosts[0], setup)
	testing.expect(t, err == .None)
	for _ in 0..<10 {
		for h in c.hosts do testing.expect(t, durable.tick(h) == .None)
		durable_test_drain(t, c)
	}
	slots: [3]sql.Slot
	for h, i in c.hosts {
		m := transaction_test_request(t, 1, "UPDATE t SET v=v+1;")
		m.origin_node = sql.Node_Id(i + 1)
		if i == 2 do m.request.session[0] = 2
		slot, propose_err := durable.propose(h, m)
		testing.expect(t, propose_err == .None)
		slots[i] = slot
	}
	durable_test_drain(t, c)
	for h in c.hosts {
		expect_rows(t, &h.engine, "SELECT * FROM t WHERE v=2;", 1)
		for slot in slots {
			out, found, read_err := sql.engine_outcome(&h.engine, slot)
			testing.expect(t, found && read_err == .None && out.kind == .Applied)
		}
	}
	for i in 0..<3 {
		durable_test_reopen(t, c, i, 3)
		expect_rows(t, &c.hosts[i].engine, "SELECT * FROM t WHERE v=2;", 1)
	}
}

@(test)
test_transaction_trigger_rollback_preserves_prior_request :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(id PRIMARY KEY); " +
		"CREATE TRIGGER reject BEFORE INSERT ON t WHEN new.id=9 " +
		"BEGIN SELECT RAISE(ROLLBACK,'rejected'); END;")
	m := transaction_test_request(t, 1, "INSERT INTO t VALUES(1);")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
	m = transaction_test_request(t, 2, "INSERT INTO t VALUES(2); INSERT INTO t VALUES(9);")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Constraint)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE id=1;", 1)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE id=2;", 0)
	durable_test_reopen(t, c, 0, 1)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t;", 1)
}
