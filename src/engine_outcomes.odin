package sqlodin

import "core:c"
import "sqlite"

engine_initialize_outcomes :: proc(e: ^Engine) -> bool {
	return sqlite.exec(e.db,
		"CREATE TABLE _sqlodin_outcomes(slot INTEGER PRIMARY KEY CHECK(slot>0)," +
		"kind INTEGER NOT NULL CHECK(kind BETWEEN 0 AND 8),code INTEGER NOT NULL," +
		"changes INTEGER NOT NULL CHECK(changes>=0)," +
		"origin_slot INTEGER NOT NULL CHECK(origin_slot>0 AND origin_slot<=slot));" +
		"CREATE TABLE _sqlodin_sessions(session BLOB PRIMARY KEY CHECK(length(session)=16)," +
		"seq INTEGER NOT NULL CHECK(seq>0),hash BLOB NOT NULL CHECK(length(hash)=32)," +
		"kind INTEGER NOT NULL CHECK(kind IN (0,1,2,3,7,8)),code INTEGER NOT NULL," +
		"changes INTEGER NOT NULL CHECK(changes>=0),slot INTEGER NOT NULL CHECK(slot>0)) WITHOUT ROWID;" +
		"CREATE TABLE _sqlodin_tx_revision(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL);" +
		"INSERT INTO _sqlodin_tx_revision VALUES(1,1);")
}

// The reference execution commits each request separately. Deferred constraints
// and ROLLBACK conflict actions cannot roll back another request's outcome.
engine_apply_outcomes :: proc(e: ^Engine, entries: []Committed(Mutation)) -> Error {
	through := e.applied_through
	for entry in entries {
		if entry.slot == 0 do return .Invalid_Slot
		if entry.slot <= e.applied_through do continue
		if through == max(Slot) || entry.slot != through + 1 do return .Invalid_Slot
		mutation_validate(entry.value) or_return
		through = entry.slot
	}
	for first := 0; first < len(entries); {
		if entries[first].slot <= e.applied_through { first += 1; continue }
		last := min(first + MAX_APPLICATION_GROUP, len(entries))
		group := entries[first:last]
		grouped := false
		when APPLICATION_GROUP_COMMIT {
			if len(group) > 1 do grouped = engine_apply_group(e, group) or_return
		}
		if !grouped {
			for entry in group do engine_apply_outcome(e, entry.slot, entry.value) or_return
		}
		first = last
	}
	return .None
}

engine_apply_outcome :: proc(e: ^Engine, slot: Slot, m: ^Mutation) -> Error {
	if slot == 0 || slot > u64(max(i64)) do return .Invalid_Slot
	if slot <= e.applied_through do return .None
	if slot != e.applied_through + 1 do return .Invalid_Slot
	mutation_validate(m) or_return
	out := Outcome{slot = slot}
	execute, record_session := true, false
	if m.kind == .Transaction {
		out, execute, record_session = engine_request_lookup(e, m, slot) or_return
	}
	if !sqlite.begin_tx(e.db) do return .Sqlite_Exec_Failed
	defer if sqlite.sqlite3_get_autocommit(e.db) == 0 do sqlite.rollback_tx(e.db)
	if execute {
		err := engine_run_outcome(e, m, &out)
		if err != .None do return err
		if out.kind != .Applied {
			if sqlite.sqlite3_get_autocommit(e.db) == 0 && !sqlite.rollback_tx(e.db) {
				return .Sqlite_Exec_Failed
			}
			if !sqlite.begin_tx(e.db) do return .Sqlite_Exec_Failed
		}
	}
	engine_record_outcome(e, slot, out, m, record_session) or_return
	if e.application_before_commit != nil do e.application_before_commit()
	if !sqlite.commit_tx(e.db) {
		// A deferred foreign key can reject at COMMIT. Roll back SQL and metadata,
		// then durably record the rejection in a fresh transaction.
		code := sqlite.sqlite3_extended_errcode(e.db)
		if !engine_expected_constraint(code) do return .Sqlite_Exec_Failed
		if !sqlite.rollback_tx(e.db) || !sqlite.begin_tx(e.db) do return .Sqlite_Exec_Failed
		out = Outcome{kind = .Constraint, sqlite_code = i32(code), slot = slot}
		engine_record_outcome(e, slot, out, m, record_session) or_return
		if !sqlite.commit_tx(e.db) do return .Sqlite_Exec_Failed
	}
	e.applied_through = slot
	return .None
}

