package durable

import "core:strings"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

// The original application is the predecessor of the first published generation.
// Only a later publication makes it disposable. A durable completion marker
// prevents subsequent runs from deleting an unrelated file created at that path.
retire_root_application :: proc(h: ^Host, cluster: string,
	checkpoint: proc(Generation_Phase) = nil) -> (bool, Error) {
	if h == nil || h.poisoned || !h.store_guard_owned do return false, .Invalid
	if h.compaction != nil || h.snapshot_busy do return false, .Backpressure
	if h.store_current == "" || h.generation_previous == "" do return false, .None
	catalog, opened := open_catalog(h.store_root, verify = false)
	if !opened do return false, .Storage
	defer db.close(catalog)
	current, valid := read_generation(catalog, cluster, h.node.id, sql.membership_slice(&h.node.membership))
	defer delete(current)
	if !valid || current != h.store_current do return false, .Storage
	// Reuse the checked predecessor descriptor before deleting the original base.
	previous_image, previous_ok := predecessor_image(h)
	defer delete(previous_image)
	if !previous_ok do return false, .Storage
	if !db.exec(catalog, "CREATE TABLE IF NOT EXISTS _sqlodin_root_retired(" +
		"id INTEGER PRIMARY KEY CHECK(id=1),done INTEGER NOT NULL CHECK(done=1))") {
		return false, .Storage
	}
	count, ok := migration_integer(catalog,
		"SELECT count(*) FROM _sqlodin_root_retired WHERE id=1 AND done=1")
	if !ok do return false, .Storage
	if count == 1 do return false, .None
	if err := delete_root_application(h.store_root, checkpoint); err != .None do return false, err
	if !db.begin_tx(catalog) do return false, .Storage
	defer db.rollback_tx(catalog)
	if !db.exec(catalog, "INSERT INTO _sqlodin_root_retired VALUES(1,1)") do return false, .Storage
	if checkpoint != nil do checkpoint(.Before_Root_Retirement_Commit)
	if !db.commit_tx(catalog) do return false, .Storage
	return true, .None
}

@(private)
delete_root_application :: proc(path: string, checkpoint: proc(Generation_Phase)) -> Error {
	name := strings.clone_to_cstring(path)
	defer delete(name)
	root := posix.open(name, {.DIRECTORY, .NOFOLLOW})
	if root < 0 do return .Storage
	defer posix.close(root)
	lock := posix.openat(root, "node.db.lock", {.RDWR, .NOFOLLOW})
	if lock < 0 {
		if posix.errno() != .ENOENT do return .Storage
	} else {
		defer posix.close(lock)
		if lock_file(lock, 2 | 4) != 0 do return .Backpressure
		return unlink_root_application(root, checkpoint)
	}
	return unlink_root_application(root, checkpoint)
}

@(private)
unlink_root_application :: proc(root: posix.FD, checkpoint: proc(Generation_Phase)) -> Error {
	for file in ([5]cstring{"node.db", "node.db-wal", "node.db-shm", "node.db-journal", "node.db.lock"}) {
		if posix.unlinkat(root, file, {}) != nil && posix.errno() != .ENOENT do return .Storage
	}
	if checkpoint != nil do checkpoint(.After_Root_Retirement_Files)
	if posix.fsync(root) != nil do return .Storage
	if checkpoint != nil do checkpoint(.After_Root_Retirement_Sync)
	return .None
}
