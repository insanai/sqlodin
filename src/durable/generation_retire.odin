package durable

import "core:c"
import "core:strings"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

// Retire at most one inventoried directory. The active catalog and the exact
// predecessor in its checked descriptor are protected independently of sorting.
// No path discovered merely by listing the filesystem is eligible for deletion.
retire_generation :: proc(h: ^Host, cluster: string,
	checkpoint: proc(Generation_Phase) = nil) -> (bool, Error) {
	if h == nil || h.poisoned || !h.store_guard_owned do return false, .Invalid
	if h.compaction != nil || h.snapshot_busy do return false, .Backpressure
	catalog, opened := open_catalog(h.store_root, verify = false)
	if !opened do return false, .Storage
	defer db.close(catalog)
	current, valid := read_generation(catalog, cluster, h.node.id, sql.membership_slice(&h.node.membership))
	defer delete(current)
	if !valid || current != h.store_current do return false, .Storage
	name, ok := retirement_candidate(catalog, current, h.generation_previous)
	defer delete(name)
	if !ok do return false, .Storage
	if name == "" do return false, .None
	root_name := strings.clone_to_cstring(h.store_root)
	defer delete(root_name)
	root := posix.open(root_name, {.DIRECTORY, .NOFOLLOW})
	if root < 0 do return false, .Storage
	defer posix.close(root)
	if err := retire_directory(root, name); err != .None do return false, err
	if checkpoint != nil do checkpoint(.After_Retirement_Files)
	if posix.fsync(root) != nil do return false, .Storage
	if checkpoint != nil do checkpoint(.After_Retirement_Sync)
	if !db.begin_tx(catalog) do return false, .Storage
	defer db.rollback_tx(catalog)
	stmt: db.Sqlite3_Stmt
	query := "DELETE FROM _sqlodin_generation_inventory WHERE name=?"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return false, .Storage
	}
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_bind_text(stmt, 1, cstring(raw_data(name)), c.int(len(name)), nil) != db.OK ||
		db.sqlite3_step(stmt) != db.DONE { return false, .Storage }
	if checkpoint != nil do checkpoint(.Before_Retirement_Commit)
	if !db.commit_tx(catalog) do return false, .Storage
	return true, .None
}

@(private)
retire_directory :: proc(root: posix.FD, name: string) -> Error {
	path := strings.clone_to_cstring(name)
	defer delete(path)
	directory := posix.openat(root, path, {.DIRECTORY, .NOFOLLOW})
	if directory < 0 do return .None if posix.errno() == .ENOENT else .Storage
	defer posix.close(directory)
	locks := [2]posix.FD{-1, -1}
	defer for fd in locks do if fd >= 0 { posix.close(fd) }
	for lock, i in ([2]cstring{"node.db.lock", "consensus.db.lock"}) {
		locks[i] = posix.openat(directory, lock, {.RDWR, .NOFOLLOW})
		if locks[i] < 0 {
			if posix.errno() != .ENOENT do return .Storage
		} else if lock_file(locks[i], 2 | 4) != 0 { return .Backpressure }
	}
	// Unlink only known owned files; unlinkat never follows a file symlink.
	// Unexpected files/subdirectories prevent rmdir and remain untouched.
	for file in ([11]cstring{"node.db", "node.db-wal", "node.db-shm", "node.db-journal", "node.db.lock",
		"consensus.db", "consensus.db-wal", "consensus.db-shm", "consensus.db-journal",
		"consensus.db.lock", "store.lock"}) {
		if posix.unlinkat(directory, file, {}) != nil && posix.errno() != .ENOENT do return .Storage
	}
	return .None if posix.unlinkat(root, path, {.REMOVEDIR}) == nil else .Storage
}
