package snapshot

import "core:c"
import "core:crypto/sha2"
import "core:fmt"
import "core:strings"
import db "../sqlite"

@(private)
logical_word :: proc(ctx: ^sha2.Context_256, word: u64) {
	bytes: [8]u8
	for i in 0..<8 do bytes[i] = u8(word >> uint(8*i))
	sha2.update(ctx, bytes[:])
}

@(private)
logical_bytes :: proc(ctx: ^sha2.Context_256, bytes: string) {
	logical_word(ctx, u64(len(bytes)))
	sha2.update(ctx, transmute([]u8)bytes)
}

@(private)
logical_value :: proc(ctx: ^sha2.Context_256, stmt: db.Sqlite3_Stmt, column: c.int) -> bool {
	kind := db.sqlite3_column_type(stmt, column)
	logical_word(ctx, u64(kind))
	switch kind {
	case db.NULL_TYPE:
	case db.INTEGER_TYPE: logical_word(ctx, u64(db.sqlite3_column_int64(stmt, column)))
	case db.FLOAT_TYPE: logical_word(ctx, transmute(u64)f64(db.sqlite3_column_double(stmt, column)))
	case db.TEXT_TYPE, db.BLOB_TYPE:
		data := db.sqlite3_column_blob(stmt, column)
		length := db.sqlite3_column_bytes(stmt, column)
		if length < 0 || length > 1024*1024 || length > 0 && data == nil do return false
		logical_word(ctx, u64(length))
		if length > 0 do sha2.update(ctx, (cast([^]u8)data)[:int(length)])
	case: return false
	}
	return true
}

@(private)
logical_tables :: proc(
	database, scratch: db.Sqlite3, ctx: ^sha2.Context_256, max_rows: u64, budget: ^Verify_Budget,
) -> bool {
	stmt, ok := logical_prepare(database,
		"SELECT name,wr FROM pragma_table_list WHERE schema='main' " +
		"AND type IN ('table','shadow','virtual') " +
		"AND name!='sqlite_schema' ORDER BY name COLLATE BINARY")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	total: u64
	for {
		rc := db.sqlite3_step(stmt)
		if rc == db.DONE do return true
		if rc != db.ROW do return false
		name := string(db.sqlite3_column_text(stmt, 0))
		if len(name) > 4096 do return false
		logical_bytes(ctx, name)
		// Per-slot outcomes are a retireable host cache. Request deduplication
		// lives in _sqlodin_sessions, which remains fully hashed. Different
		// local generation floors must not split a quorum's logical image key.
		if name == "_sqlodin_outcomes" { logical_bytes(ctx, "retired-at-image-prefix"); continue }
		without_rowid := db.sqlite3_column_int64(stmt, 1) != 0
		query, valid := logical_table_query(database, name, without_rowid)
		if !valid do return false
		good := logical_table_rows(database, scratch, query, ctx, &total, max_rows, budget)
		delete(query)
		if !good do return false
	}
}

@(private)
logical_table_query :: proc(database: db.Sqlite3, name: string, without_rowid: bool) -> (string, bool) {
	// quote() is for string values; identifiers require doubled double quotes.
	quoted, allocated := strings.replace_all(name, "\"", "\"\"")
	defer if allocated do delete(quoted)
	if without_rowid do return fmt.aprintf("SELECT * FROM \"%s\"", quoted), true
	stmt, ok := logical_prepare(database, "SELECT lower(name) FROM pragma_table_xinfo(?)")
	if !ok do return "", false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_bind_text(stmt, 1, cstring(raw_data(name)), c.int(len(name)), nil) != db.OK {
		return "", false
	}
	aliases := [3]string{"rowid", "_rowid_", "oid"}
	shadowed: [3]bool
	for {
		rc := db.sqlite3_step(stmt)
		if rc == db.DONE do break
		if rc != db.ROW do return "", false
		column := string(db.sqlite3_column_text(stmt, 0))
		for alias, i in aliases do if column == alias { shadowed[i] = true }
	}
	for alias, i in aliases {
		if !shadowed[i] do return fmt.aprintf("SELECT %s,* FROM \"%s\"", alias, quoted), true
	}
	return "", false // Hidden rowid cannot be inspected safely when every alias is shadowed.
}

@(private)
logical_table_rows :: proc(
	database, scratch: db.Sqlite3, query: string, ctx: ^sha2.Context_256,
	total: ^u64, max_rows: u64, budget: ^Verify_Budget,
) -> bool {
	if !db.exec(scratch, "DELETE FROM hashes; BEGIN;") do return false
	defer db.rollback_tx(scratch)
	rows, ok := logical_prepare(database, query)
	if !ok do return false
	defer db.sqlite3_finalize(rows)
	insert, prepared := logical_prepare(scratch, "INSERT INTO hashes VALUES(?)")
	if !prepared do return false
	defer db.sqlite3_finalize(insert)
	columns := db.sqlite3_column_count(rows)
	logical_word(ctx, u64(columns))
	count: u64
	for {
		if !verify_budget_active(budget) do return false
		rc := db.sqlite3_step(rows)
		if rc == db.DONE do break
		if rc != db.ROW do return false
		if total^ >= max_rows { budget.error = .Limit; return false }
		total^ += 1
		count += 1
		row: sha2.Context_256
		sha2.init_256(&row)
		logical_word(&row, u64(columns))
		for column: c.int = 0; column < columns; column += 1 {
			if !logical_value(&row, rows, column) do return false
		}
		hash: [32]u8
		sha2.final(&row, hash[:])
		if db.sqlite3_bind_blob(insert, 1, raw_data(hash[:]), 32, nil) != db.OK do return false
		rc = db.sqlite3_step(insert)
		db.sqlite3_reset(insert)
		if rc != db.DONE {
			budget.error = logical_error(budget, .Limit if rc == db.FULL else .Storage)
			return false
		}
	}
	if !db.commit_tx(scratch) do return false
	logical_word(ctx, count)
	sorted, sorted_ok := logical_prepare(scratch, "SELECT value FROM hashes ORDER BY value")
	if !sorted_ok do return false
	defer db.sqlite3_finalize(sorted)
	for {
		rc := db.sqlite3_step(sorted)
		if rc == db.DONE do return true
		if rc != db.ROW do return false
		if !logical_value(ctx, sorted, 0) do return false
	}
}
