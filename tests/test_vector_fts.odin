package tests

import "core:testing"
import sqlodin "../src"
import "../src/sqlite"

@(test)
test_sqlite_fts5 :: proc(t: ^testing.T) {
	e, err := sqlodin.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sqlodin.engine_close(&e)

	ddl := "CREATE VIRTUAL TABLE articles USING fts5(title, content);"
	exec_err := sqlodin.engine_exec(&e, ddl)
	testing.expect(t, exec_err == .None)

	ins1 := "INSERT INTO articles VALUES ('Paxos in Odin', 'Deterministic multi-master " +
		"consensus');"
	ins2 := "INSERT INTO articles VALUES ('Vector Search', 'Dense embeddings with sqlite-vec');"
	sqlodin.engine_exec(&e, ins1)
	sqlodin.engine_exec(&e, ins2)

	// FTS5 MATCH query
	query := "SELECT * FROM articles WHERE articles MATCH '\"consensus\"';"
	rows, read_err := sqlodin.engine_read_snapshot(&e, query)
	testing.expect(t, read_err == .None)
	testing.expect_value(t, rows, 1)

	query2 := "SELECT * FROM articles WHERE articles MATCH '\"embeddings\"';"
	rows2, _ := sqlodin.engine_read_snapshot(&e, query2)
	testing.expect_value(t, rows2, 1)
}

@(test)
test_sqlite_vec_embeddings :: proc(t: ^testing.T) {
	e, err := sqlodin.engine_open(":memory:", 1, memory = true)
	testing.expect(t, err == .None)
	defer sqlodin.engine_close(&e)

	ver := sqlite.vec_version(e.db)
	defer delete(ver)
	testing.expect(t, len(ver) > 0)

	// Create vec0 virtual table for 4-dimensional float embeddings
	vec_ddl := "CREATE VIRTUAL TABLE vec_items USING vec0(embedding float[4]);"
	exec_err := sqlodin.engine_exec(&e, vec_ddl)
	testing.expect(t, exec_err == .None)

	// Insert embeddings
	v1 := "INSERT INTO vec_items (rowid, embedding) VALUES (1, '[0.1, 0.2, 0.3, 0.4]');"
	v2 := "INSERT INTO vec_items (rowid, embedding) VALUES (2, '[0.9, 0.8, 0.7, 0.6]');"
	sqlodin.engine_exec(&e, v1)
	sqlodin.engine_exec(&e, v2)

	// Query nearest neighbor using cosine distance
	search_sql := `SELECT rowid FROM vec_items
		WHERE embedding MATCH '[0.11, 0.21, 0.29, 0.39]'
		ORDER BY distance LIMIT 1;`

	rows, q_err := sqlodin.engine_read_snapshot(&e, search_sql)
	testing.expect(t, q_err == .None)
	testing.expect_value(t, rows, 1)
}
