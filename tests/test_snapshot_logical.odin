package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import snapshot "../src/snapshot"

@(test)
test_snapshot_logical_digest_enforces_work_and_scratch_budgets :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	path := fmt.aprintf("%s/application.db", dir)
	defer delete(path)
	e, open_err := sql.engine_open(path, 1)
	testing.expect(t, open_err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_exec(&e,
		"CREATE TABLE entries(id INTEGER PRIMARY KEY,value TEXT);" +
		"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<2048) " +
		"INSERT INTO entries SELECT i,'value' FROM n;") == .None)
	skip := sql.mutation_make_skip(0, 0)
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &skip) == .None)
	limits := snapshot.DEFAULT_LOGICAL_LIMITS
	limits.scratch_bytes = 3*4096 // schema + table root + index root; no room to grow
	_, err := snapshot.logical_digest(path, 1, limits)
	testing.expect_value(t, err, snapshot.Image_Error.Limit)
	limits = snapshot.DEFAULT_LOGICAL_LIMITS
	limits.instructions = 1000
	_, err = snapshot.logical_digest(path, 1, limits)
	testing.expect_value(t, err, snapshot.Image_Error.Limit)
	// A failed worker must release its handles and leave its input intact.
	_, err = snapshot.logical_digest(path, 1)
	testing.expect_value(t, err, snapshot.Image_Error.None)
}

@(test)
test_snapshot_logical_digest_ignores_page_layout_and_preserves_types :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	paths: [2]string
	engines: [2]sql.Engine
	defer for i in 0..<2 { sql.engine_close(&engines[i]); delete(paths[i]) }
	hashes: [2][32]u8
	for i in 0..<2 {
		paths[i] = fmt.aprintf("%s/application-%d.db", dir, i)
		engine, err := sql.engine_open(paths[i], 1)
		testing.expect(t, err == .None)
		engines[i] = engine
		e := &engines[i]
		testing.expect(t, sql.engine_initialize_outcomes(e))
		testing.expect(t, sql.engine_exec(e, "CREATE TABLE data(id INTEGER PRIMARY KEY,v);") == .None)
		order := "(1,1),(2,'1'),(3,x'31'),(4,NULL),(5,1.0)" if i == 0 else
			"(5,1.0),(4,NULL),(3,x'31'),(2,'1'),(1,1)"
		statement := fmt.aprintf("INSERT INTO data VALUES %s;", order)
		testing.expect(t, sql.engine_exec(e, statement) == .None)
		delete(statement)
		if i == 1 do testing.expect(t, sql.engine_exec(e, "VACUUM;") == .None)
		skip := sql.mutation_make_skip(0, 0)
		testing.expect(t, sql.engine_apply_outcome(e, 1, &skip) == .None)
		hash, hash_err := snapshot.logical_digest(paths[i], 1)
		testing.expect_value(t, hash_err, snapshot.Image_Error.None)
		hashes[i] = hash
	}
	testing.expect(t, hashes[0] == hashes[1] && hashes[0] != [32]u8{})
	for statement in ([5]string{
		"UPDATE data SET v='1' WHERE id=1;", // same display, different storage type
		"UPDATE data SET id=6 WHERE id=2;", // row identity
		"UPDATE _sqlodin_tx_revision SET version=2;", // transaction conflict fence
		"CREATE INDEX new_index ON data(v);", // schema
		"INSERT INTO data VALUES(7,x'3100');", // embedded zero in blob
	}) {
		testing.expect(t, sql.engine_exec(&engines[1], statement) == .None)
		hash, err := snapshot.logical_digest(paths[1], 1)
		testing.expect(t, err == .None && hash != hashes[1])
		hashes[1] = hash
	}
	limits := snapshot.DEFAULT_LOGICAL_LIMITS
	limits.rows = 1
	_, err := snapshot.logical_digest(paths[0], 1, limits)
	testing.expect(t, err == .Limit)
}

@(test)
test_snapshot_logical_digest_covers_extensions_and_request_state :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	path := fmt.aprintf("%s/application.db", dir)
	defer delete(path)
	e, open_err := sql.engine_open(path, 1)
	testing.expect(t, open_err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_exec(&e,
		"CREATE VIRTUAL TABLE search USING fts5(body); INSERT INTO search VALUES('first');" +
		"CREATE VIRTUAL TABLE vectors USING vec0(embedding float[2]);" +
		"INSERT INTO vectors(rowid,embedding) VALUES(1,'[1,2]');" +
		"CREATE TABLE ordered(k TEXT PRIMARY KEY,v) WITHOUT ROWID; INSERT INTO ordered VALUES('a',1);" +
		"CREATE TABLE \"quote\"\"table\"(v); INSERT INTO \"quote\"\"table\" VALUES(5);") == .None)
	skip := sql.mutation_make_skip(0, 0)
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &skip) == .None)
	previous, err := snapshot.logical_digest(path, 1)
	testing.expect_value(t, err, snapshot.Image_Error.None)
	for statement in ([4]string{
		"INSERT INTO search VALUES('second');",
		"UPDATE vectors SET embedding='[3,4]' WHERE rowid=1;",
		"UPDATE ordered SET v=2;",
		"INSERT INTO _sqlodin_sessions VALUES(zeroblob(16),1,zeroblob(32),0,0,0,1);",
	}) {
		testing.expect(t, sql.engine_exec(&e, statement) == .None)
		hash, hash_err := snapshot.logical_digest(path, 1)
		testing.expect_value(t, hash_err, snapshot.Image_Error.None)
		testing.expect(t, hash != previous)
		previous = hash
	}
	// All hidden rowid aliases shadowed: refuse instead of losing row identity.
	testing.expect(t, sql.engine_exec(&e, "CREATE TABLE ambiguous(rowid,_rowid_,oid);") == .None)
	_, err = snapshot.logical_digest(path, 1)
	testing.expect(t, err == .Invalid_Source)
}
