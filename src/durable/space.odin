package durable

import "core:strings"
import db "../sqlite"
import "core:sys/posix"

MINIMUM_FREE_RESERVE :: 256*1024*1024

// Admission uses space available to this unprivileged service account. This is
// a reserve check, not a claim that another process cannot consume space later;
// every write and durability barrier must still handle errors independently.
space_available :: proc(directory: string, required: u64) -> bool {
	name := strings.clone_to_cstring(directory)
	defer delete(name)
	info: posix.statvfs_t
	if posix.statvfs(name, &info) != nil || info.f_frsize == 0 do return false
	blocks, size := u64(info.f_bavail), u64(info.f_frsize)
	if blocks > max(u64)/size do return true
	return blocks*size >= required
}

// Receiving/staging an image needs room for the immutable copy, replacement
// application, and retained local journal. The active generation remains intact.
generation_space_available :: proc(h: ^Host, image_bytes: u64, receiving: bool = false) -> bool {
	if h == nil || h.consensus == nil || h.store_root == "" do return false
	journal_bytes, journal_ok := database_size(h.consensus)
	application_bytes, application_ok := database_size(h.engine.db)
	if !journal_ok || !application_ok do return false
	history, history_ok := history_usage(h)
	if !history_ok || history > HISTORY_LIMIT-HISTORY_TRANSITION_RESERVE ||
		journal_bytes > (HISTORY_LIMIT-HISTORY_TRANSITION_RESERVE-history)/2 { return false }
	application_bytes = max(application_bytes, image_bytes)
	required := u64(MINIMUM_FREE_RESERVE)
	for addition in ([3]u64{application_bytes, journal_bytes, image_bytes if receiving else 0}) {
		if addition > max(u64)-required do return false
		required += addition
	}
	return space_available(h.store_root, required)
}

@(private)
database_size :: proc(database: db.Sqlite3) -> (u64, bool) {
	page_size, size_ok := migration_integer(database, "PRAGMA page_size")
	pages, pages_ok := migration_integer(database, "PRAGMA page_count")
	if !size_ok || !pages_ok || page_size <= 0 || pages < 0 ||
		u64(pages) > max(u64)/u64(page_size) { return 0, false }
	return u64(pages)*u64(page_size), true
}

// SQLite page accounting is independent of its current WAL checkpoint position.
consensus_bytes :: proc(h: ^Host) -> (u64, bool) {
	return database_size(journal_db(h))
}

// Capture can target a different filesystem from the live application. Check
// that destination before proposing a barrier and again at the chosen prefix.
snapshot_space_available :: proc(h: ^Host) -> bool {
	if h.snapshot == nil do return false
	bytes, valid := database_size(h.engine.db)
	return valid && bytes <= max(u64)-MINIMUM_FREE_RESERVE &&
		space_available(h.snapshot.directory, bytes+MINIMUM_FREE_RESERVE)
}
