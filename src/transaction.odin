package sqlodin

import "core:mem"

// A session has one outstanding transaction. Advancing its sequence retires the
// previous result, but never permits an older transaction to execute again.
Request_Id :: struct { session: [16]u8, sequence: u64 }
Transaction_Outcome :: enum u8 {
	Applied,
	Constraint,
	Policy,
	Sequence_Gap,
	Expired,
	Identity_Conflict,
	Session_Limit,
	Invalid_SQL,
	Conflict,
}
Outcome :: struct {
	kind: Transaction_Outcome,
	sqlite_code: i32,
	changes: i64,
	slot: Slot,
}
MAX_REQUEST_SESSIONS :: 65536

// SQL is a complete transaction body, without BEGIN/COMMIT. Bound parameters use
// ?1..?16 and the same parameter tuple in each statement. Explicit values, never
// connection-local random/time/last_insert_rowid(), belong in this request.
mutation_make_transaction :: proc(
	origin: Node_Id, request: Request_Id, sql: string,
) -> (Mutation, Error) {
	if request.session == ([16]u8{}) || request.sequence == 0 ||
	   request.sequence > u64(max(i64)) {
		return {}, .Invalid_Mutation
	}
	if len(sql) == 0 || len(sql) > MAX_SQL_LEN do return {}, .Payload_Too_Large
	m := Mutation{kind = .Transaction, origin_node = origin, request = request,
		sql_len = u16(len(sql))}
	mem.copy(&m.sql_bytes[0], raw_data(sql), len(sql))
	return m, mutation_validate(&m)
}

// Parameter names are not SQL fragments. The existing bounded column storage is
// reused as a typed parameter tuple; no additional maximum-sized values are copied.
transaction_add_int :: proc(m: ^Mutation, value: i64) -> Error {
	if m.kind != .Transaction do return .Invalid_Mutation
	return mutation_add_int(m, "p", value)
}

transaction_add_text :: proc(m: ^Mutation, value: string) -> Error {
	if m.kind != .Transaction do return .Invalid_Mutation
	return mutation_add_text(m, "p", value)
}
