// Cooperative, application-only image copying. Copied is not a verified receipt
// or a published generation. The owner must serialize calls and retain private paths.
package snapshot

import "core:c"
import "core:crypto/sha2"
import "core:strings"
import "core:path/filepath"
import "core:time"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

Image_Phase :: enum { Empty, Copying, Hashing, Copied, Failed, Cancelled }
Image_Error :: enum { None, Invalid, Invalid_Source, Storage, Limit, Timeout, Cancelled }
Image_Copy :: struct {
	phase: Image_Phase,
	cancel: ^u32,
	error: Image_Error,
	prefix: sql.Slot,
	bytes: u64,
	hash: [32]u8,
	source, destination: db.Sqlite3,
	backup: db.Sqlite3_Backup,
	file: posix.FD, file_open: bool,
	directory: posix.FD, directory_open: bool,
	started: time.Tick, deadline: time.Duration,
	pages_per_step: c.int,
	max_bytes, hashed: u64,
	hasher: sha2.Context_256,
}

// Opens a pinned read transaction before copying, so concurrent WAL writes cannot
// move the chosen image prefix. Destination is exclusive and is never overwritten.
// No node-local journal/ID tables may appear in an exportable application image.
image_begin :: proc(
	job: ^Image_Copy, source, destination: string, max_bytes: u64, timeout_seconds: u32 = 60,
) -> Image_Error {
	if job == nil || job.phase != .Empty || max_bytes < 4096 || max_bytes > u64(max(i64)) ||
	   timeout_seconds == 0 || timeout_seconds > 3600 { return .Invalid }
	for path in ([2]string{source, destination}) {
		if path == "" || path == ":memory:" || strings.has_prefix(path, "file:") ||
		   strings.contains(path, "\x00") { return .Invalid }
	}
	job.started, job.deadline = time.tick_now(), time.Duration(timeout_seconds)*time.Second
	job.max_bytes = max_bytes
	src := strings.clone_to_cstring(source)
	defer delete(src)
	flags := c.int(db.OPEN_READONLY | db.OPEN_PRIVATECACHE | db.OPEN_NOFOLLOW)
	if db.sqlite3_open_v2(src, &job.source, flags, nil) != db.OK {
		return image_fail(job, .Storage)
	}
	if !db.exec(job.source, "PRAGMA cache_size=-8192; PRAGMA query_only=ON; BEGIN;") ||
	   !image_source(job) { return image_fail(job, .Invalid_Source) }
	dst := strings.clone_to_cstring(destination)
	defer delete(dst)
	dir := strings.clone_to_cstring(filepath.dir(destination))
	defer delete(dir)
	job.directory = posix.open(dir, {.DIRECTORY, .NOFOLLOW})
	if job.directory < 0 do return image_fail(job, .Storage)
	job.directory_open = true
	job.file = posix.open(dst, {.RDWR, .CREAT, .EXCL, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if job.file < 0 do return image_fail(job, .Storage)
	job.file_open = true
	if db.sqlite3_open_v2(dst, &job.destination, db.OPEN_READWRITE | db.OPEN_NOFOLLOW, nil) != db.OK {
		return image_fail(job, .Storage)
	}
	if !db.exec(job.destination, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; " +
		"PRAGMA fullfsync=ON; PRAGMA cache_size=-8192;") { return image_fail(job, .Storage) }
	job.backup = db.sqlite3_backup_init(job.destination, "main", job.source, "main")
	if job.backup == nil do return image_fail(job, .Storage)
	job.phase = .Copying
	return .None
}

// At most 1 MiB of pages or hashing input per call. SQLite commits and filesystem
// calls can still block; this is a work bound, not a hard wall-clock latency bound.
image_step :: proc(job: ^Image_Copy) -> Image_Error {
	if job == nil do return .Invalid
	if job.phase == .Copied do return .None
	if job.phase == .Failed do return job.error
	if job.phase != .Copying && job.phase != .Hashing do return .Invalid
	if cancelled(job.cancel) do return image_fail(job, .Cancelled)
	if time.tick_since(job.started) >= job.deadline do return image_fail(job, .Timeout)
	if job.phase == .Hashing do return image_hash_step(job)
	rc := db.sqlite3_backup_step(job.backup, job.pages_per_step)
	if rc == db.BUSY || rc == db.LOCKED || rc == db.OK do return .None
	if rc != db.DONE do return image_fail(job, .Storage)
	if !image_finish_copy(job) do return image_fail(job, .Storage)
	return .None
}

// Release a pinned source promptly on cancellation/error. Partial files are left
// unadvertised for the owner to remove; no manifest or receipt is issued here.
image_cancel :: proc(job: ^Image_Copy) {
	if job == nil do return
	image_release(job)
	if job.phase != .Copied && job.phase != .Failed do job.phase = .Cancelled
}

@(private)
image_release :: proc(job: ^Image_Copy) {
	if job.backup != nil do db.sqlite3_backup_finish(job.backup)
	job.backup = nil
	if job.source != nil do db.close(job.source)
	if job.destination != nil do db.close(job.destination)
	job.source, job.destination = nil, nil
	if job.file_open do posix.close(job.file)
	job.file_open = false
	if job.directory_open do posix.close(job.directory)
	job.directory_open = false
}

@(private)
image_fail :: proc(job: ^Image_Copy, err: Image_Error) -> Image_Error {
	image_release(job)
	job.phase, job.error = .Failed, err
	return err
}
