package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

@(test)
test_session_retirement_fences_reclaimed_requests_across_restart :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE epoch_items(v INTEGER)")
	value := transaction_test_request(t, 1, "INSERT INTO epoch_items VALUES(7)")
	out := transaction_test_submit(t, h, value)
	testing.expect(t, out.kind == .Applied)
	retire, err := sql.mutation_make_session_retirement(1, 0)
	testing.expect(t, err == .None)
	testing.expect(t, transaction_test_submit(t, h, retire).kind == .Applied)
	testing.expect(t, transaction_test_submit(t, h, value).kind == .Expired)
	value.request.epoch = 1
	testing.expect(t, transaction_test_submit(t, h, value).kind == .Applied)
	// A delayed duplicate retirement cannot erase the current epoch's result.
	testing.expect(t, transaction_test_submit(t, h, retire).kind == .Applied)
	duplicate := transaction_test_submit(t, h, value)
	testing.expect(t, duplicate.kind == .Applied)
	durable_test_reopen(t, c, 0, 1)
	h = c.hosts[0]
	testing.expect_value(t, transaction_test_submit(t, h, value), duplicate)
	value.request.epoch = 0
	testing.expect(t, transaction_test_submit(t, h, value).kind == .Expired)
	expect_rows(t, &h.engine, "SELECT * FROM epoch_items", 2)
	expect_session_count(t, &h.engine, 1)
	epoch, epoch_err := sql.engine_session_epoch(&h.engine)
	testing.expect(t, epoch_err == .None && epoch == 1)
	_, overflow := sql.mutation_make_session_retirement(1, u64(max(i64)))
	testing.expect(t, overflow == .Invalid_Mutation)
}

@(test)
test_session_epoch_retirement_at_full_capacity :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE epoch_items(v INTEGER)")
	// Seed the complete fixed-capacity boundary directly; subsequent admissions,
	// retries and retirement all go through the durable application path.
	testing.expect(t, sql.engine_exec(&h.engine,
		"WITH RECURSIVE n(v) AS (VALUES(1) UNION ALL SELECT v+1 FROM n WHERE v<65535) " +
		"INSERT INTO _sqlodin_sessions SELECT CAST(printf('%016x',v) AS BLOB)," +
		"1,zeroblob(32),0,0,0,1 FROM n") == .None)
	value := transaction_test_request(t, 1, "INSERT INTO epoch_items VALUES(7)")
	first := transaction_test_submit(t, h, value)
	testing.expect(t, first.kind == .Applied)
	testing.expect_value(t, transaction_test_submit(t, h, value), first)
	other := value
	other.request.session[0] = 2
	testing.expect(t, transaction_test_submit(t, h, other).kind == .Session_Limit)
	retire, _ := sql.mutation_make_session_retirement(1, 0)
	testing.expect(t, transaction_test_submit(t, h, retire).kind == .Applied)
	testing.expect(t, transaction_test_submit(t, h, value).kind == .Expired)
	other.request.epoch = 1
	testing.expect(t, transaction_test_submit(t, h, other).kind == .Applied)
	durable_test_reopen(t, c, 0, 1)
	testing.expect(t, transaction_test_submit(t, c.hosts[0], value).kind == .Expired)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM epoch_items", 2)
	expect_session_count(t, &c.hosts[0].engine, 1)
}

@(test)
test_session_epoch_grouped_and_reference_orderings_match :: proc(t: ^testing.T) {
	a, b := durable_test_open(t, 1), durable_test_open(t, 1)
	defer durable_test_close(a); defer durable_test_close(b)
	for h in ([2]^durable.Host{a.hosts[0], b.hosts[0]}) {
		transaction_test_schema(t, h, "CREATE TABLE epoch_items(v INTEGER)")
	}
	value := transaction_test_request(t, 1, "INSERT INTO epoch_items VALUES(7)")
	first, _ := sql.mutation_make_session_retirement(1, 0)
	second, _ := sql.mutation_make_session_retirement(1, 1)
	current := value
	current.request.epoch = 1
	values := [9]sql.Mutation{value, first, current, value, first, current, second, current, first}
	slots: [9]sql.Slot
	_, err := durable.propose_batch(a.hosts[0], values[:], slots[:])
	testing.expect(t, err == .None)
	for &m, i in values {
		want := transaction_test_submit(t, b.hosts[0], m)
		got, found, read_err := durable.outcome(a.hosts[0], slots[i], &m)
		testing.expect(t, found && read_err == .None)
		testing.expect_value(t, got, want)
	}
	for c in ([2]type_of(a){a, b}) {
		durable_test_reopen(t, c, 0, 1)
		epoch, read_err := sql.engine_session_epoch(&c.hosts[0].engine)
		testing.expect(t, read_err == .None && epoch == 2)
		expect_rows(t, &c.hosts[0].engine, "SELECT * FROM epoch_items", 2)
		expect_session_count(t, &c.hosts[0].engine, 0)
	}
}

expect_session_count :: proc(t: ^testing.T, e: ^sql.Engine, count: i64) {
	s, err := sql.engine_prepare(e, "SELECT count(*) FROM _sqlodin_sessions")
	testing.expect(t, err == .None)
	defer db.sqlite3_finalize(s)
	testing.expect(t, db.sqlite3_step(s) == db.ROW)
	testing.expect_value(t, db.sqlite3_column_int64(s, 0), count)
}

@(test)
test_legacy_session_epoch_upgrade_preserves_canonical_metadata_schema :: proc(t: ^testing.T) {
	a, _ := sql.engine_open(":memory:", 1)
	b, _ := sql.engine_open(":memory:", 1)
	defer sql.engine_close(&a); defer sql.engine_close(&b)
	testing.expect(t, sql.engine_initialize_outcomes(&a))
	testing.expect(t, sql.engine_exec(&b,
		"CREATE TABLE _sqlodin_tx_revision(id INTEGER PRIMARY KEY CHECK(id=1)," +
		"version INTEGER NOT NULL);" +
		"INSERT INTO _sqlodin_tx_revision VALUES(1,19); BEGIN;") == .None)
	testing.expect(t, sql.engine_upgrade_session_epoch(&b) == .None)
	testing.expect(t, db.commit_tx(b.db))
	left, _ := sql.engine_prepare(&a, "SELECT sql FROM sqlite_schema WHERE name='_sqlodin_tx_revision'")
	right, _ := sql.engine_prepare(&b, "SELECT sql FROM sqlite_schema WHERE name='_sqlodin_tx_revision'")
	defer db.sqlite3_finalize(left); defer db.sqlite3_finalize(right)
	testing.expect(t, db.sqlite3_step(left) == db.ROW && db.sqlite3_step(right) == db.ROW)
	testing.expect_value(t, string(db.sqlite3_column_text(left, 0)),
		string(db.sqlite3_column_text(right, 0)))
	epoch, epoch_err := sql.engine_session_epoch(&b)
	version, version_err := sql.engine_read_version(&b)
	testing.expect(t, epoch_err == .None && epoch == 0 && version_err == .None && version == 19)
}
