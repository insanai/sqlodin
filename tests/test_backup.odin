package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import durable "../src/durable"

@(test)
test_backup_empty_and_populated_application_preserve_source_and_reject_corruption :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(root, "backup-test", 1, ids[:], create = true)
	testing.expect(t, err == .None)
	if h == nil do return
	defer durable.close(h)
	for cycle in 0..<2 {
		if cycle == 1 {
			for text in ([5]string{"CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)",
				"CREATE VIRTUAL TABLE search USING fts5(body)", "INSERT INTO search VALUES('first')",
				"CREATE TABLE vectors(id INTEGER PRIMARY KEY, embedding BLOB)",
				"INSERT INTO vectors VALUES(1,x'0000803f00000040')"}) {
				value, _ := sql.mutation_make_raw_sql(1, 0, text)
				slot, write_err := durable.propose(h, value)
				testing.expect(t, write_err == .None && durable.acknowledged(h, slot, &value), text)
			}
			request := sql.Request_Id{sequence = 1}
			request.session[0] = 1
			value, _ := sql.mutation_make_transaction(1, request, "INSERT INTO t VALUES(1,'durable')")
			slot, transaction_err := durable.propose(h, value)
			testing.expect(t, transaction_err == .None && durable.acknowledged(h, slot, &value))
		}
		path := fmt.aprintf("%s/backup-%d", root, cycle)
		defer delete(path)
		sequence, applied := h.sequence, h.engine.applied_through
		manifest, backup_err := durable.backup_store(h, "backup-test", path)
		testing.expect(t, backup_err == .None && manifest.prefix == applied)
		if backup_err != .None do return
		verified, verify_err := durable.verify_backup(path)
		testing.expect(t, verify_err == .None && verified == manifest)
		testing.expect(t, h.sequence == sequence && h.engine.applied_through == applied && !h.poisoned)
		_, duplicate := durable.backup_store(h, "backup-test", path)
		testing.expect(t, duplicate == .Storage)
		encoded := durable.backup_manifest_encode(manifest)
		decoded, valid := durable.backup_manifest_decode(encoded[:])
		testing.expect(t, valid && decoded == manifest)
		encoded[len(encoded)-1] ~= 1
		_, valid = durable.backup_manifest_decode(encoded[:])
		testing.expect(t, !valid)
		image := fmt.aprintf("%s/application.db", path)
		defer delete(image)
		bytes, read_err := os.read_entire_file(image, context.allocator)
		testing.expect(t, read_err == nil)
		defer delete(bytes)
		bytes[len(bytes)-1] ~= 1
		testing.expect(t, os.write_entire_file(image, bytes) == nil)
		_, verify_err = durable.verify_backup(path)
		testing.expect(t, verify_err == .Storage)
	}
	expect_rows(t, &h.engine, "SELECT * FROM t", 1)
}
