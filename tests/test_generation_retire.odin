package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:sys/posix"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

@(test)
test_retirement_preserves_exact_predecessor_and_unowned_directories :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "sqlodin-retire-", context.allocator)
	defer delete(root)
	defer os.remove_all(root)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(root, "test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	images := fmt.aprintf("%s/snapshots", root)
	defer delete(images)
	paths: [3]string
	defer for path in paths do delete(path)
	for cycle in 0..<3 {
		generation_test_snapshot(t, h, images)
		next, compact_err := durable.compact_store(h, "test")
		testing.expect(t, compact_err == .None)
		if next == nil do return
		durable.close(h)
		h = next
		paths[cycle] = fmt.aprintf("%s/%s", root, h.store_current)
		durable.close(h)
		h, err = durable.open_store(root, "test", 1, ids[:])
		testing.expect(t, err == .None)
		if h == nil do return
	}
	unknown := fmt.aprintf("%s/generation-999-999", root)
	defer delete(unknown)
	testing.expect(t, os.make_directory(unknown) == nil)
	lock, locked := durable.lock_database(fmt.tprintf("%s/node.db", paths[0]), false)
	testing.expect(t, locked)
	busy, busy_err := durable.retire_generation(h, "test")
	testing.expect(t, !busy && busy_err == .Backpressure && os.exists(paths[0]))
	if locked do posix.close(lock)
	retired, retire_err := durable.retire_generation(h, "test")
	testing.expect(t, retired && retire_err == .None)
	testing.expect(t, !os.exists(paths[0]) && os.exists(paths[1]) && os.exists(paths[2]))
	testing.expect(t, os.exists(unknown))
	retired, retire_err = durable.retire_generation(h, "test")
	testing.expect(t, !retired && retire_err == .None)
	generation_test_snapshot(t, h, images)
	testing.expect(t, durable.begin_compaction(h, "test") == .None)
	if h.compaction == nil do return
	abandoned := strings.clone(h.compaction.directory)
	defer delete(abandoned)
	durable.generation_release_worker(h)
	testing.expect(t, os.exists(abandoned))
	// A killed initial SQLite backup may leave a rollback journal before the
	// candidate switches to WAL. It is owned staging data, not an unknown file.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/node.db-journal", abandoned), []u8{1}) == nil)
	retired, retire_err = durable.retire_generation(h, "test")
	testing.expect(t, retired && retire_err == .None && !os.exists(abandoned))
	testing.expect(t, os.exists(paths[1]) && os.exists(paths[2]) && os.exists(unknown))
	durable.close(h)
	h, err = durable.open_store(root, "test", 1, ids[:])
	testing.expect(t, err == .None)
}

@(test)
test_retirement_rejects_corrupt_inventory_without_deleting_candidate :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	testing.expect(t, durable.begin_compaction(h, "test") == .None)
	if h.compaction == nil do return
	path := strings.clone(h.compaction.directory)
	defer delete(path)
	durable.generation_release_worker(h)
	testing.expect(t, db.exec(h.consensus,
		"UPDATE _sqlodin_generation_inventory SET digest=zeroblob(32)"))
	retired, err := durable.retire_generation(h, "test")
	testing.expect(t, !retired && err == .Storage && os.exists(path))
	testing.expect(t, h.store_current == "" && !h.poisoned)
}

@(test)
test_generation_allocation_never_inventories_a_preexisting_directory :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	token, token_err := durable.next_id(h, 0)
	testing.expect(t, token_err == .None)
	path := fmt.aprintf("%s/generation-%d-%d", h.store_root, h.snapshot_sealed.key.prefix, token+1)
	defer delete(path)
	testing.expect(t, os.make_directory(path) == nil)
	marker := fmt.aprintf("%s/user-data", path)
	defer delete(marker)
	testing.expect(t, os.write_entire_file(marker, []u8{7}) == nil)
	next, err := durable.compact_store(h, "test")
	testing.expect(t, next == nil && err == .Storage && !h.poisoned)
	retired, retire_err := durable.retire_generation(h, "test")
	testing.expect(t, !retired && retire_err == .None && os.exists(marker))
}