@(private)
engine_run_outcome :: proc(e: ^Engine, m: ^Mutation, out: ^Outcome) -> Error {
	if m.kind == .Transaction && m.read_version != 0 {
		version := engine_read_version(e) or_return
		if version != m.read_version { out.kind = .Conflict; return .None }
	}
	before := sqlite.sqlite3_total_changes64(e.db)
	e.last_sqlite_code = sqlite.OK
	e.last_expression_error = false
	e.authorization.restricted, e.authorization.deterministic = true, true
	e.authorization.denied = false
	err := engine_execute_mutation(e, m)
	e.authorization.restricted, e.authorization.deterministic = false, false
	if err == .None && !e.authorization.denied {
		if sqlite.sqlite3_get_autocommit(e.db) != 0 do return .Sqlite_Exec_Failed
		out.changes = sqlite.sqlite3_total_changes64(e.db) - before
		return .None
	}
	if e.authorization.denied && (err == .None || err == .Invalid_Mutation ||
	   e.last_sqlite_code == sqlite.ERROR || e.last_sqlite_code == sqlite.AUTH ||
	   engine_expected_constraint(e.last_sqlite_code)) {
		out.kind = .Policy
	} else if engine_expected_constraint(e.last_sqlite_code) {
		out.kind = .Constraint
		out.sqlite_code = i32(e.last_sqlite_code)
	} else if (err == .Sqlite_Prepare_Failed && e.last_sqlite_code == sqlite.ERROR) ||
	   (err == .Sqlite_Step_Failed && e.last_expression_error) ||
	   e.last_sqlite_code == sqlite.MISMATCH || e.last_sqlite_code == sqlite.TOOBIG {
		// Parse/name-resolution, audited expressions, datatype and fixed-length
		// limits reject the request. Unknown failures and storage errors halt.
		out.kind = .Invalid_SQL
	} else {
		return err
	}
	return .None
}

@(private)
engine_expected_constraint :: proc(code: c.int) -> bool {
	// Policy 5 admits built-in FTS5, which reports duplicate rowids as the
	// primary CONSTRAINT code. Other virtual modules remain policy-rejected;
	// unknown extended constraints and storage errors still halt application.
	for sub in ([?]int{0, 1, 3, 5, 6, 7, 8, 10, 12}) {
		if code == (sqlite.CONSTRAINT | c.int(sub << 8)) do return true
	}
	return false
}

@(private)
engine_record_outcome :: proc(
	e: ^Engine, slot: Slot, out: Outcome, m: ^Mutation, record_session: bool,
) -> Error {
	if m.kind != .Skip && out.kind == .Applied && out.slot == slot {
		engine_advance_version(e, slot) or_return
	}
	s := engine_prepare(e, "INSERT INTO _sqlodin_outcomes VALUES(?,?,?,?,?)") or_return
	defer sqlite.sqlite3_finalize(s)
	for val, i in ([5]i64{i64(slot), i64(out.kind), i64(out.sqlite_code), out.changes, i64(out.slot)}) {
		if sqlite.sqlite3_bind_int64(s, c.int(i + 1), val) != sqlite.OK do return .Sqlite_Step_Failed
	}
	if sqlite.sqlite3_step(s) != sqlite.DONE do return .Sqlite_Step_Failed
	if record_session do engine_record_session(e, m, out) or_return
	w := e.watermark_stmt
	defer sqlite.sqlite3_reset(w)
	if sqlite.sqlite3_bind_int64(w, 1, i64(slot)) != sqlite.OK ||
	   sqlite.sqlite3_step(w) != sqlite.DONE {
		return .Sqlite_Step_Failed
	}
	return .None
}

// A decided rejection is a completed request, but not a successful write.
engine_outcome :: proc(e: ^Engine, slot: Slot) -> (out: Outcome, found: bool, err: Error) {
	s := engine_prepare(e,
		"SELECT kind,code,changes,origin_slot FROM _sqlodin_outcomes WHERE slot=?") or_return
	defer sqlite.sqlite3_finalize(s)
	if sqlite.sqlite3_bind_int64(s, 1, i64(slot)) != sqlite.OK do return {}, false, .Sqlite_Step_Failed
	rc := sqlite.sqlite3_step(s)
	if rc == sqlite.DONE do return {}, false, .None
	if rc != sqlite.ROW do return {}, false, .Sqlite_Step_Failed
	out = engine_decode_outcome(s, 0, slot) or_return
	return out, true, .None
}

@(private)
engine_decode_outcome :: proc(s: sqlite.Sqlite3_Stmt, first: c.int, limit: Slot) -> (Outcome, Error) {
	values: [4]i64
	for &v, i in values {
		col := first + c.int(i)
		if sqlite.sqlite3_column_type(s, col) != sqlite.INTEGER_TYPE do return {}, .Sqlite_Corrupt
		v = sqlite.sqlite3_column_int64(s, col)
	}
	if values[0] < 0 || values[0] > i64(Transaction_Outcome.Conflict) || values[1] < 0 ||
	   values[1] > i64(max(i32)) || values[2] < 0 || values[3] <= 0 || u64(values[3]) > limit {
		return {}, .Sqlite_Corrupt
	}
	out := Outcome{Transaction_Outcome(values[0]), i32(values[1]), values[2], Slot(values[3])}
	if (out.kind != .Applied && out.changes != 0) ||
	   (out.kind == .Constraint && !engine_expected_constraint(c.int(out.sqlite_code))) ||
	   (out.kind != .Constraint && out.sqlite_code != 0) {
		return {}, .Sqlite_Corrupt
	}
	return out, .None
}
