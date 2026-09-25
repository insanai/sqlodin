package snapshot

import "core:c"
import "core:crypto/sha2"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

@(private)
image_integer :: proc(database: db.Sqlite3, query: cstring) -> (i64, bool) {
	stmt: db.Sqlite3_Stmt
	if db.sqlite3_prepare_v2(database, query, -1, &stmt, nil) != db.OK do return 0, false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_step(stmt) != db.ROW || db.sqlite3_column_type(stmt, 0) != db.INTEGER_TYPE {
		return 0, false
	}
	value := db.sqlite3_column_int64(stmt, 0)
	return value, db.sqlite3_step(stmt) == db.DONE
}

@(private)
image_source :: proc(job: ^Image_Copy) -> bool {
	// This SELECT establishes the source transaction's immutable WAL snapshot.
	prefix, ok := image_integer(job.source, "SELECT applied FROM _sqlodin_state WHERE id=1")
	if !ok || prefix < 1 do return false
	job.prefix = sql.Slot(prefix)
	local_tables, valid := image_integer(job.source,
		"SELECT count(*) FROM sqlite_schema WHERE type='table' AND name GLOB '_sqlodin_*' " +
		"AND name NOT IN ('_sqlodin_state','_sqlodin_outcomes','_sqlodin_sessions','_sqlodin_tx_revision')")
	if !valid || local_tables != 0 do return false
	count, found := image_integer(job.source,
		"SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN " +
		"('_sqlodin_state','_sqlodin_outcomes','_sqlodin_sessions','_sqlodin_tx_revision')")
	if !found || count != 4 do return false
	page_size, size_ok := image_integer(job.source, "PRAGMA page_size")
	pages, pages_ok := image_integer(job.source, "PRAGMA page_count")
	if !size_ok || !pages_ok || page_size < 512 || page_size > 65536 ||
	   page_size & (page_size-1) != 0 || pages < 1 ||
	   u64(pages) > job.max_bytes/u64(page_size) { return false }
	job.pages_per_step = c.int(1024*1024/page_size)
	return true
}

@(private)
image_finish_copy :: proc(job: ^Image_Copy) -> bool {
	rc := db.sqlite3_backup_finish(job.backup)
	job.backup = nil
	if rc != db.OK do return false
	prefix, valid := image_integer(job.destination, "SELECT applied FROM _sqlodin_state WHERE id=1")
	if !valid || prefix < 0 || sql.Slot(prefix) != job.prefix do return false
	if !db.close(job.destination) do return false
	job.destination = nil
	if !db.close(job.source) do return false
	job.source = nil
	stat: posix.stat_t
	if posix.fstat(job.file, &stat) != nil || stat.st_size <= 0 ||
	   u64(stat.st_size) > job.max_bytes { return false }
	job.bytes = u64(stat.st_size)
	// SQLite's FULL commit above syncs database contents (fullfsync on macOS).
	// The retained name is synced too. A certificate/generation manifest still
	// requires its own verified publication protocol before issuing any receipt.
	if posix.fsync(job.file) != nil || posix.fsync(job.directory) != nil do return false
	sha2.init_256(&job.hasher)
	job.phase = .Hashing
	return true
}

@(private)
image_hash_step :: proc(job: ^Image_Copy) -> Image_Error {
	buffer: [64*1024]u8
	for _ in 0..<16 {
		if job.hashed == job.bytes {
			sha2.final(&job.hasher, job.hash[:])
			image_release(job)
			job.phase = .Copied
			return .None
		}
		want := min(u64(len(buffer)), job.bytes-job.hashed)
		count := posix.pread(job.file, raw_data(buffer[:]), c.size_t(want), posix.off_t(job.hashed))
		if count <= 0 do return image_fail(job, .Storage)
		sha2.update(&job.hasher, buffer[:int(count)])
		job.hashed += u64(count)
	}
	return .None
}
