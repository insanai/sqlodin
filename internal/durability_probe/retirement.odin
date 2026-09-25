package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import sql "../../src"
import durable "../../src/durable"

run_retirement :: proc(directory, mode, boundary: string) {
	ids := [1]sql.Node_Id{1}
	h, err := durable.open_store(directory, "retirement-crash", 1, ids[:],
		create = strings.has_suffix(mode, "write"))
	must(err == .None)
	defer durable.close(h)
	if strings.has_suffix(mode, "verify") { retirement_verify(h); return }
	value, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
	_, err = durable.propose(h, value)
	must(err == .None)
	images := fmt.aprintf("%s/images", directory)
	defer delete(images)
	must(durable.snapshot_enable(h, h.application_path, images) == .None)
	for _ in 0..<3 {
		value, _ = sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(7)")
		slot, write_err := durable.propose(h, value)
		must(write_err == .None && durable.acknowledged(h, slot, &value))
		snapshot_slot, snapshot_err := durable.begin_snapshot(h, 0)
		must(snapshot_err == .None)
		for _ in 0..<3000 {
			must(durable.snapshot_progress(h, 0) == .None)
			if h.snapshot_sealed.key.prefix >= snapshot_slot do break
			time.sleep(time.Millisecond)
		}
		must(h.snapshot_sealed.key.prefix >= snapshot_slot)
		next, compact_err := durable.compact_store(h, "retirement-crash")
		must(compact_err == .None)
		durable.close(h)
		h = next
	}
	_, id_err := durable.next_id(h, 100)
	must(id_err == .None)
	ballot := sql.ballot_make(33, 0, 1)
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Prepare_Message{ballot, 50, 50, .Global}}
	must(durable.step(h, env) == .None)
	env.message = sql.Accept_Message(sql.Mutation){ballot, 50, &value}
	must(durable.step(h, env) == .None)
	vote, _, found := sql.ledger_vote_at(&h.node.ledger, 50)
	must(found && vote == ballot)
	generation_stop = boundary
	retire_err: durable.Error
	if mode == "retire-image-write" {
		_, retire_err = durable.retire_snapshot_image(h, "retirement-crash", generation_checkpoint)
	} else if mode == "retire-root-write" {
		_, retire_err = durable.retire_root_application(h, "retirement-crash", generation_checkpoint)
	} else {
		_, retire_err = durable.retire_generation(h, "retirement-crash", generation_checkpoint)
	}
	must(retire_err == .None)
	must(false)
}

retirement_verify :: proc(h: ^durable.Host) {
	for _ in 0..<2 {
		retired, err := durable.retire_generation(h, "retirement-crash")
		must(err == .None)
		if !retired do break
	}
	retired, retire_err := durable.retire_generation(h, "retirement-crash")
	must(!retired && retire_err == .None)
	for name in ([2]string{h.store_current, h.generation_previous}) {
		must(name != "" && os.exists(fmt.tprintf("%s/%s/node.db", h.store_root, name)))
	}
	for _ in 0..<3 {
		image_retired, image_err := durable.retire_snapshot_image(h, "retirement-crash")
		must(image_err == .None)
		if !image_retired do break
	}
	must(os.exists(fmt.tprintf("%s/images/%s", h.store_root, h.generation_image_name)))
	_, root_err := durable.retire_root_application(h, "retirement-crash")
	must(root_err == .None && !os.exists(fmt.tprintf("%s/node.db", h.store_root)))
	rows, err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t")
	must(err == .None && rows == 3)
	vote, _, found := sql.ledger_vote_at(&h.node.ledger, 50)
	must(found && vote == sql.ballot_make(33, 0, 1) && h.node.ledger.promised == vote)
	id, id_err := durable.next_id(h, 0)
	must(id_err == .None && id > u64(100)<<22)
	fmt.printf("verified retirement current=%s previous=%s rows=3 accepted=50 IDs=preserved\n",
		h.store_current, h.generation_previous)
}
