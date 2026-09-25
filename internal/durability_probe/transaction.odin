package main

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

run_transaction :: proc(path, mode, boundary: string) {
	ids := [1]sql.Node_Id{1}
	h, err := probe_open(path, "transaction-crash", 1, ids[:], create = mode == "tx-init")
	must(err == .None)
	defer durable.close(h)
	if mode == "tx-init" {
		m, build_err := sql.mutation_make_raw_sql(1, 0,
			"CREATE TABLE counter(id PRIMARY KEY,v); INSERT INTO counter VALUES(1,0);")
		must(build_err == .None)
		slot, propose_err := durable.propose(h, m)
		must(propose_err == .None && durable.acknowledged(h, slot, &m))
		return
	}
	reject := strings.contains(mode, "reject")
	text := "UPDATE counter SET v=v+1 WHERE id=1;"
	if reject do text = "UPDATE counter SET v=v+1 WHERE id=1; INSERT INTO counter VALUES(1,99);"
	id := sql.Request_Id{sequence = 1}
	id.session[0] = 1
	m, build_err := sql.mutation_make_transaction(1, id, text)
	must(build_err == .None)
	verify := strings.contains(mode, "verify")
	if verify {
		want := 1 if boundary != "before" && !reject else 0
		query := fmt.aprintf("SELECT * FROM counter WHERE id=1 AND v=%d", want)
		defer delete(query)
		rows, read_err := sql.engine_read_snapshot(&h.engine, query)
		must(read_err == .None && rows == 1)
	} else {
		switch boundary {
		case "before": stop_at = .Before_Journal_Commit
		case "journal": stop_at = .After_Journal_Commit
		case "application": stop_at = .After_Application_Commit
		case "ack":
		case: must(false)
		}
		h.checkpoint = checkpoint
	}
	slot, propose_err := durable.propose(h, m)
	must(propose_err == .None)
	out, complete, read_err := durable.outcome(h, slot, &m)
	want: sql.Transaction_Outcome = .Constraint if reject else .Applied
	must(read_err == .None && complete && out.kind == want)
	if !verify do posix.kill(posix.getpid(), .SIGSTOP)
	// Retry again after recovery. No extra increment and exactly the same outcome.
	retry_slot, retry_err := durable.propose(h, m)
	must(retry_err == .None)
	retry, retry_complete, retry_read_err := durable.outcome(h, retry_slot, &m)
	must(retry_read_err == .None && retry_complete && retry == out)
	query := "SELECT * FROM counter WHERE id=1 AND v=1"
	if reject do query = "SELECT * FROM counter WHERE id=1 AND v=0"
	rows, value_err := sql.engine_read_snapshot(&h.engine, query)
	must(value_err == .None && rows == 1)
	fmt.printf("verified request outcome=%v original-slot=%d; retry has no extra effect\n",
		out.kind, out.slot)
}
