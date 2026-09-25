package main

import "core:fmt"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

stop_before_application :: proc() { posix.kill(posix.getpid(), .SIGSTOP) }

group_values :: proc(values: []sql.Mutation) {
	for &m, i in values {
		id := sql.Request_Id{sequence = 1}
		id.session[0] = u8(i + 1)
		text := fmt.tprintf("INSERT INTO t VALUES(%d);", i / 2)
		err: sql.Error
		m, err = sql.mutation_make_transaction(1, id, text)
		must(err == .None)
	}
}

run_group :: proc(path, mode, boundary: string) {
	ids := [1]sql.Node_Id{1}
	h, err := probe_open(path, "group-crash", 1, ids[:], create = mode == "group-init")
	must(err == .None)
	defer durable.close(h)
	if mode == "group-init" {
		m, make_err := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v UNIQUE);")
		must(make_err == .None)
		slot, propose_err := durable.propose(h, m)
		must(propose_err == .None && durable.acknowledged(h, slot, &m))
		return
	}
	values: [3]sql.Mutation
	group_values(values[:])
	if mode == "group-verify" {
		rows, read_err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t;")
		want := 0 if boundary == "before" else 2
		must(read_err == .None && rows == want)
	} else {
		switch boundary {
		case "before": stop_at = .Before_Journal_Commit
		case "journal": stop_at = .After_Journal_Commit
		case "sql": h.engine.application_before_commit = stop_before_application
		case "application": stop_at = .After_Application_Commit
		case "ack":
		case: must(false)
		}
		h.checkpoint = checkpoint
	}
	slots: [3]sql.Slot
	_, propose_err := durable.propose_batch(h, values[:], slots[:])
	must(propose_err == .None)
	for slot, i in slots {
		out, complete, read_err := durable.outcome(h, slot, &values[i])
		want: sql.Transaction_Outcome = .Constraint if i == 1 else .Applied
		must(read_err == .None && complete && out.kind == want && out.slot == u64(i + 2))
	}
	if mode != "group-verify" {
		must(boundary == "ack")
		posix.kill(posix.getpid(), .SIGSTOP)
	}
	rows, read_err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t WHERE v IN (0,1);")
	must(read_err == .None && rows == 2)
	fmt.println("verified application group: two effects, independent rejection, stable retry outcomes")
}
