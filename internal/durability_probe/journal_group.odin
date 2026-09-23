package main

import "core:fmt"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

journal_vote_packets :: proc(packets: []durable.Packet) {
	ballot := sql.ballot_make(1, 0, 1)
	packets[0].env = {from = 1, to = 2,
		message = sql.Prepare_Message{ballot, 1, 16, .Global}}
	for &p, i in packets[1:] {
		p.value = sql.mutation_make_skip(1, u64(i + 11))
		p.env = {from = 1, to = 2,
			message = sql.Accept_Message(sql.Mutation){ballot, u64(i + 1), &p.value}}
	}
}

run_journal_group :: proc(path, mode, boundary: string) {
	ids := [3]sql.Node_Id{1, 2, 3}
	h, err := durable.open(path, "journal-group", 2, ids[:], create = mode == "journal-init")
	must(err == .None)
	defer durable.close(h)
	if mode == "journal-init" do return
	ballot := sql.ballot_make(1, 0, 1)
	if mode == "journal-verify" {
		want := 0 if boundary == "before" else 15
		when !durable.JOURNAL_GROUP_COMMIT {
			if boundary != "ack" do want = 0
		}
		promise := sql.Ballot(0) if boundary == "before" else ballot
		must(h.node.ledger.promised == promise && h.sequence == h.durable_sequence)
		for i in 0..<15 {
			vote, value, voted := sql.ledger_vote_at(&h.node.ledger, u64(i + 1))
			must(voted == (i < want))
			if voted do must(vote == ballot && value^ == sql.mutation_make_skip(1, u64(i + 11)))
		}
		must(h.engine.applied_through == 0)
		fmt.printf("verified promise and %d votes; no unchosen SQL applied\n", want)
		return
	}
	switch boundary {
	case "before": stop_at = .Before_Journal_Commit
	case "journal": stop_at = .After_Journal_Commit
	case "application": stop_at = .After_Application_Commit
	case "ack":
	case: must(false)
	}
	h.checkpoint = checkpoint
	packets: [16]durable.Packet
	journal_vote_packets(packets[:])
	must(durable.step_batch(h, packets[:]) == .None)
	p: durable.Packet
	responses := 0
	for durable.pop(h, &p) do responses += 1
	must(responses >= 15 && boundary == "ack")
	posix.kill(posix.getpid(), .SIGSTOP)
}
