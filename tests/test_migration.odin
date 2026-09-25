package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

@(test)
test_migration_preserves_source_retries_and_reserved_ids :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	h := c.hosts[0]
	transaction_test_schema(t, h, "CREATE TABLE t(v INTEGER UNIQUE);")
	m := transaction_test_request(t, 1, "INSERT INTO t VALUES(7);")
	out := transaction_test_submit(t, h, m)
	reserved, id_err := durable.next_id(h, 100)
	testing.expect(t, id_err == .None)
	durable.close(h); c.hosts[0] = nil
	before, before_err := os.read_entire_file(c.paths[0], context.allocator)
	defer delete(before)
	testing.expect(t, before_err == nil)
	application := fmt.aprintf("%s/new-application.db", c.dir)
	consensus := fmt.aprintf("%s/new-consensus.db", c.dir)
	defer delete(application)
	defer delete(consensus)
	members := [1]sql.Node_Id{1}
	phase: durable.Migration_Phase
	testing.expect(t, durable.migrate_format4(c.paths[0], application, consensus,
		"test", 1, members[:], phase = &phase) == .None)
	testing.expect_value(t, phase, durable.Migration_Phase.Complete)
	after, after_err := os.read_entire_file(c.paths[0], context.allocator)
	defer delete(after)
	testing.expect(t, after_err == nil && durable.digest(before) == durable.digest(after))
	migrated, err := durable.open(application, "test", 1, members[:], consensus_path = consensus)
	testing.expect(t, err == .None && migrated != nil)
	if migrated == nil do return
	defer durable.close(migrated)
	expect_rows(t, &migrated.engine, "SELECT * FROM t WHERE v=7;", 1)
	again := transaction_test_submit(t, migrated, m)
	testing.expect_value(t, again, out)
	next, next_err := durable.next_id(migrated, 1)
	testing.expect(t, next_err == .None && next > reserved)
	testing.expect(t, durable.migrate_format4(c.paths[0], application, consensus,
		"test", 1, members[:]) == .Storage)
	// The original remains usable by its original format-4 path.
	durable_test_reopen(t, c, 0, 1)
	expect_rows(t, &c.hosts[0].engine, "SELECT * FROM t WHERE v=7;", 1)
}

@(test)
test_migration_replays_chosen_unapplied_and_refuses_incomplete :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	m, _ := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE pending(v);")
	c.hosts[0].fault = .After_Journal_Commit
	_, proposal_err := durable.propose(c.hosts[0], m)
	testing.expect(t, proposal_err == .Storage && c.hosts[0].engine.applied_through == 0)
	durable.close(c.hosts[0]); c.hosts[0] = nil
	application := fmt.aprintf("%s/new-application.db", c.dir)
	consensus := fmt.aprintf("%s/new-consensus.db", c.dir)
	defer delete(application)
	defer delete(consensus)
	members := [1]sql.Node_Id{1}
	phase: durable.Migration_Phase
	testing.expect(t, durable.migrate_format4(c.paths[0], application, consensus,
		"test", 1, members[:], phase = &phase) == .None)
	testing.expect_value(t, phase, durable.Migration_Phase.Complete)
	h, err := durable.open(application, "test", 1, members[:], consensus_path = consensus)
	testing.expect(t, err == .None && h != nil)
	if h == nil do return
	testing.expect(t, h.engine.applied_through == 1)
	expect_rows(t, &h.engine, "SELECT * FROM pending;", 0)
	// Any interrupted staging identity must be refused, even with complete SQL data.
	testing.expect(t, db.exec(h.consensus,
		"UPDATE _sqlodin_journal_meta SET identity='sqlodin-migration-incomplete';"))
	durable.close(h)
	h, err = durable.open(application, "test", 1, members[:], consensus_path = consensus)
	testing.expect(t, h == nil && err == .Storage)
}

@(test)
test_migration_preserves_unchosen_acceptor_vote :: proc(t: ^testing.T) {
	c := durable_test_open(t, 3)
	defer durable_test_close(c)
	value := sql.mutation_make_skip(1, 17)
	ballot := sql.ballot_make(3, 0, 1)
	env := sql.Envelope(sql.Mutation){from = 1, to = 2,
		message = sql.Accept_Message(sql.Mutation){ballot, 1, &value}}
	testing.expect(t, durable.step(c.hosts[1], env) == .None)
	durable.close(c.hosts[1]); c.hosts[1] = nil
	application := fmt.aprintf("%s/new-application.db", c.dir)
	consensus := fmt.aprintf("%s/new-consensus.db", c.dir)
	defer delete(application)
	defer delete(consensus)
	members := [3]sql.Node_Id{1, 2, 3}
	testing.expect(t, durable.migrate_format4(c.paths[1], application, consensus,
		"test", 2, members[:]) == .None)
	h, err := durable.open(application, "test", 2, members[:], consensus_path = consensus)
	testing.expect(t, err == .None && h != nil)
	if h == nil do return
	defer durable.close(h)
	vote, accepted, found := sql.ledger_vote_at(&h.node.ledger, 1)
	testing.expect(t, found && vote == ballot && accepted^ == value && h.engine.applied_through == 0)
	other := sql.mutation_make_skip(1, 29)
	env.message = sql.Accept_Message(sql.Mutation){sql.ballot_make(0, 0, 1), 1, &other}
	testing.expect(t, durable.step(h, env) == .None)
	vote, accepted, found = sql.ledger_vote_at(&h.node.ledger, 1)
	testing.expect(t, found && vote == ballot && accepted^ == value)
}
