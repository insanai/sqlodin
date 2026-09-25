package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

restore_stop: string
restore_checkpoint :: proc(phase: durable.Restore_Phase) {
	if fmt.tprintf("%v", phase) == restore_stop do posix.kill(posix.getpid(), .SIGSTOP)
}

run_restore :: proc(directory, mode, boundary: string) {
	source, backup, restored := fmt.aprintf("%s/source", directory), fmt.aprintf("%s/backup", directory),
		fmt.aprintf("%s/restored", directory)
	defer delete(source)
	defer delete(backup)
	defer delete(restored)
	ids := [1]sql.Node_Id{1}
	if mode == "restore-write" {
		must(os.make_directory(source) == nil)
		h, err := durable.open_store(source, "old", 1, ids[:], create = true)
		must(err == .None)
		defer durable.close(h)
		schema, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
		_, err = durable.propose(h, schema)
		must(err == .None)
		request := sql.Request_Id{sequence = 1}
		request.session[0] = 1
		value, _ := sql.mutation_make_transaction(1, request, "INSERT INTO t VALUES(7)")
		slot, write_err := durable.propose(h, value)
		must(write_err == .None && durable.acknowledged(h, slot, &value))
		_, backup_err := durable.backup_store(h, "old", backup)
		must(backup_err == .None)
		restore_stop = boundary
		must(durable.restore_backup(backup, restored, "fresh", 1, ids[:], restore_checkpoint) == .None)
		must(false)
		return
	}
	manifest, verify_err := durable.verify_backup(backup)
	must(verify_err == .None && manifest.prefix == 2)
	h, err := durable.open_store(restored, "fresh", 1, ids[:])
	defer durable.close(h)
	if boundary != "Ready" {
		must(err == .Storage && h == nil)
		fmt.println("verified incomplete restore cannot open; original backup remains valid")
		return
	}
	must(err == .None && h.genesis.prefix == 2 && h.sequence == 0)
	rows, read_err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t")
	must(read_err == .None && rows == 1)
	request := sql.Request_Id{sequence = 1}
	request.session[0] = 1
	value, _ := sql.mutation_make_transaction(1, request, "INSERT INTO t VALUES(7)")
	slot, write_err := durable.propose(h, value)
	must(write_err == .None && durable.acknowledged(h, slot, &value))
	rows, read_err = sql.engine_read_snapshot(&h.engine, "SELECT * FROM t")
	must(read_err == .None && rows == 1)
	fmt.println("verified ready restore preserves data/retry fence with fresh acceptor state")
}
