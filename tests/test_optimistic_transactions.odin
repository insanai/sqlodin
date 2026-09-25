package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"

@(test)
test_optimistic_commit_conflict_retry_and_reopen :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	setup, _ := sql.mutation_make_transaction(1, {{0 = 90}, 1, 0},
		"CREATE TABLE optimistic(id INTEGER PRIMARY KEY, value INTEGER);" +
		"INSERT INTO optimistic VALUES(1,10);")
	slot, err := durable.propose(c.hosts[0], setup)
	testing.expect(t, err == .None && durable.acknowledged(c.hosts[0], slot, &setup))
	version, read_err := sql.engine_read_version(&c.hosts[0].engine)
	testing.expect(t, read_err == .None)
	write, _ := sql.mutation_make_transaction(1, {{0 = 91}, 1, 0},
		"UPDATE optimistic SET value=11 WHERE id=1;")
	write.read_version = version
	slot, err = durable.propose(c.hosts[0], write)
	testing.expect(t, err == .None && durable.acknowledged(c.hosts[0], slot, &write))
	committed_version, _ := sql.engine_read_version(&c.hosts[0].engine)
	conflict := write
	conflict.request.session[0] = 92
	conflict_slot, propose_err := durable.propose(c.hosts[0], conflict)
	testing.expect(t, propose_err == .None)
	out, done, outcome_err := durable.outcome(c.hosts[0], conflict_slot, &conflict)
	testing.expect(t, outcome_err == .None && done && out.kind == .Conflict)
	durable_test_reopen(t, c, 0, 1)
	recovered_version, version_err := sql.engine_read_version(&c.hosts[0].engine)
	testing.expect(t, version_err == .None && recovered_version == committed_version)
	// A retry must return its original success even though the version changed.
	slot, err = durable.propose(c.hosts[0], write)
	testing.expect(t, err == .None && durable.acknowledged(c.hosts[0], slot, &write))
	altered := write
	altered.read_version += 1
	slot, err = durable.propose(c.hosts[0], altered)
	out, done, outcome_err = durable.outcome(c.hosts[0], slot, &altered)
	testing.expect(t, err == .None && outcome_err == .None && done && out.kind == .Identity_Conflict)
}

@(test)
test_application_group_validates_each_read_version :: proc(t: ^testing.T) {
	e, _ := sql.engine_open(":memory:", 1, memory = true)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	setup, _ := sql.mutation_make_transaction(1, {{0 = 93}, 1, 0}, "CREATE TABLE optimistic(n);")
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &setup) == .None)
	version, _ := sql.engine_read_version(&e)
	first, _ := sql.mutation_make_transaction(1, {{0 = 94}, 1, 0}, "INSERT INTO optimistic VALUES(1);")
	second := first
	first.read_version, second.read_version = version, version
	second.request.session[0] = 95
	entries := [?]sql.Committed(sql.Mutation){{2, &first}, {3, &second}}
	testing.expect(t, sql.engine_apply_outcomes(&e, entries[:]) == .None)
	out, found, err := sql.engine_outcome(&e, 3)
	testing.expect(t, err == .None && found && out.kind == .Conflict)
	rows, read_err := sql.engine_read_snapshot(&e, "SELECT n FROM optimistic")
	testing.expect(t, read_err == .None && rows == 1)
}

@(test)
test_preview_rolls_back_and_preserves_read_version :: proc(t: ^testing.T) {
	e, _ := sql.engine_open(":memory:", 1, memory = true)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	setup, _ := sql.mutation_make_transaction(1, {{0 = 96}, 1, 0},
		"CREATE TABLE optimistic(id INTEGER PRIMARY KEY,n);")
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &setup) == .None)
	version, _ := sql.engine_read_version(&e)
	write, _ := sql.mutation_make_transaction(1, {{0 = 97}, 1, 0}, "INSERT INTO optimistic(n) VALUES(42);")
	write.read_version = version
	query, _ := sql.mutation_make_transaction(1, {{0 = 98}, 1, 0}, "SELECT n FROM optimistic;")
	r, out, changes, id, err := sql.engine_preview(&e, &write, &query)
	defer sql.query_result_free(&r)
	testing.expect(t, err == .None && out.kind == .Applied && changes == 1 && id == 1)
	testing.expect(t, len(r.rows) == 1 && r.rows[0][0].integer == 42)
	after, _ := sql.engine_read_version(&e)
	rows, _ := sql.engine_read_snapshot(&e, "SELECT n FROM optimistic;")
	testing.expect(t, version == after && rows == 0)
}
