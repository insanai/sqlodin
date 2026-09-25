package durable

import snapshot "../snapshot"

import sql ".."
import db "../sqlite"
import paxos "../../deps/paxos-odin/src"

persist_record :: proc(h: ^Host, r: ^Record) -> bool {
	if h.sequence == u64(max(i64)) || !history_record_room(h) do return false
	r.seq, r.previous = h.sequence + 1, h.head
	c := Codec{legacy = r.legacy}
	record_codec(&c, r)
	packed: [PACKED_CAPACITY]u8
	bytes, encoded := pack_record(c.bytes[:c.pos], packed[:])
	if !encoded do return false
	hash := digest(bytes)
	s, ok := prepare(h, "INSERT INTO _sqlodin_journal VALUES(?,?,?,?,?)")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	if db.sqlite3_bind_int64(s, 1, i64(r.seq)) != db.OK ||
	   db.sqlite3_bind_int64(s, 2, i64(r.kind)) != db.OK ||
	   db.sqlite3_bind_int64(s, 3, i64(r.slot)) != db.OK ||
	   !bind_blob(s, 4, bytes) || !bind_blob(s, 5, hash[:]) {
		return false
	}
	if db.sqlite3_step(s) != db.DONE do return false
	h.sequence, h.head = r.seq, hash
	return true
}

persist :: proc(h: ^Host) -> bool {
	writes := sql.effects_writes_slice(&h.effects)
	if len(writes) == 0 do return true
	if !db.begin_tx(journal_db(h)) do return false
	defer db.rollback_tx(journal_db(h))
	for w in writes {
		r, ok := make_record(w)
		if !ok || !persist_record(h, &r) do return false
	}
	through, stage_err := stage_journal_skips(h,
		sql.effects_committed_slice(&h.effects))
	if stage_err != .None do return false
	s, ok := prepare(h, "UPDATE _sqlodin_journal_meta SET seq=?,digest=? WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	if db.sqlite3_bind_int64(s, 1, i64(h.sequence)) != db.OK || !bind_blob(s, 2, h.head[:]) {
		return false
	}
	if db.sqlite3_step(s) != db.DONE || db.sqlite3_changes(journal_db(h)) != 1 do return false
	if h.checkpoint != nil do h.checkpoint(.Before_Journal_Commit)
	if h.fault == .Before_Journal_Commit do return false
	if !db.commit_tx(journal_db(h)) do return false
	h.durable_sequence = h.sequence
	h.engine.applied_through = through
	if h.checkpoint != nil do h.checkpoint(.After_Journal_Commit)
	return h.fault != .After_Journal_Commit
}

// Validate length before decoding; a zero-filled buffer is never accepted as a short record.
decode_row :: proc(s: db.Sqlite3_Stmt, r: ^Record) -> bool {
	bytes, hash := column_blob(s, 3), column_blob(s, 4)
	if len(bytes) < 6 || len(bytes) > PACKED_CAPACITY || len(hash) != 32 do return false
	actual := digest(bytes)
	for b, i in hash do if b != actual[i] do return false
	c := Codec{reading = true}
	size, decoded := unpack_record(bytes, c.bytes[:])
	if !decoded || size < 57 do return false
	// Promise records are unchanged; value records gained the request epoch word.
	if c.bytes[40] == 3 || c.bytes[40] == 4 {
		probe: Codec
		value: sql.Mutation
		mutation_codec(&probe, &value)
		c.legacy = size == 57 + probe.pos - 8
	}
	r.legacy = c.legacy
	record_codec(&c, r)
	if r.kind < 1 || r.kind > 4 || c.pos != size do return false
	if r.seq != u64(db.sqlite3_column_int64(s, 0)) ||
	   r.kind != u8(db.sqlite3_column_int64(s, 1)) ||
	   r.slot != u64(db.sqlite3_column_int64(s, 2)) {
		return false
	}
	if r.kind != 1 && r.slot == 0 do return false
	if r.kind >= 3 && sql.mutation_validate(&r.value) != .None do return false
	return true
}

recover_ledger :: proc(h: ^Host, cancel: ^u32 = nil) -> bool {
	s, ok := prepare(h, "SELECT seq,kind,slot,data,digest FROM _sqlodin_journal ORDER BY seq")
	if !ok do return false
	defer db.sqlite3_finalize(s)
	seq: u64
	head: [32]u8
	for {
		if snapshot.cancelled(cancel) do return false
		rc := db.sqlite3_step(s)
		if rc == db.DONE do break
		if rc != db.ROW do return false
		r: Record
		if !decode_row(s, &r) || r.seq != seq + 1 || r.previous != head do return false
		if paxos.ledger_replay_fold(&h.node.ledger, record_write(&r)) != .None do return false
		seq = r.seq
		copy(head[:], column_blob(s, 4))
	}
	return seq == h.sequence && head == h.head
}

chosen :: proc(h: ^Host, slot: sql.Slot) -> (value: sql.Mutation, found, ok: bool) {
	if h.chosen_stmt == nil {
		s, prepared := prepare(h,
			"SELECT seq,kind,slot,data,digest FROM _sqlodin_journal WHERE kind=4 AND slot=?")
		if !prepared do return {}, false, false
		h.chosen_stmt = s
	}
	s := h.chosen_stmt
	defer db.sqlite3_reset(s)
	if db.sqlite3_bind_int64(s, 1, i64(slot)) != db.OK do return {}, false, false
	for {
		rc := db.sqlite3_step(s)
		if rc == db.DONE do return value, found, true
		if rc != db.ROW do return {}, false, false
		r: Record
		if !decode_row(s, &r) || r.kind != 4 || r.slot != slot do return {}, false, false
		if found && value != r.value do return {}, false, false
		value, found = r.value, true
	}
}

recover_application :: proc(h: ^Host, cancel: ^u32 = nil) -> bool {
	// Verify every applied slot has durable decision evidence, then finish the unapplied suffix.
	for slot := max(h.generation_base.key.prefix, h.genesis.prefix) + 1; ; slot += 1 {
		if snapshot.cancelled(cancel) do return false
		value, found, ok := chosen(h, slot)
		if !ok do return false
		if !found do return slot > h.engine.applied_through
		if slot > h.engine.applied_through {
			if sql.engine_apply_outcome(&h.engine, slot, &value) != .None do return false
		} else {
			_, complete, err := sql.engine_outcome(&h.engine, slot)
			if err != .None || !complete do return false
		}
		if !snapshot_observe_seal(h, slot, &value) do return false
	}
}
