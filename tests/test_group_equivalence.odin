package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

// Exercise identical histories through proposal groups and individual commits.
// Compare SQL state, every outcome, and retry fences after each group and reopen.
@(test)
test_application_group_matches_individual_history :: proc(t: ^testing.T) {
	for separated in ([2]bool{false, true}) {
		group_history_layout(t, separated)
	}
}

group_history_layout :: proc(t: ^testing.T, separated: bool) {
	a, b := durable_test_open(t, 1, separated), durable_test_open(t, 1, separated)
	defer durable_test_close(a)
	defer durable_test_close(b)
	schema := "CREATE TABLE p(id INTEGER PRIMARY KEY); INSERT INTO p VALUES(1); " +
		"CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,v INTEGER UNIQUE," +
		"pid REFERENCES p(id) DEFERRABLE INITIALLY DEFERRED); " +
		"CREATE TABLE audit(v INTEGER); CREATE TRIGGER log AFTER INSERT ON t " +
		"BEGIN INSERT INTO audit VALUES(new.v); END;"
	transaction_test_schema(t, a.hosts[0], schema)
	transaction_test_schema(t, b.hosts[0], schema)
	for round in 0..<12 {
		values: [16]sql.Mutation
		group_history_values(t, values[:], round)
		slots: [16]sql.Slot
		_, err := durable.propose_batch(a.hosts[0], values[:], slots[:])
		testing.expect(t, err == .None)
		for &value, i in values {
			want := transaction_test_submit(t, b.hosts[0], value)
			got, complete, read_err := durable.outcome(a.hosts[0], slots[i], &value)
			testing.expect(t, complete && read_err == .None)
			testing.expect_value(t, got, want)
		}
		group_history_compare(t, a.hosts[0], b.hosts[0])
		if round % 3 == 2 {
			durable_test_reopen(t, a, 0, 1)
			durable_test_reopen(t, b, 0, 1)
			group_history_compare(t, a.hosts[0], b.hosts[0])
		}
	}
}

group_history_values :: proc(t: ^testing.T, values: []sql.Mutation, round: int) {
	texts := [?]string{
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"INSERT INTO t(v,pid) VALUES(?1,999);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"UPDATE t SET v=v+100000 WHERE v=?1;",
		"INSERT INTO t(v,pid) VALUES(?1,1); SELECT abs(-9223372036854775808);",
		"INSERT INTO t(v,pid) VALUES(?1,1); SELECT random();",
		"INSERT INTO missing_table VALUES(?1);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"INSERT OR FAIL INTO t(v,pid) VALUES(?1+1,1),(?1,1);",
		"INSERT OR ROLLBACK INTO t(v,pid) VALUES(?1,1);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
		"INSERT INTO t(v,pid) VALUES(?1,1);",
	}
	for &value, i in values {
		id := sql.Request_Id{sequence = 1}
		id.session[0], id.session[1] = u8(round + 2), u8(i + 1)
		err: sql.Error
		value, err = sql.mutation_make_transaction(1, id, texts[i])
		testing.expect(t, err == .None)
		testing.expect(t, sql.transaction_add_int(&value, i64(round * 100 + i / 2)) == .None)
	}
	// Same-group retry, identity conflict, sequence gap and retired identity.
	values[11] = values[8]
	values[12].request = values[8].request
	values[13].request = values[8].request
	values[13].request.sequence = 3
	values[14] = values[8]
	values[15].request = values[8].request
	values[15].request.sequence = 4
	// Alternate groups that can commit together with whole-group rollback fallback.
	if round % 2 == 0 do values[10].col_values[0].int_val = values[8].col_values[0].int_val
}

group_history_compare :: proc(t: ^testing.T, a, b: ^durable.Host) {
	queries := [?]cstring{
		"SELECT printf('%d/%d/%d',id,v,pid) FROM t ORDER BY id",
		"SELECT printf('%d/%d',rowid,v) FROM audit ORDER BY rowid",
		"SELECT name||'/'||seq FROM sqlite_sequence ORDER BY name",
		"SELECT printf('%d/%d',version,epoch) FROM _sqlodin_tx_revision WHERE id=1",
		"SELECT printf('%d/%d/%d/%d/%d',slot,kind,code,changes,origin_slot) " +
			"FROM _sqlodin_outcomes ORDER BY slot",
		"SELECT hex(session)||'/'||hex(hash)||'/'||printf('%d/%d/%d/%d/%d'," +
			"seq,kind,code,changes,slot) FROM _sqlodin_sessions ORDER BY session",
	}
	for query in queries {
		left, right: db.Sqlite3_Stmt
		testing.expect(t, db.sqlite3_prepare_v2(a.engine.db, query, -1, &left, nil) == db.OK)
		testing.expect(t, db.sqlite3_prepare_v2(b.engine.db, query, -1, &right, nil) == db.OK)
		for {
			x, y := db.sqlite3_step(left), db.sqlite3_step(right)
			testing.expect_value(t, x, y)
			if x != db.ROW || y != db.ROW { testing.expect(t, x == db.DONE && y == db.DONE); break }
			testing.expect_value(t, string(db.sqlite3_column_text(left, 0)),
				string(db.sqlite3_column_text(right, 0)))
		}
		db.sqlite3_finalize(left)
		db.sqlite3_finalize(right)
	}
}
