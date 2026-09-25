package main

import "core:fmt"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

session_submit :: proc(h: ^durable.Host, value: sql.Mutation) -> sql.Outcome {
	value := value
	slot, err := durable.propose(h, value)
	must(err == .None)
	out, found, read_err := durable.outcome(h, slot, &value)
	must(read_err == .None && found)
	return out
}

run_session :: proc(path, mode, boundary: string) {
	ids := [1]sql.Node_Id{1}
	h, err := probe_open(path, "session-crash", 1, ids[:], create = mode == "session-init")
	must(err == .None)
	defer durable.close(h)
	request := sql.Request_Id{sequence = 1}
	request.session[0] = 1
	value, value_err := sql.mutation_make_transaction(1, request, "INSERT INTO t VALUES(7)")
	must(value_err == .None)
	if mode == "session-init" {
		ddl, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v)")
		must(session_submit(h, ddl).kind == .Applied)
		must(session_submit(h, value).kind == .Applied)
		return
	}
	retire, _ := sql.mutation_make_session_retirement(1, 0)
	if mode == "session-write" {
		switch boundary {
		case "before": stop_at = .Before_Journal_Commit
		case "journal": stop_at = .After_Journal_Commit
		case "sql": h.engine.application_before_commit = stop_before_application
		case "application": stop_at = .After_Application_Commit
		case "ack":
		case: must(false)
		}
		h.checkpoint = checkpoint
		must(session_submit(h, retire).kind == .Applied)
		posix.kill(posix.getpid(), .SIGSTOP)
		return
	}
	epoch, epoch_err := sql.engine_session_epoch(&h.engine)
	must(epoch_err == .None && epoch == (0 if boundary == "before" else 1))
	must(session_submit(h, value).kind == (.Applied if epoch == 0 else .Expired))
	must(session_submit(h, retire).kind == .Applied)
	must(session_submit(h, value).kind == .Expired)
	value.request.epoch = 1
	must(session_submit(h, value).kind == .Applied)
	must(session_submit(h, retire).kind == .Applied)
	must(session_submit(h, value).kind == .Applied)
	rows, query_err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t WHERE v=7")
	must(query_err == .None && rows == 2)
	fmt.println("verified durable epoch, old-request fence and current-epoch deduplication")
}
