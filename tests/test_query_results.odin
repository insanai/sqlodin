package tests

import "core:testing"
import sql "../src"

@(test)
test_query_owned_values_and_bindings :: proc(t: ^testing.T) {
	e, err := sql.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	m, _ := sql.mutation_make_transaction(1, {{0 = 1}, 1}, "SELECT ?1 AS name, ?2 AS number;")
	_ = sql.transaction_add_text(&m, "a\x00b")
	_ = sql.transaction_add_int(&m, 9223372036854775807)
	r, error := sql.engine_query(&e, sql.mutation_sql(&m), &m)
	testing.expect(t, error == .None)
	defer sql.query_result_free(&r)
	testing.expect_value(t, len(r.rows), 1)
	if len(r.rows) != 1 do return
	testing.expect_value(t, r.columns[0], "name")
	testing.expect_value(t, r.rows[0][0].text, "a\x00b")
	testing.expect_value(t, r.rows[0][1].integer, i64(9223372036854775807))
	v, v_err := sql.engine_query(&e, "SELECT NULL, 1.5, X'00FF', ''; ")
	testing.expect(t, v_err == .None)
	defer sql.query_result_free(&v)
	if len(v.rows) != 1 do return
	testing.expect(t, v.rows[0][0].kind == .Null)
	testing.expect_value(t, v.rows[0][1].real, f64(1.5))
	testing.expect(t, v.rows[0][2].kind == .Blob)
	testing.expect_value(t, v.rows[0][2].text, "AP8=")
	testing.expect(t, v.rows[0][3].kind == .Text)
}

@(test)
test_query_limits_return_no_partial_result :: proc(t: ^testing.T) {
	e, _ := sql.engine_open(":memory:", 1, memory = true)
	defer sql.engine_close(&e)
	for text in ([?]string{
		"SELECT 1; SELECT 2;", "CREATE TABLE denied(id);", "SELECT ?1;",
		"WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<5000) SELECT n FROM x;",
	}) {
		r, err := sql.engine_query(&e, text)
		testing.expect(t, err != .None)
		testing.expect_value(t, len(r.rows), 0)
		testing.expect_value(t, len(r.columns), 0)
	}
}
