package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

group_commit_count: int
count_group_commits :: proc() { group_commit_count += 1 }

@(test)
test_application_group_one_commit_independent_outcomes :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v UNIQUE);")
	values := [3]sql.Mutation{
		transaction_test_request(t, 1, "INSERT INTO t VALUES(1);"),
		transaction_test_request(t, 2, "INSERT INTO t VALUES(1);"),
		transaction_test_request(t, 3, "INSERT INTO t VALUES(2);"),
	}
	slots: [3]sql.Slot
	group_commit_count = 0
	h.engine.application_before_commit = count_group_commits
	_, err := durable.propose_batch(h, values[:], slots[:])
	testing.expect(t, err == .None)
	want := 1 if sql.APPLICATION_GROUP_COMMIT else 3
	testing.expect_value(t, group_commit_count, want)
	durable_test_reopen(t, c, 0, 1)
	for slot, i in slots {
		out, complete, read_err := durable.outcome(c.hosts[0], slot, &values[i])
		kind: sql.Transaction_Outcome = .Constraint if i == 1 else .Applied
		testing.expect(t, read_err == .None && complete && out.kind == kind)
	}
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t;", 2)
	testing.expect(t, transaction_test_submit(t, c.hosts[0], values[2]).kind == .Applied)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t;", 2)
}

@(test)
test_application_group_deferred_fk_boundary :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h,
		"CREATE TABLE p(id PRIMARY KEY); CREATE TABLE c(id PRIMARY KEY,pid REFERENCES p(id) " +
		"DEFERRABLE INITIALLY DEFERRED);")
	values := [3]sql.Mutation{
		transaction_test_request(t, 1, "INSERT INTO c VALUES(1,1);"),
		transaction_test_request(t, 2, "INSERT INTO p VALUES(1);"),
		transaction_test_request(t, 3, "INSERT INTO c VALUES(2,1);"),
	}
	slots: [3]sql.Slot
	_, err := durable.propose_batch(h, values[:], slots[:])
	testing.expect(t, err == .None)
	durable_test_reopen(t, c, 0, 1)
	for slot, i in slots {
		out, complete, read_err := durable.outcome(c.hosts[0], slot, &values[i])
		kind: sql.Transaction_Outcome = .Constraint if i == 0 else .Applied
		testing.expect(t, read_err == .None && complete && out.kind == kind)
	}
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM c WHERE id=1;", 0)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM c WHERE id=2;", 1)
}

@(test)
test_application_group_rollback_replays_without_duplicate_effects :: proc(t: ^testing.T) {
	for failing_sql in ([?]string{
		"INSERT OR ROLLBACK INTO t VALUES(1);",
		"INSERT INTO trigger_rollback VALUES(1);",
	}) {
		c := durable_test_open(t, 1)
		h := c.hosts[0]
		transaction_test_schema(t, h,
			"CREATE TABLE t(v UNIQUE); CREATE TABLE trigger_rollback(v); " +
			"CREATE TRIGGER stop BEFORE INSERT ON trigger_rollback " +
			"BEGIN SELECT raise(ROLLBACK,'stop'); END;")
		values := [3]sql.Mutation{
			transaction_test_request(t, 1, "INSERT INTO t VALUES(1);"),
			transaction_test_request(t, 2, failing_sql),
			transaction_test_request(t, 3, "INSERT INTO t VALUES(2);"),
		}
		slots: [3]sql.Slot
		_, err := durable.propose_batch(h, values[:], slots[:])
		testing.expect(t, err == .None)
		durable_test_reopen(t, c, 0, 1)
		for slot, i in slots {
			out, complete, read_err := durable.outcome(c.hosts[0], slot, &values[i])
			kind: sql.Transaction_Outcome = .Constraint if i == 1 else .Applied
			testing.expect(t, read_err == .None && complete && out.kind == kind)
			testing.expect_value(t, out.changes, i64(0) if i == 1 else i64(1))
		}
		expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t;", 2)
		durable_test_close(c)
	}
}
