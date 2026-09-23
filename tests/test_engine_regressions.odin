package tests

import "core:testing"
import "core:os"
import "core:fmt"
import sqlodin "../src"

expect_rows :: proc(t: ^testing.T, e: ^sqlodin.Engine, query: string, want: int) {
	rows, err := sqlodin.engine_read_snapshot(e, query)
	testing.expect(t, err == .None)
	testing.expect_value(t, rows, want)
}

@(test)
test_sqlite_text_update_and_vector_bindings :: proc(t: ^testing.T) {
	e, err := sqlodin.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sqlodin.engine_close(&e)
	sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, emb BLOB);")
	m, _ := sqlodin.mutation_make_insert(1, 0, 42, "t")
	sqlodin.mutation_add_text(&m, "name", "a\x00b")
	vec := [?]f32{0.1, 0.2, 0.3, 0.4}
	sqlodin.mutation_add_vector(&m, "emb", vec[:])
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) == .None)
	expect_rows(t, &e, "SELECT * FROM t WHERE hex(name)='610062' AND length(emb)=16;", 1)
	u, _ := sqlodin.mutation_make_update(1, 0, 42, "t")
	sqlodin.mutation_add_text(&u, "name", "updated")
	testing.expect(t, sqlodin.engine_apply_slot(&e, 2, &u) == .None)
	expect_rows(t, &e, "SELECT * FROM t WHERE name='updated' AND length(emb)=16;", 1)
	// Repeated statement shapes exercise cached bindings with fresh mutation storage.
	for i in 3..=20 {
		u.primary_key = 42
		testing.expect(t, sqlodin.engine_apply_slot(&e, sqlodin.Slot(i), &u) == .None)
	}
	expect_rows(t, &e, "SELECT * FROM t WHERE name='updated';", 1)
}

@(test)
test_sqlite_failed_raw_sql_rolls_back_and_does_not_advance :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)
	sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY);")
	for sql in ([?]string{
		"INSERT INTO t VALUES (1); INSERT INTO missing VALUES (1);",
		"INSERT INTO t VALUES (1); COMMIT;",
		"INSERT INTO t VALUES (1); UPDATE _sqlodin_state SET applied=99;",
		"ALTER TABLE _sqlodin_state ADD COLUMN unwanted INTEGER;",
		"CREATE TRIGGER corrupt AFTER UPDATE ON _sqlodin_state " +
			"BEGIN UPDATE _sqlodin_state SET applied=99; END;",
	}) {
		m, _ := sqlodin.mutation_make_raw_sql(1, 0, sql)
		testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) != .None)
		testing.expect_value(t, e.applied_through, sqlodin.Slot(0))
		expect_rows(t, &e, "SELECT * FROM t;", 0)
	}
	valid, _ := sqlodin.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES (2);")
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &valid) == .None)
	// Replaying an applied slot is harmless; gaps and zero slots are errors.
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &valid) == .None)
	testing.expect(t, sqlodin.engine_apply_slot(&e, 3, &valid) == .Invalid_Slot)
	testing.expect(t, sqlodin.engine_apply_slot(&e, 0, &valid) == .Invalid_Slot)
	expect_rows(t, &e, "SELECT * FROM t;", 1)
}

@(test)
test_sqlite_delete_and_commit_failures :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)
	sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1);")
	sqlodin.engine_exec(&e,
		"CREATE TRIGGER keep BEFORE DELETE ON t BEGIN SELECT RAISE(ABORT, 'keep'); END;")
	del, _ := sqlodin.mutation_make_delete(1, 0, 1, "t")
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &del) != .None)
	testing.expect_value(t, e.applied_through, sqlodin.Slot(0))
	expect_rows(t, &e, "SELECT * FROM t;", 1)
	sqlodin.engine_exec(&e, "PRAGMA foreign_keys=ON;")
	sqlodin.engine_exec(&e, "CREATE TABLE child (id INTEGER PRIMARY KEY, " +
		"parent INTEGER REFERENCES t(id) DEFERRABLE INITIALLY DEFERRED);")
	m, _ := sqlodin.mutation_make_insert(1, 0, 1, "child")
	sqlodin.mutation_add_int(&m, "parent", 99)
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) != .None)
	testing.expect_value(t, e.applied_through, sqlodin.Slot(0))
	expect_rows(t, &e, "SELECT * FROM child;", 0)
}

@(test)
test_sqlite_batch_is_atomic :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)
	sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER CHECK(v>0));")
	m1, _ := sqlodin.mutation_make_insert(1, 0, 1, "t")
	m2, _ := sqlodin.mutation_make_insert(1, 0, 2, "t")
	sqlodin.mutation_add_int(&m1, "v", 10)
	sqlodin.mutation_add_int(&m2, "v", -1)
	entries := [?]sqlodin.Committed(sqlodin.Mutation){{1, &m1}, {2, &m2}}
	testing.expect(t, sqlodin.engine_apply_batch(&e, entries[:]) != .None)
	expect_rows(t, &e, "SELECT * FROM t;", 0)
	testing.expect_value(t, e.applied_through, sqlodin.Slot(0))
	m2.col_values[0].int_val = 20
	testing.expect(t, sqlodin.engine_apply_batch(&e, entries[:]) == .None)
	expect_rows(t, &e, "SELECT * FROM t;", 2)
	testing.expect_value(t, e.applied_through, sqlodin.Slot(2))
}

