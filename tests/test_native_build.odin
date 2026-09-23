package tests

import "core:testing"
import sql "../src"

@(test)
test_pinned_sqlite_fts_and_vector_build :: proc(t: ^testing.T) {
	e, err := sql.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	rows, read_err := sql.engine_read_snapshot(&e,
		"SELECT 1 WHERE sqlite_version()='3.51.3' AND vec_version()='v0.1.9' " +
		"AND sqlite_compileoption_used('ENABLE_FTS5') " +
		"AND sqlite_compileoption_used('OMIT_LOAD_EXTENSION');")
	testing.expect(t, read_err == .None && rows == 1)
}
