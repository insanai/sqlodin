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

@(test)
test_mutation_bounds_and_shared_vector_payload :: proc(t: ^testing.T) {
	m, _ := sqlodin.mutation_make_insert(1, 0, 1, "items")
	long_name: [sqlodin.MAX_TABLE_NAME_LEN + 1]u8
	for &ch in long_name do ch = 'a'
	testing.expect(t, sqlodin.mutation_add_int(&m, string(long_name[:]), 1) == .Payload_Too_Large)
	testing.expect(t, sqlodin.mutation_add_text(&m, "x); DROP TABLE items;--", "x") == .Invalid_Mutation)
	testing.expect_value(t, m.col_count, u8(0))
	v: [sqlodin.MAX_VEC_DIMS]f32
	testing.expect(t, sqlodin.mutation_add_vector(&m, "emb", v[:]) == .None)
	testing.expect(t, sqlodin.mutation_add_vector(&m, "second", v[:]) == .Payload_Too_Large)
	testing.expect(t, sqlodin.mutation_validate(&m) == .None)
	m.col_values[0].vec_offset = 1
	testing.expect(t, sqlodin.mutation_validate(&m) == .Invalid_Mutation)
	m.col_count = 255
	testing.expect(t, sqlodin.mutation_validate(&m) == .Invalid_Mutation)
}

@(test)
test_snowflake_rollover_and_clock_rollback :: proc(t: ^testing.T) {
	e: sqlodin.Engine
	e.node_id = 1
	last: u64
	for _ in 0..<5000 {
		id, err := sqlodin.engine_next_id_checked(&e, 1000)
		testing.expect(t, err == .None && id > last)
		last = id
	}
	id, err := sqlodin.engine_next_id_checked(&e, 999)
	testing.expect(t, err == .None && id > last)
	_, err = sqlodin.engine_next_id_checked(&e, u64(1) << 42)
	testing.expect(t, err == .Snowflake_Exhausted)
	e.node_id = 1025
	_, err = sqlodin.engine_next_id_checked(&e, 1001)
	testing.expect(t, err == .Invalid_Node_Id)
}

@(test)
test_inactive_nan_cannot_break_consensus_value_equality :: proc(t: ^testing.T) {
	m := sqlodin.mutation_make_skip(1, 0)
	bits: u64 = 0x7ff8000000000001
	m.col_values[15].real_val = transmute(f64)bits
	testing.expect(t, sqlodin.mutation_validate(&m) == .Invalid_Mutation)
	m = sqlodin.mutation_make_skip(1, 0)
	vector_bits: u32 = 0x7fc00001
	m.vec_values[sqlodin.MAX_MUTATION_VEC_VALUES - 1] = transmute(f32)vector_bits
	testing.expect(t, sqlodin.mutation_validate(&m) == .Invalid_Mutation)
}
