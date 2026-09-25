// Offline, bounded logical-state fingerprinting. Physical page layout is excluded;
// schema, typed row values, hidden rowids and extension shadow state are included.
package snapshot

import "core:c"
import "core:crypto/sha2"
import "core:fmt"
import "core:strings"
import "core:time"
import sql ".."
import db "../sqlite"

Logical_Limits :: struct {
	cancel: ^u32, // Optional worker-owned atomic flag; never part of image identity.
	image_bytes: u64,
	rows: u64,
	scratch_bytes: u64,
	instructions: u64,
	seconds: u32,
}
// The 100 GiB / 4 KiB-row capacity profile needs 26,214,400 rows before
// metadata. Sorting their 32-byte hashes uses bounded disk scratch, not RAM.
DEFAULT_LOGICAL_LIMITS :: Logical_Limits{
	image_bytes = 128*1024*1024*1024, rows = 32_000_000,
	scratch_bytes = 4*1024*1024*1024, instructions = 8_000_000_000, seconds = 3600,
}

// Caller owns an immutable application-only image directory. This is deliberately
// not an event-loop operation. The scratch database is disposable, never voter state.
logical_digest :: proc(
	path: string, prefix: sql.Slot, limits: Logical_Limits = DEFAULT_LOGICAL_LIMITS,
) -> (result: [32]u8, err: Image_Error) {
	if !candidate_path_valid(path) || prefix == 0 || limits.rows == 0 ||
	   limits.image_bytes < 4096 || limits.image_bytes > u64(max(i64)) ||
	   limits.scratch_bytes < 4096 || limits.scratch_bytes > u64(max(i64)) ||
	   limits.seconds == 0 || limits.seconds > 3600 || limits.instructions < 1000 { return {}, .Invalid }
	budget := Verify_Budget{started = time.tick_now(),
		deadline = time.Duration(limits.seconds)*time.Second,
		calls = limits.instructions/1000, cancel = limits.cancel}
	if !verify_budget_active(&budget) do return {}, budget.error
	job := Image_Copy{max_bytes = limits.image_bytes}
	defer image_release(&job)
	name := strings.clone_to_cstring(path)
	defer delete(name)
	if db.sqlite3_open_v2(name, &job.source, db.OPEN_READONLY | db.OPEN_NOFOLLOW, nil) != db.OK {
		return {}, .Storage
	}
	if !db.vec_register(job.source) do return {}, .Storage
	// Bound SQLite allocations before inspecting schema or materializing rows.
	// One extra result column carries the hidden row identity of ordinary tables.
	for limit in ([?][2]c.int{
		{0, sql.MAX_SQL_VALUE_BYTES}, {1, 16*1024}, {2, 129}, {7, 0}, {11, 0},
	}) {
		db.sqlite3_limit(job.source, limit[0], limit[1])
	}
	db.sqlite3_progress_handler(job.source, 1000, verify_progress, &budget)
	defer db.sqlite3_progress_handler(job.source, 0, nil, nil)
	if !db.exec(job.source, "PRAGMA cache_size=-8192; PRAGMA mmap_size=0; PRAGMA query_only=ON; BEGIN;") ||
	   !image_source(&job) || job.prefix != prefix {
		return {}, logical_error(&budget, .Invalid_Source)
	}
	scratch, opened := db.open("")
	if !opened do return {}, .Storage
	defer db.close(scratch)
	db.sqlite3_progress_handler(scratch, 1000, verify_progress, &budget)
	defer db.sqlite3_progress_handler(scratch, 0, nil, nil)
	settings := fmt.aprintf("PRAGMA page_size=4096; PRAGMA cache_size=-2048; " +
		"PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=FILE; " +
		"PRAGMA max_page_count=%d; CREATE TABLE hashes(value BLOB NOT NULL); " +
		"CREATE INDEX hashes_value ON hashes(value);", limits.scratch_bytes/4096)
	defer delete(settings)
	if !db.exec(scratch, settings) do return {}, logical_error(&budget, .Storage)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	logical_bytes(&ctx, "SQLodin/logical-image/v2")
	if !logical_schema(job.source, &ctx) do return {}, logical_error(&budget, .Invalid_Source)
	logical_bytes(&ctx, "tables")
	if !logical_tables(job.source, scratch, &ctx, limits.rows, &budget) {
		return {}, logical_error(&budget, .Invalid_Source)
	}
	if !verify_budget_active(&budget) do return {}, budget.error
	sha2.final(&ctx, result[:])
	return result, .None
}

@(private)
logical_error :: proc(budget: ^Verify_Budget, fallback: Image_Error) -> Image_Error {
	return budget.error if budget.error != .None else fallback
}

@(private)
logical_prepare :: proc(database: db.Sqlite3, text: string) -> (db.Sqlite3_Stmt, bool) {
	stmt: db.Sqlite3_Stmt
	if db.sqlite3_prepare_v2(database, cstring(raw_data(text)), c.int(len(text)), &stmt, nil) != db.OK {
		if stmt != nil do db.sqlite3_finalize(stmt)
		return nil, false
	}
	return stmt, stmt != nil
}

@(private)
logical_schema :: proc(database: db.Sqlite3, ctx: ^sha2.Context_256) -> bool {
	stmt, ok := logical_prepare(database,
		"SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type COLLATE BINARY,name COLLATE BINARY")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	for {
		rc := db.sqlite3_step(stmt)
		if rc == db.DONE do return true
		if rc != db.ROW do return false
		logical_word(ctx, 4)
		for column in 0..<4 do if !logical_value(ctx, stmt, c.int(column)) { return false }
	}
}
