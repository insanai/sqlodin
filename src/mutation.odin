package sqlodin

import "core:mem"
import "core:math"
import "core:strings"

MAX_TABLE_NAME_LEN :: 64
MAX_MUTATION_COLS  :: 16
MAX_SQL_LEN        :: 4096
MAX_TEXT_LEN       :: 256
MAX_VEC_DIMS       :: 384
MAX_MUTATION_VEC_VALUES :: #config(SQLODIN_MAX_MUTATION_VEC_VALUES, MAX_VEC_DIMS)
#assert(MAX_MUTATION_VEC_VALUES >= MAX_VEC_DIMS && MAX_MUTATION_VEC_VALUES <= 65535)

Mutation_Kind :: enum u8 {
	Skip    = 0,
	Insert  = 1,
	Delete  = 2,
	Update  = 3,
	Raw_SQL = 4,
	Transaction = 5,
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
	vec_offset: u16,
	vec_dim:   u16,
}

// Logical transaction mutation replicated through the consensus log.
Mutation :: struct {
	kind:         Mutation_Kind,
	request:      Request_Id,
	// Zero is unconditional; otherwise the required application revision plus one.
	read_version: u64,
	origin_node:  Node_Id,
	timestamp_ms: u64,
	primary_key:  u64,

	table_name:   [MAX_TABLE_NAME_LEN]u8,
	table_len:    u8,

	col_count:    u8,
	col_names:    [MAX_MUTATION_COLS][MAX_TABLE_NAME_LEN]u8,
	col_name_lens:[MAX_MUTATION_COLS]u8,
	col_values:   [MAX_MUTATION_COLS]Column_Value,

	// Vector storage is shared by the columns; integer/text columns reserve no vectors.
	vec_values:   [MAX_MUTATION_VEC_VALUES]f32,
	vec_count:    u16,

	sql_bytes:    [MAX_SQL_LEN]u8,
	sql_len:      u16,
}

// Low-level bit packer. Caller must prevent timestamp/sequence reuse and node aliasing.
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
	if !mutation_identifier_valid(table) do return {}, .Invalid_Mutation
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
	if !mutation_identifier_valid(table) do return {}, .Invalid_Mutation
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
	if len(name) > MAX_TABLE_NAME_LEN do return .Payload_Too_Large
	if !mutation_identifier_valid(name) do return .Invalid_Mutation
	idx := int(m.col_count)
	m.col_name_lens[idx] = u8(len(name))
	mem.copy(&m.col_names[idx][0], raw_data(name), len(name))
	m.col_values[idx] = Column_Value{kind = .Integer, int_val = val}
	m.col_count += 1
	return .None
}

mutation_add_text :: proc(m: ^Mutation, name: string, val: string) -> Error {
	if int(m.col_count) >= MAX_MUTATION_COLS do return .Payload_Too_Large
	if len(name) > MAX_TABLE_NAME_LEN do return .Payload_Too_Large
	if !mutation_identifier_valid(name) do return .Invalid_Mutation
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
	if len(name) > MAX_TABLE_NAME_LEN do return .Payload_Too_Large
	if !mutation_identifier_valid(name) do return .Invalid_Mutation
	if len(vec) == 0 || len(vec) > MAX_VEC_DIMS do return .Vector_Dimension_Mismatch
	if int(m.vec_count) + len(vec) > MAX_MUTATION_VEC_VALUES do return .Payload_Too_Large
	for v in vec {
		if math.is_nan(v) || math.is_inf(v) do return .Vector_Invalid_Format
	}
	idx := int(m.col_count)
	m.col_name_lens[idx] = u8(len(name))
	mem.copy(&m.col_names[idx][0], raw_data(name), len(name))
	cv := Column_Value{kind = .Vector, vec_offset = m.vec_count, vec_dim = u16(len(vec))}
	copy(m.vec_values[int(m.vec_count):], vec)
	m.vec_count += u16(len(vec))
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

// Identifiers are restricted, then quoted by the SQL builder. No SQL fragments.
mutation_identifier_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_TABLE_NAME_LEN do return false
	for ch, i in name {
		alpha := ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch == '_'
		if !alpha && !(i > 0 && ch >= '0' && ch <= '9') do return false
	}
	return true
}

mutation_make_update :: proc(
	origin: Node_Id, ts: u64, pk: u64, table: string,
) -> (result: Mutation, err: Error) {
	m := mutation_make_insert(origin, ts, pk, table) or_return
	m.kind = .Update
	return m, .None
}

// Validate fixed-array lengths before taking slices, including host-decoded values.
mutation_validate :: proc(m: ^Mutation) -> Error {
	if m == nil do return .Invalid_Mutation
	// Even inactive floating fields participate in upstream whole-value equality.
	for v in m.col_values {
		if math.is_nan(v.real_val) do return .Invalid_Mutation
	}
	for v in m.vec_values {
		if math.is_nan(v) do return .Invalid_Mutation
	}
	switch m.kind {
	case .Skip:
		return .None
	case .Raw_SQL, .Transaction:
		if m.kind == .Transaction && (m.request.session == ([16]u8{}) ||
		   m.request.sequence == 0 || m.request.sequence > u64(max(i64)) ||
		   m.read_version > u64(max(i64))) {
			return .Invalid_Mutation
		}
		if m.sql_len == 0 || int(m.sql_len) > MAX_SQL_LEN do return .Invalid_Mutation
		for ch in m.sql_bytes[:m.sql_len] {
			if ch == 0 do return .Invalid_Mutation
		}
		if m.kind == .Raw_SQL do return .None
	case .Insert, .Delete, .Update:
		if int(m.table_len) > MAX_TABLE_NAME_LEN do return .Invalid_Mutation
		if !mutation_identifier_valid(mutation_table_name(m)) do return .Invalid_Mutation
		if mutation_reserved_name(mutation_table_name(m)) do return .Invalid_Mutation
	case:
		return .Invalid_Mutation
	}
	if int(m.col_count) > MAX_MUTATION_COLS do return .Invalid_Mutation
	if int(m.vec_count) > MAX_MUTATION_VEC_VALUES do return .Invalid_Mutation
	if m.kind == .Update && m.col_count == 0 do return .Invalid_Mutation
	for i in 0..<int(m.col_count) {
		if int(m.col_name_lens[i]) > MAX_TABLE_NAME_LEN do return .Invalid_Mutation
		if !mutation_identifier_valid(string(m.col_names[i][:m.col_name_lens[i]])) {
			return .Invalid_Mutation
		}
		v := &m.col_values[i]
		switch v.kind {
		case .Null, .Integer:
		case .Real:
			if math.is_nan(v.real_val) || math.is_inf(v.real_val) do return .Invalid_Mutation
		case .Text:
			if int(v.text_len) > MAX_TEXT_LEN do return .Invalid_Mutation
		case .Vector:
			if v.vec_dim == 0 || int(v.vec_dim) > MAX_VEC_DIMS do return .Vector_Dimension_Mismatch
			end := int(v.vec_offset) + int(v.vec_dim)
			if end > int(m.vec_count) do return .Invalid_Mutation
			for x in m.vec_values[int(v.vec_offset):end] {
				if math.is_nan(x) || math.is_inf(x) do return .Vector_Invalid_Format
			}
		case:
			return .Invalid_Mutation
		}
	}
	return .None
}

// The durable host reserves its entire metadata namespace.
mutation_reserved_name :: proc(name: string) -> bool {
	prefix :: "_sqlodin_"
	return len(name) >= len(prefix) && strings.equal_fold(name[:len(prefix)], prefix)
}
