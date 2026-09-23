package sqlodin

import "core:c"
import "core:crypto/sha2"
import "sqlite"

// Policy 4 bounds individual SQLite values/rows and parser constructs. These
// are not aggregate memory or execution-time quotas. Limits apply to the writer,
// including replay, and must be identical across every replica in a cluster.
MAX_SQL_VALUE_BYTES :: 1024 * 1024

engine_install_limits :: proc(e: ^Engine) -> Error {
	for limit in ([?][2]c.int{
		{0, MAX_SQL_VALUE_BYTES}, // LENGTH: values and encoded rows
		{1, MAX_SQL_LEN},         // SQL_LENGTH
		{2, 128},                 // COLUMN
		{3, 64},                  // EXPR_DEPTH
		{4, 16},                  // COMPOUND_SELECT
		{6, 64},                  // FUNCTION_ARG
		{7, 0},                   // ATTACHED
		{8, 4096},                // LIKE_PATTERN_LENGTH
		{9, 32},                  // VARIABLE_NUMBER (structured DML also binds a key)
		{10, 16},                 // TRIGGER_DEPTH
		{11, 0},                  // WORKER_THREADS
	}) {
		sqlite.sqlite3_limit(e.db, limit[0], limit[1])
		if sqlite.sqlite3_limit(e.db, limit[0], -1) != limit[1] do return .Sqlite_Open_Failed
	}
	return .None
}

// Prevent recovery under a silently changed engine/configuration. This local
// fingerprint is not a replacement for a future transport compatibility handshake.
engine_build_fingerprint :: proc() -> (hash: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	source := string(sqlite.sqlite3_sourceid())
	sha2.update(&ctx, transmute([]u8)source)
	separator := [1]u8{0}
	for i: c.int = 0; ; i += 1 {
		option := sqlite.sqlite3_compileoption_get(i)
		if option == nil do break
		sha2.update(&ctx, separator[:])
		sha2.update(&ctx, transmute([]u8)string(option))
	}
	sha2.final(&ctx, hash[:])
	return
}
