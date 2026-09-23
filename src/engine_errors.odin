package sqlodin

import "core:strings"
import "sqlite"

// Capture before reset/finalize can replace the connection's error. Only audited
// built-in expression diagnostics are SQL-level failures; generic SQLITE_ERROR
// is not sufficient evidence to turn an unknown failure into a committed result.
@(private)
engine_capture_error :: proc(e: ^Engine) {
	e.last_sqlite_code = sqlite.sqlite3_extended_errcode(e.db)
	e.last_expression_error = false
	if e.last_sqlite_code != sqlite.ERROR do return
	message := sqlite.last_error(e.db)
	for expected in ([?]string{
		"integer overflow", "malformed JSON", "JSON cannot hold BLOB values",
		"json_object() labels must be TEXT",
		"json_object() requires an even number of arguments",
		"ESCAPE expression must be a single character", "LIKE or GLOB pattern too complex",
		"too many levels of trigger recursion",
	}) {
		if message == expected { e.last_expression_error = true; return }
	}
	// SQLite 3.51 uses the first diagnostic; the platform test library may use
	// the second. Only the user-supplied path suffix is variable.
	e.last_expression_error = strings.has_prefix(message, "bad JSON path: '") ||
		strings.has_prefix(message, "JSON path error near '")
}
