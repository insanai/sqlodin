package tests

import "core:testing"
import "core:fmt"
import "core:c"
import "base:runtime"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

@(test)
test_expression_rejections_rollback_retry_and_restart :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	transaction_test_schema(t, c.hosts[0], "CREATE TABLE t(v);")
	for text, i in ([?]string{
		"INSERT INTO t VALUES(1); SELECT abs(-9223372036854775808);",
		"INSERT INTO t VALUES(1); SELECT json('broken');",
		"INSERT INTO t VALUES(1); SELECT json_extract('{}','broken');",
		"INSERT INTO t VALUES(1); SELECT json_array(x'ff');",
		"INSERT INTO t VALUES(1); SELECT json_object(1,2);",
		"INSERT INTO t VALUES(1); SELECT 'a' LIKE 'a' ESCAPE 'ab';",
		"INSERT INTO t VALUES(1); SELECT zeroblob(1048577);",
		"INSERT INTO t(rowid,v) VALUES('bad',1);",
	}) {
		m := transaction_test_request(t, u64(i + 1), text)
		h := c.hosts[0]
		out := transaction_test_submit(t, h, m)
		testing.expect(t, out.kind == .Invalid_SQL && out.changes == 0, fmt.tprintf("%s: %v", text, out))
		expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
		testing.expect_value(t, transaction_test_submit(t, h, m), out)
		durable_test_reopen(t, c, 0, 1)
		testing.expect_value(t, transaction_test_submit(t, c.hosts[0], m), out)
	}
	m := transaction_test_request(t, 9, "INSERT INTO t VALUES(42);")
	testing.expect(t, transaction_test_submit(t, c.hosts[0], m).kind == .Applied)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t WHERE v=42;", 1)
}

@(test)
test_expression_rejections_all_replicas :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	setup, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v);")
	_, err := durable.propose(c.hosts[0], setup)
	testing.expect(t, err == .None)
	durable_test_drain(t, c)
	for node in 0..<3 {
		m := transaction_test_request(t, u64(node + 1),
			"INSERT INTO t VALUES(1); SELECT json('broken');")
		slot, propose_err := durable.propose(c.hosts[node], m)
		testing.expect(t, propose_err == .None)
		for _ in 0..<12 {
			for h in c.hosts do testing.expect(t, durable.tick(h) == .None)
			durable_test_drain(t, c)
		}
		for h in c.hosts {
			out, found, read_err := durable.outcome(h, slot, &m)
			testing.expect(t, read_err == .None && found && out.kind == .Invalid_SQL)
			expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
		}
	}
	for node in 0..<3 {
		durable_test_reopen(t, c, node, 3)
		expect_rows(t, &c.hosts[node].engine, "SELECT * FROM t;", 0)
	}
}

@(test)
test_durable_rejects_changed_engine_identity :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	testing.expect(t, sql.engine_exec(&c.hosts[0].engine,
		"UPDATE _sqlodin_journal_meta SET identity=identity||'different-engine';") == .None)
	durable.close(c.hosts[0])
	c.hosts[0] = nil
	h, err := durable.open(c.paths[0], "test", 1, []sql.Node_Id{1})
	testing.expect(t, h == nil && err != .None)
	if h != nil do durable.close(h)
}

injected_sqlite_failure :: proc "c" (
	ctx: db.Sqlite3_Context, argc: c.int, argv: ^db.Sqlite3_Value,
) {
	context = runtime.default_context()
	code := cast(^c.int)db.sqlite3_user_data(ctx)
	message: cstring = "malformed JSON"
	if code^ == db.ERROR do message = "unclassified execution error"
	db.sqlite3_result_error(ctx, message, -1)
	db.sqlite3_result_error_code(ctx, code^)
}

@(test)
test_expression_classifier_never_masks_storage_or_unknown_errors :: proc(t: ^testing.T) {
	for failure in ([?]c.int{db.NOMEM, db.IOERR, db.FULL, db.CORRUPT, db.READONLY,
		db.INTERRUPT, db.ERROR, db.ERROR | (1 << 8)}) {
		c := durable_test_open(t, 1)
		h := c.hosts[0]
		transaction_test_schema(t, h, "CREATE TABLE t(v);")
		code := failure
		// Test-only injection: use a permitted function's callback to deliver a
		// precise SQLite failure after a preceding statement has changed rows.
		testing.expect(t, db.sqlite3_create_function_v2(h.engine.db, "abs", 1, 1, &code,
			injected_sqlite_failure, nil, nil, nil) == db.OK)
		m := transaction_test_request(t, 1, "INSERT INTO t VALUES(1); SELECT abs(1);")
		slot, err := durable.propose(h, m)
		testing.expect(t, err == .Storage && h.poisoned, fmt.tprintf("error %d", code))
		testing.expect(t, !durable.acknowledged(h, slot, &m))
		expect_rows(t, &h.engine, "SELECT * FROM t;", 0)
		durable_test_close(c)
	}
}

@(test)
test_recursive_sql_rejects_without_poisoning :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	m := transaction_test_request(t, 1,
		"WITH RECURSIVE x(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM x) SELECT * FROM x;")
	testing.expect(t, transaction_test_submit(t, c.hosts[0], m).kind == .Policy)
	durable_test_reopen(t, c, 0, 1)
	testing.expect(t, transaction_test_submit(t, c.hosts[0], m).kind == .Policy)
}

@(test)
test_sqlite_sequence_is_not_client_writable :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h,
		"CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,v); INSERT INTO t(v) VALUES(1);")
	m := transaction_test_request(t, 1, "UPDATE sqlite_sequence SET seq=9223372036854775807;")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Policy)
	m = transaction_test_request(t, 2, "INSERT INTO t(v) VALUES(2);")
	testing.expect(t, transaction_test_submit(t, h, m).kind == .Applied)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE id=2 AND v=2;", 1)
}
