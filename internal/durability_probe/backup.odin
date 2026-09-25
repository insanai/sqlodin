package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

backup_stop: string
backup_checkpoint :: proc(phase: durable.Backup_Phase) {
	if fmt.tprintf("%v", phase) == backup_stop do posix.kill(posix.getpid(), .SIGSTOP)
}

run_backup :: proc(directory, mode, boundary: string) {
	source, backup := fmt.aprintf("%s/source", directory), fmt.aprintf("%s/backup", directory)
	defer delete(source)
	defer delete(backup)
	create := mode == "backup-write"
	if create do must(os.make_directory(source) == nil)
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(source, "backup-crash", 1, ids[:], create = create)
	must(err == .None)
	defer durable.close(h)
	value, _ := sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(7)")
	ballot := sql.ballot_make(33, 0, 1)
	if !create {
		rows, read_err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t")
		must(read_err == .None && rows == 1 && h.node.ledger.promised == ballot)
		vote, _, found := sql.ledger_vote_at(&h.node.ledger, 10)
		must(found && vote == ballot)
		id, id_err := durable.next_id(h, 0)
		must(id_err == .None && id > u64(100)<<22)
		manifest, verify_err := durable.verify_backup(backup)
		written := strings.contains(boundary, "Manifest_Sync") || boundary == "Manifest_Durable"
		must((written && verify_err == .None && manifest.prefix == 2) ||
			(!written && verify_err == .Storage))
		fmt.printf("verified source rows=1 promise/vote/IDs preserved backup-complete=%v\n", written)
		return
	}
	schema, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	_, err = durable.propose(h, schema)
	must(err == .None)
	slot, write_err := durable.propose(h, value)
	must(write_err == .None && durable.acknowledged(h, slot, &value))
	_, id_err := durable.next_id(h, 100)
	must(id_err == .None)
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Prepare_Message{ballot, 10, 10, .Global}}
	must(durable.step(h, env) == .None)
	env.message = sql.Accept_Message(sql.Mutation){ballot, 10, &value}
	must(durable.step(h, env) == .None)
	backup_stop = boundary
	_, err = durable.backup_store(h, "backup-crash", backup, backup_checkpoint)
	must(err == .None)
	must(false)
}
