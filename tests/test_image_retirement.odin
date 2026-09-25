package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sql "../src"
import durable "../src/durable"

@(test)
test_image_retirement_keeps_active_predecessor_and_unsealed_receipt :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(root, "test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	images := fmt.aprintf("%s/images", root)
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
		paths[cycle] = fmt.aprintf("%s/%s", images, h.generation_image_name)
		durable.close(h)
		h, err = durable.open_store(root, "test", 1, ids[:])
		testing.expect(t, err == .None)
		if h == nil do return
	}
	testing.expect(t, durable.snapshot_enable(h, h.application_path, images) == .None)
	_, snapshot_err := durable.begin_snapshot(h, 0)
	testing.expect(t, snapshot_err == .None)
	for _ in 0..<3000 {
		if !durable.snapshot_worker_running(h.snapshot) do break
		time.sleep(time.Millisecond)
	}
	_, receipt_ready := durable.snapshot_local_receipt(h)
	testing.expect(t, receipt_ready && h.snapshot.prefix > h.snapshot_sealed.key.prefix)
	unsealed := strings.clone(h.snapshot.worker.image)
	defer delete(unsealed)
	retired, retire_err := durable.retire_snapshot_image(h, "test")
	testing.expect(t, retired && retire_err == .None && !os.exists(paths[0]))
	testing.expect(t, os.exists(paths[1]) && os.exists(paths[2]) && os.exists(unsealed))
	retired, retire_err = durable.retire_snapshot_image(h, "test")
	testing.expect(t, !retired && retire_err == .None && os.exists(unsealed))
}

@(test)
test_abandoned_incoming_image_can_retire_without_a_successor_certificate :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	h := c.hosts[0]
	path := fmt.aprintf("%s/incoming-10-100.db", h.snapshot.directory)
	manifest := fmt.aprintf("%s.manifest", path)
	defer delete(path)
	defer delete(manifest)
	testing.expect(t, durable.register_snapshot_image(h, path, manifest, 10, received = true) == .None)
	testing.expect(t, os.write_entire_file(path, []u8{1, 2, 3}) == nil)
	h.snapshot_busy = true
	retired, err := durable.retire_snapshot_image(h, "test")
	testing.expect(t, !retired && err == .Backpressure && os.exists(path))
	h.snapshot_busy = false
	retired, err = durable.retire_snapshot_image(h, "test")
	testing.expect(t, retired && err == .None && !os.exists(path))
	// A preexisting file is never adopted into the deletion inventory.
	testing.expect(t, os.write_entire_file(path, []u8{7}) == nil)
	testing.expect(t, durable.register_snapshot_image(h, path, manifest, 10, received = true) == .Storage)
	retired, err = durable.retire_snapshot_image(h, "test")
	testing.expect(t, !retired && err == .None && os.exists(path))
}
