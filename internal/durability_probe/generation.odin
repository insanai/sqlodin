package main

import "core:fmt"
import "core:time"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

generation_stop: string

generation_checkpoint :: proc(phase: durable.Generation_Phase) {
	if fmt.tprintf("%v", phase) == generation_stop do posix.kill(posix.getpid(), .SIGSTOP)
}

run_generation :: proc(directory, mode, boundary: string) {
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(directory, "generation-crash", 1, ids[:], create = mode == "gen-write")
	must(err == .None)
	defer durable.close(h)
	session: [16]u8
	session[0] = 1
	value, value_err := sql.mutation_make_transaction(1, {session, 1, 0}, "INSERT INTO t VALUES(7)")
	must(value_err == .None)
	if mode == "gen-verify" {
		generation_verify(h, &value, boundary == "After_Publication")
		return
	}
	create, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	_, err = durable.propose(h, create)
	must(err == .None)
	images := fmt.aprintf("%s/images", directory)
	defer delete(images)
	must(durable.snapshot_enable(h, h.application_path, images) == .None)
	slot, snapshot_err := durable.begin_snapshot(h, 0)
	must(snapshot_err == .None)
	for _ in 0..<3000 {
		must(durable.snapshot_progress(h, 0) == .None)
		if h.snapshot_sealed.key.prefix >= slot do break
		must(!durable.snapshot_worker_failed(h.snapshot))
		time.sleep(time.Millisecond)
	}
	must(h.snapshot_sealed.key.prefix >= slot)
	write_slot, write_err := durable.propose(h, value)
	must(write_err == .None && durable.acknowledged(h, write_slot, &value))
	reserved, id_err := durable.next_id(h, 100)
	must(id_err == .None && reserved != 0)
	// A future accepted value must survive even though it was never acknowledged.
	ballot := sql.ballot_make(33, 0, 1)
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Prepare_Message{ballot, 10, 10, .Global}}
	must(durable.step(h, env) == .None)
	env.message = sql.Accept_Message(sql.Mutation){ballot, 10, &value}
	must(durable.step(h, env) == .None)
	generation_stop = boundary
	new_host, compact_err := durable.compact_store(h, "generation-crash", generation_checkpoint)
	must(compact_err == .None)
	durable.close(new_host)
	must(false) // Every requested boundary must stop before returning to the harness.
}

generation_verify :: proc(h: ^durable.Host, expected: ^sql.Mutation, published: bool) {
	must((h.generation_base.key.prefix > 0) == published)
	rows, err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t WHERE v=7")
	must(err == .None && rows == 1)
	vote, value, found := sql.ledger_vote_at(&h.node.ledger, 10)
	must(found && vote == sql.ballot_make(33, 0, 1) && value^ == expected^)
	must(h.node.ledger.promised == vote)
	id, id_err := durable.next_id(h, 0)
	must(id_err == .None && id > u64(100)<<22)
	// Confirm retry fences directly in the durable application state; deliberately
	// do not deliver the still-unacknowledged accepted slot while checking the retry.
	retry := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Commit_Message(sql.Mutation){h.engine.applied_through+1, expected}}
	must(durable.step(h, retry) == .None)
	rows, err = sql.engine_read_snapshot(&h.engine, "SELECT * FROM t WHERE v=7")
	must(err == .None && rows == 1)
	fmt.printf("verified generation=%d rows=%d promise=%d accepted=10 retry=once\n",
		h.generation_base.key.prefix, rows, vote)
}
