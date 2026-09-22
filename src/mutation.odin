package sqlodin

import "core:mem"

MAX_TABLE_NAME_LEN :: 64
MAX_MUTATION_COLS  :: 16
MAX_SQL_LEN        :: 512
MAX_TEXT_LEN       :: 256
MAX_VEC_DIMS       :: 384

Mutation_Kind :: enum u8 {
	Skip    = 0,
	Insert  = 1,
	Delete  = 2,
	Update  = 3,
	Raw_SQL = 4,
}

Value_Kind :: enum u8 {
	Null    = 0,
	Integer = 1,
	Real    = 2,
	Text    = 3,
	Vector  = 4,
}

// Fixed-capacity column value to ensure zero-heap deterministic transitions.
Column_Value :: struct {
	kind:      Value_Kind,
	int_val:   i64,
	real_val:  f64,
	text_val:  [MAX_TEXT_LEN]u8,
	text_len:  u16,
	vec_val:   [MAX_VEC_DIMS]f32,
	vec_dim:   u16,
}

// Logical transaction mutation replicated through the consensus log.
Mutation :: struct {
	kind:         Mutation_Kind,
	origin_node:  Node_Id,
	timestamp_ms: u64,
	primary_key:  u64,

	table_name:   [MAX_TABLE_NAME_LEN]u8,
	table_len:    u8,

	col_count:    u8,
	col_names:    [MAX_MUTATION_COLS][MAX_TABLE_NAME_LEN]u8,
	col_name_lens:[MAX_MUTATION_COLS]u8,
	col_values:   [MAX_MUTATION_COLS]Column_Value,

	sql_bytes:    [MAX_SQL_LEN]u8,
	sql_len:      u16,
}

// Generates a cluster-unique 64-bit Snowflake ID.
// 42 bits timestamp_ms, 10 bits node_id (0..1023), 12 bits sequence (0..4095).
snowflake_generate :: proc(node_id: Node_Id, timestamp_ms: u64, seq: ^u16) -> u64 {
	seq^ = (seq^ + 1) & 0x0FFF
	time_part := timestamp_ms & 0x3FFFFFFFFFF
	node_part := u64(node_id & 0x03FF)
	seq_part  := u64(seq^)
	return (time_part << 22) | (node_part << 12) | seq_part
}

snowflake_node :: #force_inline proc(id: u64) -> Node_Id {
	return Node_Id((id >> 12) & 0x03FF)
}

snowflake_timestamp :: #force_inline proc(id: u64) -> u64 {
	return id >> 22
}

mutation_make_skip :: proc(origin: Node_Id, ts: u64) -> Mutation {
	m: Mutation
	m.kind = .Skip
	m.origin_node = origin
	m.timestamp_ms = ts
	return m
}

mutation_make_raw_sql :: proc(origin: Node_Id, ts: u64, sql: string) -> (Mutation, Error) {
	if len(sql) > MAX_SQL_LEN do return {}, .Payload_Too_Large
	m: Mutation
	m.kind = .Raw_SQL
	m.origin_node = origin
	m.timestamp_ms = ts
	m.sql_len = u16(len(sql))
	mem.copy(&m.sql_bytes[0], raw_data(sql), len(sql))
	return m, .None
}

mutation_make_insert :: proc(
	origin: Node_Id,
	ts: u64,
	pk: u64,
	table: string,
) -> (Mutation, Error) {
	if len(table) > MAX_TABLE_NAME_LEN do return {}, .Payload_Too_Large
	m: Mutation
	m.kind = .Insert
	m.origin_node = origin
	m.timestamp_ms = ts
	m.primary_key = pk
	m.table_len = u8(len(table))
	mem.copy(&m.table_name[0], raw_data(table), len(table))
	return m, .None
}

mutation_make_delete :: proc(
	origin: Node_Id,
	ts: u64,
	pk: u64,
	table: string,
) -> (Mutation, Error) {
	if len(table) > MAX_TABLE_NAME_LEN do return {}, .Payload_Too_Large
	m: Mutation
	m.kind = .Delete
	m.origin_node = origin
	m.timestamp_ms = ts
	m.primary_key = pk
	m.table_len = u8(len(table))
	mem.copy(&m.table_name[0], raw_data(table), len(table))
	return m, .None
}

mutation_add_int :: proc(m: ^Mutation, name: string, val: i64) -> Error {
	if int(m.col_count) >= MAX_MUTATION_COLS do return .Payload_Too_Large
	idx := int(m.col_count)
	m.col_name_lens[idx] = u8(len(name))
	mem.copy(&m.col_names[idx][0], raw_data(name), len(name))
	m.col_values[idx] = Column_Value{kind = .Integer, int_val = val}
	m.col_count += 1
	return .None
}

mutation_add_text :: proc(m: ^Mutation, name: string, val: string) -> Error {
	if int(m.col_count) >= MAX_MUTATION_COLS do return .Payload_Too_Large
	if len(val) > MAX_TEXT_LEN do return .Payload_Too_Large
	idx := int(m.col_count)
	m.col_name_lens[idx] = u8(len(name))
	mem.copy(&m.col_names[idx][0], raw_data(name), len(name))
	cv := Column_Value{kind = .Text, text_len = u16(len(val))}
	mem.copy(&cv.text_val[0], raw_data(val), len(val))
	m.col_values[idx] = cv
	m.col_count += 1
	return .None
}

mutation_add_vector :: proc(m: ^Mutation, name: string, vec: []f32) -> Error {
	if int(m.col_count) >= MAX_MUTATION_COLS do return .Payload_Too_Large
	if len(vec) > MAX_VEC_DIMS do return .Vector_Dimension_Mismatch
	idx := int(m.col_count)
	m.col_name_lens[idx] = u8(len(name))
	mem.copy(&m.col_names[idx][0], raw_data(name), len(name))
	cv := Column_Value{kind = .Vector, vec_dim = u16(len(vec))}
	for v, i in vec {
		cv.vec_val[i] = v
	}
	m.col_values[idx] = cv
	m.col_count += 1
	return .None
}

mutation_table_name :: proc(m: ^Mutation) -> string {
	return string(m.table_name[:m.table_len])
}

mutation_sql :: proc(m: ^Mutation) -> string {
	return string(m.sql_bytes[:m.sql_len])
}