@(test)
test_sqlite_read_errors_and_write_rejection :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)
	sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY);")
	_, err := sqlodin.engine_read_snapshot(&e, "INSERT INTO t VALUES (1) RETURNING id;")
	testing.expect(t, err == .Invalid_Mutation)
	_, err = sqlodin.engine_read_snapshot(&e, "SELECT abs(-9223372036854775808);")
	testing.expect(t, err == .Sqlite_Step_Failed)
	expect_rows(t, &e, "SELECT * FROM t;", 0)
}

@(test)
test_sqlite_watermark_survives_reopen :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "sqlodin-watermark-", context.allocator)
	testing.expect(t, dir_err == nil)
	defer delete(dir)
	defer os.remove(dir)
	path := fmt.aprintf("%s/test.db", dir)
	defer delete(path)
	defer os.remove(path)
	e, err := sqlodin.engine_open(path, 1)
	testing.expect(t, err == .None)
	m, _ := sqlodin.mutation_make_raw_sql(1, 0, "CREATE TABLE t (v INTEGER);")
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) == .None)
	sqlodin.engine_close(&e)
	e, err = sqlodin.engine_open(path, 1)
	testing.expect(t, err == .None)
	defer sqlodin.engine_close(&e)
	testing.expect_value(t, e.applied_through, sqlodin.Slot(1))
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) == .None)
}

@(test)
test_structured_vector_mutation_reaches_vec0 :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)
	err := sqlodin.engine_exec(&e,
		"CREATE VIRTUAL TABLE vectors USING vec0(id INTEGER PRIMARY KEY, emb float[4]);")
	testing.expect(t, err == .None)
	m, _ := sqlodin.mutation_make_insert(1, 0, 42, "vectors")
	v := [?]f32{0.1, 0.2, 0.3, 0.4}
	testing.expect(t, sqlodin.mutation_add_vector(&m, "emb", v[:]) == .None)
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) == .None)
	expect_rows(t, &e, "SELECT id FROM vectors WHERE emb MATCH '[0.1,0.2,0.3,0.4]' " +
		"AND k=1 AND id=42;", 1)
}

@(test)
test_sqlite_begin_failure_does_not_commit_host_transaction :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)
	sqlodin.engine_exec(&e, "CREATE TABLE t (id INTEGER PRIMARY KEY); BEGIN; INSERT INTO t VALUES (1);")
	m, _ := sqlodin.mutation_make_insert(1, 0, 2, "t")
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) != .None)
	testing.expect_value(t, e.applied_through, sqlodin.Slot(0))
	sqlodin.engine_exec(&e, "ROLLBACK;")
	expect_rows(t, &e, "SELECT id FROM t;", 0)
}

@(test)
test_statement_cache_distinguishes_shapes_and_evicts :: proc(t: ^testing.T) {
	e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
	defer sqlodin.engine_close(&e)
	slot: sqlodin.Slot
	// More shapes than cache entries; revisit them after eviction.
	for pass in 0..<2 {
		for i in 0..<10 {
			name := fmt.aprintf("t%d", i)
			defer delete(name)
			if pass == 0 {
				sql := fmt.aprintf("CREATE TABLE %s (id INTEGER PRIMARY KEY, a, ab);", name)
				defer delete(sql)
				testing.expect(t, sqlodin.engine_exec(&e, sql) == .None)
			}
			m, _ := sqlodin.mutation_make_insert(1, 0, u64(pass + 1), name)
			sqlodin.mutation_add_int(&m, "a", i64(i))
			sqlodin.mutation_add_text(&m, "ab", "value")
			slot += 1
			testing.expect(t, sqlodin.engine_apply_slot(&e, slot, &m) == .None)
			u, _ := sqlodin.mutation_make_update(1, 0, u64(pass + 1), name)
			// Reverse column order and change types: neither may reuse stale bindings.
			sqlodin.mutation_add_int(&u, "ab", 99)
			sqlodin.mutation_add_text(&u, "a", "changed")
			slot += 1
			testing.expect(t, sqlodin.engine_apply_slot(&e, slot, &u) == .None)
			query := fmt.aprintf("SELECT id FROM %s WHERE a='changed' AND ab=99;", name)
			defer delete(query)
			expect_rows(t, &e, query, pass + 1)
		}
	}
}

@(test)
test_structured_trigger_cannot_change_internal_metadata :: proc(t: ^testing.T) {
	e, err := sqlodin.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sqlodin.engine_close(&e)
	// Even a trigger installed by privileged setup is checked when the DML is prepared.
	sqlodin.engine_exec(&e, "CREATE TABLE t(id INTEGER PRIMARY KEY); " +
		"CREATE TRIGGER corrupt AFTER INSERT ON t BEGIN " +
		"UPDATE _sqlodin_state SET applied=99; END;")
	m, _ := sqlodin.mutation_make_insert(1, 0, 1, "t")
	testing.expect(t, sqlodin.engine_apply_slot(&e, 1, &m) != .None)
	testing.expect_value(t, e.applied_through, sqlodin.Slot(0))
	expect_rows(t, &e, "SELECT * FROM t;", 0)
}

@(test)
test_snapshot_cannot_disable_durability :: proc(t: ^testing.T) {
	e, err := sqlodin.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sqlodin.engine_close(&e)
	for query in ([?]string{"PRAGMA synchronous=OFF", "PRAGMA journal_mode=OFF",
		"PRAGMA writable_schema=ON", "SELECT * FROM _sqlodin_state"}) {
		_, e := sqlodin.engine_read_snapshot(&e, query)
		testing.expect(t, e != .None)
	}
}
