package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import snapshot "../src/snapshot"

@(test)
test_fts_group_and_reference_have_identical_logical_snapshot_state :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root); defer os.remove_all(root)
	hashes: [2][32]u8
	outcomes: [2][32]sql.Outcome
	for mode in 0..<2 {
		path := fmt.aprintf("%s/fts-%d.db", root, mode)
		defer delete(path)
		e, err := sql.engine_open(path, 1)
		testing.expect(t, err == .None)
		defer sql.engine_close(&e)
		testing.expect(t, sql.engine_initialize_outcomes(&e))
		testing.expect(t, sql.engine_install_function_policy(&e) == .None)
		ddl, _ := sql.mutation_make_raw_sql(1, 0, "CREATE VIRTUAL TABLE docs USING fts5(body);" +
			"CREATE TABLE vectors(id INTEGER PRIMARY KEY,embedding BLOB);" +
			"CREATE TABLE audit(id INTEGER,bytes INTEGER);" +
			"CREATE TRIGGER vectors_audit AFTER INSERT ON vectors BEGIN " +
			"INSERT INTO audit VALUES(new.id,length(new.embedding)); END;")
		testing.expect(t, sql.engine_apply_outcome(&e, 1, &ddl) == .None)
		values := make([]sql.Mutation, 32)
		entries := make([]sql.Committed(sql.Mutation), 32)
		defer delete(values); defer delete(entries)
		for &m, i in values {
			request := sql.Request_Id{sequence = 1}
			request.session[0] = u8(i+1)
			text := fmt.tprintf("INSERT INTO docs(rowid,body) VALUES(%d,'durable token')", i+1)
			if i >= 20 && i < 24 {
				text = fmt.tprintf("UPDATE docs SET body='updated token' WHERE rowid=%d", i-19)
			} else if i >= 24 && i < 28 {
				text = fmt.tprintf("DELETE FROM docs WHERE rowid=%d", i-23)
			} else if i >= 28 {
				text = fmt.tprintf("INSERT INTO docs(rowid,body) VALUES(%d,'replacement token')", i-27)
			}
			vector_text := fmt.tprintf("INSERT INTO vectors VALUES(%d,?1)", i+1)
			if i >= 20 && i < 24 {
				vector_text = fmt.tprintf("UPDATE vectors SET embedding=?1 WHERE id=%d", i-19)
			} else if i >= 24 && i < 28 {
				vector_text = fmt.tprintf("DELETE FROM vectors WHERE id=%d", i-23)
			} else if i >= 28 {
				vector_text = fmt.tprintf("INSERT INTO vectors VALUES(%d,?1)", i-27)
			}
			m, _ = sql.mutation_make_transaction(1, request, fmt.tprintf("%s;%s", text, vector_text))
			testing.expect(t, sql.mutation_add_vector(&m, "p", []f32{f32(i), 2, 3}) == .None)
			entries[i] = {slot = u64(i+2), value = &m}
		}
		if mode == 0 {
			testing.expect(t, sql.engine_apply_outcomes(&e, entries[:]) == .None)
		} else {
			for entry in entries {
				testing.expect(t, sql.engine_apply_outcome(&e, entry.slot, entry.value) == .None)
			}
		}
		for &out, i in outcomes[mode] {
			found: bool
			out, found, err = sql.engine_outcome(&e, u64(i+2))
			testing.expect(t, found && err == .None && out.kind == .Applied)
		}
		sql.engine_close(&e)
		digest_err: snapshot.Image_Error
		hashes[mode], digest_err = snapshot.logical_digest(path, 33)
		testing.expect_value(t, digest_err, snapshot.Image_Error.None)
	}
	testing.expect_value(t, outcomes[0], outcomes[1])
	testing.expect_value(t, hashes[0], hashes[1])
}
