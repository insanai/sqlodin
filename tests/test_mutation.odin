package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_snowflake_generation :: proc(t: ^testing.T) {
	seq1, seq2: u16
	ts: u64 = 1726000000000

	id_node1 := sqlodin.snowflake_generate(1, ts, &seq1)
	id_node2 := sqlodin.snowflake_generate(2, ts, &seq2)

	// Unique IDs even at the same millisecond timestamp
	testing.expect(t, id_node1 != id_node2)
	testing.expect_value(t, sqlodin.snowflake_node(id_node1), sqlodin.Node_Id(1))
	testing.expect_value(t, sqlodin.snowflake_node(id_node2), sqlodin.Node_Id(2))
	testing.expect_value(t, sqlodin.snowflake_timestamp(id_node1), ts)

	// Monotonic on same node
	id_node1_next := sqlodin.snowflake_generate(1, ts, &seq1)
	testing.expect(t, id_node1_next > id_node1)
}

@(test)
test_mutation_builders :: proc(t: ^testing.T) {
	pk: u64 = 123456789
	m, err := sqlodin.mutation_make_insert(1, 1000, pk, "users")
	testing.expect(t, err == .None)
	testing.expect_value(t, sqlodin.mutation_table_name(&m), "users")

	sqlodin.mutation_add_int(&m, "age", 30)
	sqlodin.mutation_add_text(&m, "name", "Alice")

	vec := [?][3]f32{0.1, 0.2, 0.3}
	sqlodin.mutation_add_vector(&m, "embedding", vec[0][:])

	testing.expect_value(t, m.col_count, 3)
	testing.expect(t, m.col_values[0].kind == .Integer)
	testing.expect_value(t, m.col_values[0].int_val, 30)
	testing.expect(t, m.col_values[1].kind == .Text)
	testing.expect(t, m.col_values[2].kind == .Vector)
	testing.expect_value(t, m.col_values[2].vec_dim, 3)

	del, del_err := sqlodin.mutation_make_delete(1, 1001, pk, "users")
	testing.expect(t, del_err == .None)
	testing.expect(t, del.kind == .Delete)
	testing.expect_value(t, del.primary_key, pk)
}
