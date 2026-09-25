package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import snapshot "../src/snapshot"

@(test)
test_sql_ordering_survives_physical_layout_and_cache_changes :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root); defer os.remove_all(root)
	hashes: [2][32]u8
	outcomes: [2][10]sql.Outcome
	for mode in 0..<2 {
		path := fmt.aprintf("%s/order-%d.db", root, mode)
		defer delete(path)
		e, err := sql.engine_open(path, 1)
		testing.expect(t, err == .None)
		defer sql.engine_close(&e)
		testing.expect(t, sql.engine_initialize_outcomes(&e))
		testing.expect(t, sql.engine_install_function_policy(&e) == .None)
		setup := [?]string{
			"CREATE TABLE source(id INTEGER PRIMARY KEY,k INTEGER,v TEXT);" +
			"CREATE INDEX source_k ON source(k);CREATE TABLE selected(id INTEGER PRIMARY KEY,v TEXT);" +
			"CREATE TABLE audit(id INTEGER PRIMARY KEY,v TEXT);" +
			"CREATE TRIGGER log_selected AFTER INSERT ON selected BEGIN " +
			"INSERT INTO audit(v) VALUES(new.v); END;",
			"INSERT INTO source VALUES(9,2,'nine'),(1,1,'one'),(7,1,'seven'),(3,2,'three');",
			"CREATE TABLE churn(id INTEGER PRIMARY KEY,v BLOB);" +
			"INSERT INTO churn SELECT a.id*10+b.id,zeroblob(16000) FROM source a,source b;",
			"DELETE FROM churn;",
		}
		for text, i in setup {
			m, _ := sql.mutation_make_raw_sql(1, 0, text)
			testing.expect(t, sql.engine_apply_outcome(&e, u64(i+1), &m) == .None)
		}
		// Privileged fixture changes representation, not schema/data/planner stats.
		// Neither VACUUM nor connection PRAGMAs are exposed as replicated user SQL.
		if mode == 1 {
			testing.expect(t, sql.engine_exec(&e, "VACUUM;PRAGMA cache_size=8;") == .None)
		}
		work := [?]string{
			"INSERT INTO selected(v) SELECT v FROM source WHERE k=1;",
			"INSERT INTO selected(v) SELECT v FROM source ORDER BY k,id LIMIT 2;",
			"INSERT INTO selected(v) SELECT v FROM source LIMIT 1;",
			"UPDATE selected SET v=(SELECT v FROM source WHERE k=2 LIMIT 1) WHERE id=1;",
			"INSERT INTO selected(v) SELECT min(v) FROM source GROUP BY k;",
			"INSERT INTO selected(v) SELECT a.v||b.v FROM source a JOIN source b ON a.k=b.k;",
			"INSERT INTO selected(v) SELECT v FROM source UNION SELECT v FROM source;",
			"UPDATE source SET v=upper(v) WHERE id IN(SELECT id FROM source ORDER BY k,id LIMIT 2);",
			"DELETE FROM selected WHERE id IN(SELECT id FROM selected ORDER BY v,id LIMIT 2);",
			"INSERT INTO selected(v) SELECT json_array(k,count(*)) FROM source GROUP BY k ORDER BY k;",
		}
		for text, i in work {
			if mode == 1 {
				sql.engine_close(&e)
				e, err = sql.engine_open(path, 1)
				testing.expect(t, err == .None)
				testing.expect(t, sql.engine_install_function_policy(&e) == .None)
				testing.expect(t, sql.engine_exec(&e, "PRAGMA cache_size=8;") == .None)
			}
			m, _ := sql.mutation_make_raw_sql(1, 0, text)
			slot := u64(len(setup)+i+1)
			testing.expect(t, sql.engine_apply_outcome(&e, slot, &m) == .None)
			found: bool
			outcomes[mode][i], found, err = sql.engine_outcome(&e, slot)
			testing.expect(t, found && err == .None && outcomes[mode][i].kind == .Applied)
		}
		sql.engine_close(&e)
		digest_err: snapshot.Image_Error
		hashes[mode], digest_err = snapshot.logical_digest(path, u64(len(setup)+len(work)))
		testing.expect_value(t, digest_err, snapshot.Image_Error.None)
	}
	testing.expect_value(t, outcomes[0], outcomes[1])
	testing.expect_value(t, hashes[0], hashes[1])
}
