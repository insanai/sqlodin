package durable

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

retire_snapshot_image :: proc(h: ^Host, cluster: string,
	checkpoint: proc(Generation_Phase) = nil) -> (bool, Error) {
	if h == nil || h.poisoned || !h.store_guard_owned do return false, .Invalid
	if h.compaction != nil || h.snapshot_busy ||
		h.snapshot != nil && snapshot_worker_running(h.snapshot) { return false, .Backpressure }
	catalog, opened := open_catalog(h.store_root, verify = false)
	if !opened do return false, .Storage
	defer db.close(catalog)
	current, valid := read_generation(catalog, cluster, h.node.id, sql.membership_slice(&h.node.membership))
	defer delete(current)
	if !valid || current != h.store_current do return false, .Storage
	previous, previous_ok := predecessor_image(h)
	if !previous_ok do return false, .Storage
	defer delete(previous)
	entry, found, ok := image_retirement_candidate(catalog, h.generation_image_name, previous,
		h.snapshot_sealed.key.prefix)
	if !ok do return false, .Storage
	if !found do return false, .None
	defer delete(entry.name)
	defer delete(entry.manifest)
	defer delete(entry.directory)
	if !delete_owned_image(entry, checkpoint) do return false, .Storage
	if !db.begin_tx(catalog) do return false, .Storage
	defer db.rollback_tx(catalog)
	stmt: db.Sqlite3_Stmt
	query := "DELETE FROM _sqlodin_image_inventory WHERE name=?"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return false, .Storage
	}
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_bind_text(stmt, 1, cstring(raw_data(entry.name)), c.int(len(entry.name)), nil) != db.OK ||
		db.sqlite3_step(stmt) != db.DONE { return false, .Storage }
	if checkpoint != nil do checkpoint(.Before_Image_Retirement_Commit)
	if !db.commit_tx(catalog) do return false, .Storage
	return true, .None
}

@(private)
predecessor_image :: proc(h: ^Host) -> (string, bool) {
	if h.generation_previous == "" do return "", true
	previous := new(Host)
	previous.lock, previous.consensus_lock = -1, -1
	defer close(previous)
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s/consensus.db", h.store_root, h.generation_previous))
	defer delete(path)
	if db.sqlite3_open_v2(path, &previous.consensus, db.OPEN_READONLY | db.OPEN_NOFOLLOW, nil) != db.OK {
		return "", false
	}
	previous.node.membership, previous.configuration = h.node.membership, h.configuration
	previous.genesis, previous.genesis_hash = h.genesis, h.genesis_hash
	previous.engine.applied_through = max(sql.Slot)
	if !load_generation_base(previous) || previous.generation_base.key.prefix == 0 do return "", false
	return strings.clone(previous.generation_image_name), true
}

@(private)
delete_owned_image :: proc(entry: Image_Inventory, checkpoint: proc(Generation_Phase)) -> bool {
	path := strings.clone_to_cstring(entry.directory)
	defer delete(path)
	directory := posix.open(path, {.DIRECTORY, .NOFOLLOW})
	if directory < 0 do return false
	defer posix.close(directory)
	for suffix in ([4]string{"", "-wal", "-shm", "-journal"}) {
		name := strings.clone_to_cstring(fmt.tprintf("%s%s", entry.name, suffix))
		ok := posix.unlinkat(directory, name, {}) == nil || posix.errno() == .ENOENT
		delete(name)
		if !ok do return false
	}
	manifest := strings.clone_to_cstring(entry.manifest)
	defer delete(manifest)
	if posix.unlinkat(directory, manifest, {}) != nil && posix.errno() != .ENOENT do return false
	if checkpoint != nil do checkpoint(.After_Image_Retirement_Files)
	if posix.fsync(directory) != nil do return false
	if checkpoint != nil do checkpoint(.After_Image_Retirement_Sync)
	return true
}
