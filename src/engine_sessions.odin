package sqlodin

import "core:c"
import "core:crypto/sha2"
import "sqlite"

@(private)
request_hash_word :: proc(ctx: ^sha2.Context_256, word: u64) {
	bytes: [8]u8
	for i in 0..<8 do bytes[i] = u8(word >> uint(8 * i))
	sha2.update(ctx, bytes[:])
}

// Canonical content identity excludes origin-node and inactive array tails.
// Retrying an identical request through another master must use the same hash.
transaction_digest :: proc(m: ^Mutation) -> (hash: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	request_hash_word(&ctx, 3 if m.request.epoch == 0 else 4)
	if m.request.epoch != 0 do request_hash_word(&ctx, m.request.epoch)
	request_hash_word(&ctx, m.read_version)
	request_hash_word(&ctx, u64(m.sql_len))
	sha2.update(&ctx, m.sql_bytes[:m.sql_len])
	request_hash_word(&ctx, u64(m.col_count))
	for &v in m.col_values[:m.col_count] {
		request_hash_word(&ctx, u64(v.kind))
		switch v.kind {
		case .Null:
		case .Integer: request_hash_word(&ctx, u64(v.int_val))
		case .Real: request_hash_word(&ctx, transmute(u64)v.real_val)
		case .Text:
			request_hash_word(&ctx, u64(v.text_len))
			sha2.update(&ctx, v.text_val[:v.text_len])
		case .Vector:
			request_hash_word(&ctx, u64(v.vec_dim))
			for f in m.vec_values[int(v.vec_offset):int(v.vec_offset) + int(v.vec_dim)] {
				request_hash_word(&ctx, u64(transmute(u32)f))
			}
		}
	}
	sha2.final(&ctx, hash[:])
	return
}

@(private)
engine_bind_session :: proc(s: sqlite.Sqlite3_Stmt, request: ^Request_Id) -> bool {
	return sqlite.sqlite3_bind_blob(s, 1, &request.session[0], 16, nil) == sqlite.OK
}

@(private)
engine_request_lookup :: proc(
	e: ^Engine, m: ^Mutation, slot: Slot,
) -> (out: Outcome, execute, record: bool, err: Error) {
	out.slot = slot
	epoch := engine_session_epoch(e) or_return
	if m.request.epoch != epoch {
		out.kind = .Expired
		return out, false, false, .None
	}
	s := engine_prepare(e,
		"SELECT seq,hash,kind,code,changes,slot FROM _sqlodin_sessions WHERE session=?") or_return
	defer sqlite.sqlite3_finalize(s)
	if !engine_bind_session(s, &m.request) do return {}, false, false, .Sqlite_Step_Failed
	rc := sqlite.sqlite3_step(s)
	last: u64
	if rc == sqlite.ROW {
		if sqlite.sqlite3_column_type(s, 0) != sqlite.INTEGER_TYPE ||
		   sqlite.sqlite3_column_int64(s, 0) <= 0 || sqlite.sqlite3_column_bytes(s, 1) != 32 {
			return {}, false, false, .Sqlite_Corrupt
		}
		// Earlier members of an uncommitted application group are logically prior
		// requests too; the durable in-memory watermark advances only at COMMIT.
		stored := engine_decode_outcome(s, 2, slot - 1) or_return
		last = u64(sqlite.sqlite3_column_int64(s, 0))
		if m.request.sequence < last {
			out.kind = .Expired
			return out, false, false, .None
		}
		if m.request.sequence == last {
			hash := transaction_digest(m)
			p := cast([^]u8)sqlite.sqlite3_column_blob(s, 1)
			if sqlite.sqlite3_column_bytes(s, 1) != 32 do return {}, false, false, .Sqlite_Corrupt
			for b, i in hash {
				if b != p[i] {
					out.kind = .Identity_Conflict
					return out, false, false, .None
				}
			}
			return stored, false, false, .None
		}
	} else if rc == sqlite.DONE {
		available := engine_session_available(e) or_return
		if !available {
			out.kind = .Session_Limit
			return out, false, false, .None
		}
	} else {
		return {}, false, false, .Sqlite_Step_Failed
	}
	if m.request.sequence != last + 1 {
		out.kind = .Sequence_Gap
		// Consume this sequence as a durable rejection. Lower requests expire;
		// no later delivery can turn this rejected identity into an execution.
		return out, false, true, .None
	}
	return out, true, true, .None
}

@(private)
engine_session_available :: proc(e: ^Engine) -> (available: bool, err: Error) {
	s := engine_prepare(e, "SELECT count(*) FROM _sqlodin_sessions") or_return
	defer sqlite.sqlite3_finalize(s)
	if sqlite.sqlite3_step(s) != sqlite.ROW do return false, .Sqlite_Step_Failed
	return sqlite.sqlite3_column_int64(s, 0) < MAX_REQUEST_SESSIONS, .None
}

@(private)
engine_record_session :: proc(e: ^Engine, m: ^Mutation, out: Outcome) -> Error {
	s := engine_prepare(e, "INSERT OR REPLACE INTO _sqlodin_sessions VALUES(?,?,?,?,?,?,?)") or_return
	defer sqlite.sqlite3_finalize(s)
	hash := transaction_digest(m)
	if !engine_bind_session(s, &m.request) ||
	   sqlite.sqlite3_bind_int64(s, 2, i64(m.request.sequence)) != sqlite.OK ||
	   sqlite.sqlite3_bind_blob(s, 3, &hash[0], 32, nil) != sqlite.OK {
		return .Sqlite_Step_Failed
	}
	for val, i in ([4]i64{i64(out.kind), i64(out.sqlite_code), out.changes, i64(out.slot)}) {
		if sqlite.sqlite3_bind_int64(s, c.int(i + 4), val) != sqlite.OK do return .Sqlite_Step_Failed
	}
	if sqlite.sqlite3_step(s) != sqlite.DONE do return .Sqlite_Step_Failed
	return .None
}
