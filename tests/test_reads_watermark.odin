package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_reads_watermark :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)

	sqlodin.engine_exec(&e, "CREATE TABLE logs (msg TEXT);")
	sqlodin.engine_exec(&e, "INSERT INTO logs VALUES ('hello');")

	// Read with watermark 0 (local snapshot) succeeds immediately
	rows, err := sqlodin.engine_read_snapshot(&e, "SELECT * FROM logs;", min_watermark = 0)
	testing.expect(t, err == .None)
	testing.expect_value(t, rows, 1)

	// Read with future watermark 5 fails with Stale_Watermark
	_, err_stale := sqlodin.engine_read_snapshot(&e, "SELECT * FROM logs;", min_watermark = 5)
	testing.expect(t, err_stale == .Stale_Watermark)

	// Advance applied through by applying slots 1 through 5
	for s in 1..=5 {
		noop := sqlodin.mutation_make_skip(1, 0)
		sqlodin.engine_apply_slot(&e, sqlodin.Slot(s), &noop)
	}
	testing.expect_value(t, sqlodin.engine_applied_through(&e), sqlodin.Slot(5))

	// Now watermark 5 succeeds!
	rows_caught_up, err_caught_up := sqlodin.engine_read_snapshot(
		&e, "SELECT * FROM logs;", min_watermark = 5,
	)
	testing.expect(t, err_caught_up == .None)
	testing.expect_value(t, rows_caught_up, 1)
}
