package tests

import "core:testing"
import sql "../src"

@(test)
test_replicated_fts_transaction_policy :: proc(t: ^testing.T) {
	e, err := sql.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_install_function_policy(&e) == .None)
	for text, i in ([?]string{
		"CREATE VIRTUAL TABLE docs USING fts5(title, body);",
		"INSERT INTO docs(rowid,title,body) VALUES(1,'Paxos','durable consensus');",
		"INSERT INTO docs(rowid,title,body) VALUES(2,'Vector','nearest neighbors');",
		"UPDATE docs SET body='safe durable consensus' WHERE rowid=1;",
	}) {
		m, made := sql.mutation_make_transaction(1, {{0 = 77}, u64(i + 1), 0}, text)
		testing.expect(t, made == .None)
		testing.expect(t, sql.engine_apply_outcome(&e, u64(i + 1), &m) == .None)
		out, complete, out_err := sql.engine_outcome(&e, u64(i + 1))
		testing.expect(t, out_err == .None && complete && out.kind == .Applied)
	}
	r, query_err := sql.engine_query(&e, "SELECT rowid FROM docs WHERE docs MATCH 'consensus';")
	testing.expect(t, query_err == .None)
	defer sql.query_result_free(&r)
	testing.expect_value(t, len(r.rows), 1)
}

@(test)
test_fts_shadow_writes_rejected :: proc(t: ^testing.T) {
	e, _ := sql.engine_open(":memory:", 1, memory = true)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_install_function_policy(&e) == .None)
	for text, i in ([?]string{
		"CREATE VIRTUAL TABLE docs USING fts5(body);",
		"INSERT INTO docs(rowid,body) VALUES(1,'original');",
		"DELETE FROM docs_data;",
		"UPDATE docs_content SET c0='tampered';",
		"INSERT INTO docs(rowid,body) VALUES(2,'still usable');",
	}) {
		m, _ := sql.mutation_make_transaction(1, {{0 = 78}, u64(i + 1), 0}, text)
		testing.expect(t, sql.engine_apply_outcome(&e, u64(i + 1), &m) == .None)
		out, complete, err := sql.engine_outcome(&e, u64(i + 1))
		testing.expect(t, err == .None && complete)
		testing.expect(t, (out.kind == .Applied) == (i < 2 || i == 4))
	}
	r, err := sql.engine_query(&e, "SELECT body FROM docs ORDER BY rowid;")
	testing.expect(t, err == .None && len(r.rows) == 2)
	defer sql.query_result_free(&r)
}

@(test)
test_fts_duplicate_is_durable_constraint :: proc(t: ^testing.T) {
	e, _ := sql.engine_open(":memory:", 1, memory = true)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_install_function_policy(&e) == .None)
	for text, i in ([?]string{
		"CREATE VIRTUAL TABLE docs USING fts5(body);",
		"INSERT INTO docs(rowid,body) VALUES(1,'original');",
		"INSERT INTO docs(rowid,body) VALUES(2,'rollback'); " +
		"INSERT INTO docs(rowid,body) VALUES(1,'duplicate');",
		"INSERT INTO docs(rowid,body) VALUES(3,'after rejection');",
	}) {
		m, _ := sql.mutation_make_transaction(1, {{0 = 79}, u64(i + 1), 0}, text)
		testing.expect(t, sql.engine_apply_outcome(&e, u64(i + 1), &m) == .None)
		out, complete, err := sql.engine_outcome(&e, u64(i + 1))
		testing.expect(t, err == .None && complete)
		testing.expect(t, (out.kind == .Constraint) == (i == 2))
	}
	r, err := sql.engine_query(&e, "SELECT body FROM docs ORDER BY rowid;")
	testing.expect(t, err == .None && len(r.rows) == 2)
	defer sql.query_result_free(&r)
}
