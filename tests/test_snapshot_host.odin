package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import sql "../src"
import durable "../src/durable"
import snapshot "../src/snapshot"

@(test)
test_snapshot_host_pins_group_boundary_and_requires_real_quorum :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3, separated = true)
	defer durable_test_close(c)
	for h, i in c.hosts {
		directory := fmt.aprintf("%s/snapshots-%d", c.dir, i)
		testing.expect(t, durable.snapshot_enable(h, c.paths[i], directory) == .None)
		delete(directory)
		packets: [3]durable.Packet
		packets[0].value, _ = sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v);")
		packets[1].value = sql.mutation_make_skip(1, 0)
		packets[1].value.primary_key = 4096
		packets[1].value.sql_len = u16(len(durable.SNAPSHOT_BARRIER))
		copy(packets[1].value.sql_bytes[:], durable.SNAPSHOT_BARRIER)
		packets[2].value, _ = sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(7);")
		for &packet, j in packets {
			packet.env = {from = 1, to = sql.Node_Id(i+1),
				message = sql.Commit_Message(sql.Mutation){u64(j+1), &packet.value}}
		}
		testing.expect(t, durable.step_batch(h, packets[:]) == .None)
		testing.expect(t, h.engine.applied_through == 3 && h.snapshot.prefix == 2)
		expect_rows(t, &h.engine, "SELECT * FROM t;", 1)
	}
	receipts: [3]snapshot.Receipt
	for h, i in c.hosts {
		ready := false
		for _ in 0..<3000 {
			receipts[i], ready = durable.snapshot_local_receipt(h)
			if ready || durable.snapshot_worker_failed(h.snapshot) do break
			time.sleep(time.Millisecond)
		}
		testing.expect(t, ready, "snapshot worker failed or did not finish")
		if !ready do return
		testing.expect(t, receipts[i].key.prefix == 2)
		testing.expect(t, durable.snapshot_progress(h, 0) == .None)
		testing.expect(t, h.snapshot_sealed.key.prefix == 0) // one receipt is not a quorum
	}
	testing.expect(t, receipts[0].key == receipts[1].key && receipts[1].key == receipts[2].key)
	image, image_err := sql.engine_open(c.hosts[0].snapshot.worker.image, 1)
	testing.expect(t, image_err == .None && image.applied_through == 2)
	expect_rows(t, &image, "SELECT * FROM t;", 0)
	sql.engine_close(&image)
	for h in c.hosts {
		testing.expect(t, !durable.snapshot_receive_receipt(h, 3, receipts[1]))
		for receipt in receipts {
			testing.expect(t, durable.snapshot_receive_receipt(h, receipt.voter, receipt))
		}
		testing.expect(t, durable.snapshot_progress(h, 0) == .None)
	}
	for _ in 0..<20 {
		durable_test_drain(t, c)
		for h in c.hosts do testing.expect(t, durable.progress(h) == .None)
	}
	for h, i in c.hosts {
		testing.expect(t, h.snapshot_sealed.key.prefix == 2 && h.snapshot_seal_slot > 2)
		durable_test_reopen(t, c, i, 3)
		testing.expect(t, c.hosts[i].snapshot_sealed.key.prefix == 2)
		expect_rows(t, &c.hosts[i].engine, "SELECT * FROM t;", 1)
	}
}

@(test)
test_snapshot_capture_failure_stops_further_durable_requests :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	h := c.hosts[0]
	// Obstruct the next capture with a preexisting file, rather than injecting
	// a success-shaped receipt or editing worker state.
	prefix := h.engine.applied_through+1
	path := fmt.aprintf("%s/image-%d.db", h.snapshot.directory, prefix)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, []u8{7}) == nil)
	value := sql.mutation_make_skip(1, 0)
	value.primary_key = 4096
	value.sql_len = u16(len(durable.SNAPSHOT_BARRIER))
	copy(value.sql_bytes[:], durable.SNAPSHOT_BARRIER)
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Commit_Message(sql.Mutation){prefix, &value}}
	testing.expect(t, durable.step(h, env) == .None)
	testing.expect(t, durable.snapshot_worker_failed(h.snapshot))
	testing.expect(t, durable.snapshot_progress(h, 0) == .Storage && h.poisoned)
	_, err := durable.propose(h, sql.mutation_make_skip(1, 0))
	testing.expect(t, err == .Poisoned && os.exists(path))
}
