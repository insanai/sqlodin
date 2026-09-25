package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import sql "../src"
import durable "../src/durable"
import snapshot "../src/snapshot"

Install_Test :: struct { root: string, directories: [3]string, hosts: [3]^durable.Host }

install_test_open :: proc(t: ^testing.T) -> ^Install_Test {
	c := new(Install_Test)
	c.root, _ = os.make_directory_temp("", "sqlodin-install-", context.allocator)
	ids := [3]sql.Node_Id{1, 2, 3}
	for id, i in ids {
		c.directories[i] = fmt.aprintf("%s/node-%d", c.root, id)
		testing.expect(t, os.make_directory(c.directories[i]) == nil)
		err: durable.Error
		c.hosts[i], err = durable.open_store(c.directories[i], "test", id, ids[:], create = true)
		testing.expect(t, err == .None)
		assert(c.hosts[i] != nil)
		directory := fmt.aprintf("%s/snapshots", c.directories[i])
		testing.expect(t,
			durable.snapshot_enable(c.hosts[i], c.hosts[i].application_path, directory) == .None)
		delete(directory)
	}
	return c
}

install_test_close :: proc(c: ^Install_Test) {
	for h in c.hosts do durable.close(h)
	for directory in c.directories do delete(directory)
	os.remove_all(c.root)
	delete(c.root)
	free(c)
}

install_test_commit :: proc(t: ^testing.T, h: ^durable.Host, slot: sql.Slot, value: sql.Mutation) {
	copy := value
	env := sql.Envelope(sql.Mutation){from = 1, to = h.node.id,
		message = sql.Commit_Message(sql.Mutation){slot, &copy}}
	testing.expect(t, durable.step(h, env) == .None)
}

install_test_seal :: proc(t: ^testing.T, c: ^Install_Test) -> durable.Generation_Seal {
	create, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	insert, _ := sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(7)")
	barrier := sql.mutation_make_skip(1, 0)
	barrier.primary_key, barrier.sql_len = 4096, u16(len(durable.SNAPSHOT_BARRIER))
	copy(barrier.sql_bytes[:], durable.SNAPSHOT_BARRIER)
	for h, i in c.hosts {
		install_test_commit(t, h, 1, create)
		if i == 2 do continue
		install_test_commit(t, h, 2, insert)
		install_test_commit(t, h, 3, barrier)
	}
	receipts: [2]snapshot.Receipt
	for h, i in c.hosts[:2] {
		ready := false
		for _ in 0..<3000 {
			receipts[i], ready = durable.snapshot_local_receipt(h)
			if ready || durable.snapshot_worker_failed(h.snapshot) do break
			time.sleep(time.Millisecond)
		}
		testing.expect(t, ready)
		assert(ready)
	}
	members := [3]sql.Node_Id{1, 2, 3}
	certificate, err := snapshot.build(receipts[0].key, members[:], receipts[:])
	testing.expect(t, err == .None)
	encoded, encode_err := snapshot.encode(&certificate, certificate.key, members[:])
	testing.expect(t, encode_err == .None)
	value := sql.mutation_make_skip(1, 0)
	value.primary_key = 4097
	value.sql_len = u16(len(durable.SNAPSHOT_SEAL)+encoded.count)
	copy(value.sql_bytes[:], durable.SNAPSHOT_SEAL)
	copy(value.sql_bytes[len(durable.SNAPSHOT_SEAL):], encoded.bytes[:encoded.count])
	for h in c.hosts[:2] do install_test_commit(t, h, 4, value)
	return durable.Generation_Seal{certificate, 4, value}
}

@(test)
test_received_generation_preserves_local_acceptor_and_rejects_unbound_seal :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	seal := install_test_seal(t, c)
	h := c.hosts[2]
	value, _ := sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(42)")
	ballot := sql.ballot_make(33, 0, 1)
	env := sql.Envelope(sql.Mutation){from = 1, to = 3,
		message = sql.Prepare_Message{ballot, 8, 8, .Global}}
	testing.expect(t, durable.step(h, env) == .None)
	env.message = sql.Accept_Message(sql.Mutation){ballot, 8, &value}
	testing.expect(t, durable.step(h, env) == .None)
	reserved, reserve_err := durable.next_id(h, 100)
	testing.expect(t, reserve_err == .None)
	receipt, ready := durable.snapshot_local_receipt(c.hosts[0])
	testing.expect(t, ready)
	candidate := snapshot.Candidate{receipt.key, receipt.image, receipt.bytes}
	bytes, read_err := os.read_entire_file(c.hosts[0].snapshot.worker.image, context.allocator)
	defer delete(bytes)
	testing.expect(t, read_err == nil)
	image := fmt.aprintf("%s/incoming-3-1.db", h.snapshot.directory)
	defer delete(image)
	testing.expect(t, os.write_entire_file(image, bytes) == nil)
	bad, bad_err := durable.install_store(h, 3, image, "test", candidate, seal)
	testing.expect(t, bad == nil && bad_err == .Invalid)
	forged := seal
	forged.value.sql_bytes[len(durable.SNAPSHOT_SEAL)] ~= 1
	bad, bad_err = durable.install_store(h, 1, image, "test", candidate, forged)
	testing.expect(t, bad == nil && bad_err == .Invalid && !h.poisoned)
	next, install_err := durable.install_store(h, 1, image, "test", candidate, seal)
	testing.expect(t, install_err == .None)
	if next == nil do return
	durable.close(h)
	c.hosts[2], h = next, next
	testing.expect(t, h.engine.applied_through == 4 && h.node.id == 3)
	testing.expect(t, h.node.ledger.promised == ballot)
	vote, accepted, found := sql.ledger_vote_at(&h.node.ledger, 8)
	testing.expect(t, found && vote == ballot && accepted^ == value)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE v=7", 1)
	expect_rows(t, &h.engine, "SELECT * FROM t WHERE v=42", 0)
	id, id_err := durable.next_id(h, 0)
	testing.expect(t, id_err == .None && id > reserved)
}
