// Blocking verification for an offline/worker-owned immutable image, never the
// live service loop. This checks file/integrity metadata, not logical equivalence.
package snapshot

import "base:runtime"
import "core:c"
import "core:crypto/sha2"
import "core:strings"
import "core:time"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

@(private)
Verify_Budget :: struct {
	started: time.Tick, deadline: time.Duration,
	calls: u64, error: Image_Error,
	cancel: ^u32,
}

// The expected logical/configuration identity is supplied by the independent
// host verifier. Passing this function alone must never produce a voter receipt.
candidate_check_file :: proc(
	path: string, candidate: Candidate, expected: Key,
	max_bytes: u64, timeout_seconds: u32 = 60, instructions: u64 = 10_000_000, cancel: ^u32 = nil,
) -> Image_Error {
	if !candidate_path_valid(path) || candidate_validate(candidate, expected) != .None ||
	   timeout_seconds == 0 || timeout_seconds > 3600 || instructions < 1000 { return .Invalid }
	if candidate.bytes > max_bytes do return .Limit
	if expected.engine != sql.engine_build_fingerprint() do return .Invalid_Source
	budget := Verify_Budget{started = time.tick_now(),
		deadline = time.Duration(timeout_seconds)*time.Second, calls = instructions/1000, cancel = cancel}
	if !verify_budget_active(&budget) do return budget.error
	if err := verify_image_bytes(path, candidate, &budget); err != .None do return err
	name := strings.clone_to_cstring(path)
	defer delete(name)
	job := Image_Copy{max_bytes = max_bytes}
	defer image_release(&job)
	if db.sqlite3_open_v2(name, &job.source, db.OPEN_READONLY | db.OPEN_NOFOLLOW, nil) != db.OK {
		return .Storage
	}
	if !db.vec_register(job.source) do return .Storage
	db.sqlite3_progress_handler(job.source, 1000, verify_progress, &budget)
	defer db.sqlite3_progress_handler(job.source, 0, nil, nil)
	if !db.exec(job.source, "PRAGMA cache_size=-8192; PRAGMA query_only=ON; BEGIN;") ||
	   !image_source(&job) || job.prefix != expected.prefix {
		return budget.error if budget.error != .None else .Invalid_Source
	}
	if !verify_pragma(job.source, "PRAGMA integrity_check", true) ||
	   !verify_pragma(job.source, "PRAGMA foreign_key_check", false) {
		return budget.error if budget.error != .None else .Invalid_Source
	}
	if !verify_budget_active(&budget) do return budget.error
	return .None
}

@(private)
verify_progress :: proc "c" (user: rawptr) -> c.int {
	context = runtime.default_context()
	budget := cast(^Verify_Budget)user
	if !verify_budget_active(budget) do return 1
	if budget.calls <= 1 { budget.error = .Limit; return 1 }
	budget.calls -= 1
	return 0
}

@(private)
verify_pragma :: proc(database: db.Sqlite3, query: cstring, integrity: bool) -> bool {
	stmt: db.Sqlite3_Stmt
	if db.sqlite3_prepare_v2(database, query, -1, &stmt, nil) != db.OK do return false
	defer db.sqlite3_finalize(stmt)
	if integrity {
		if db.sqlite3_step(stmt) != db.ROW || string(db.sqlite3_column_text(stmt, 0)) != "ok" {
			return false
		}
	}
	return db.sqlite3_step(stmt) == db.DONE
}

@(private)
verify_image_bytes :: proc(path: string, candidate: Candidate, budget: ^Verify_Budget) -> Image_Error {
	// A candidate is a closed, single-file image. Never verify main-file bytes
	// while SQLite could read a different logical state from a sidecar journal.
	for suffix in ([2]string{"-wal", "-journal"}) {
		sidecar := strings.concatenate({path, suffix})
		defer delete(sidecar)
		name := strings.clone_to_cstring(sidecar)
		defer delete(name)
		stat: posix.stat_t
		if posix.lstat(name, &stat) == nil {
			// SQLite can leave an empty WAL after a read-only WAL-mode open.
			// Only an empty regular sidecar is harmless; never ignore any frames.
			if stat.st_size == 0 && posix.S_ISREG(stat.st_mode) do continue
			return .Invalid_Source
		}
		if posix.errno() != .ENOENT do return .Storage
	}
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.NOFOLLOW, .NONBLOCK})
	if file < 0 do return .Storage
	defer posix.close(file)
	stat: posix.stat_t
	if posix.fstat(file, &stat) != nil || !posix.S_ISREG(stat.st_mode) ||
	   stat.st_size < 0 || u64(stat.st_size) != candidate.bytes { return .Invalid_Source }
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	remaining := candidate.bytes
	buffer: [64*1024]u8
	for remaining > 0 {
		if !verify_budget_active(budget) do return budget.error
		count := posix.read(file, raw_data(buffer[:]), c.size_t(min(remaining, u64(len(buffer)))))
		if count < 0 do return .Storage
		if count == 0 do return .Invalid_Source
		sha2.update(&ctx, buffer[:int(count)])
		remaining -= u64(count)
	}
	hash: [32]u8
	sha2.final(&ctx, hash[:])
	if hash != candidate.image do return .Invalid_Source
	return .None
}
