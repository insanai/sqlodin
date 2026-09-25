package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:sys/posix"
import sql "../src"
import durable "../src/durable"

@(test)
test_root_retirement_protects_first_predecessor_and_is_one_time :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(root, "test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	images, original := fmt.aprintf("%s/images", root), fmt.aprintf("%s/node.db", root)
	defer delete(images)
	defer delete(original)
	for _ in 0..<2 {
		retired, retire_err := durable.retire_root_application(h, "test")
		testing.expect(t, !retired && retire_err == .None && os.exists(original))
		generation_test_snapshot(t, h, images)
		next, compact_err := durable.compact_store(h, "test")
		testing.expect(t, compact_err == .None)
		if next == nil do return
		durable.close(h)
		h = next
		durable.close(h)
		h, err = durable.open_store(root, "test", 1, ids[:])
		testing.expect(t, err == .None)
		if h == nil do return
	}
	lock, locked := durable.lock_database(original, false)
	testing.expect(t, locked)
	retired, retire_err := durable.retire_root_application(h, "test")
	testing.expect(t, !retired && retire_err == .Backpressure && os.exists(original))
	if locked do posix.close(lock)
	retired, retire_err = durable.retire_root_application(h, "test")
	testing.expect(t, retired && retire_err == .None && !os.exists(original))
	durable.close(h)
	h, err = durable.open_store(root, "test", 1, ids[:])
	testing.expect(t, err == .None)
	if h == nil do return
	// Once completion is durable, the old pathname is no longer owned.
	testing.expect(t, os.write_entire_file(original, []u8{1, 2, 3}) == nil)
	retired, retire_err = durable.retire_root_application(h, "test")
	testing.expect(t, !retired && retire_err == .None && os.exists(original))
	testing.expect(t, os.exists(fmt.tprintf("%s/%s/node.db", root, h.store_current)))
	testing.expect(t, os.exists(fmt.tprintf("%s/%s/node.db", root, h.generation_previous)))
}
