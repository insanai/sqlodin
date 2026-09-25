package durable

import sql ".."
import db "../sqlite"
import paxos "../../deps/paxos-odin/src"

// Work bounds apply independently to journal replay and application replay.
// The owner calls this between normal service turns; no read transaction on the
// live journal survives a call, so it does not pin the source WAL indefinitely.
// One replayed SQL transaction may expand a small journal record into substantial
// disk work. Yield to client/peer service after each transaction, rather than
// multiplying that unavoidable call cost by a batch of thirty-two.
@(private)
generation_copy_delta :: proc(source: ^Host, w: ^Generation_Work) -> bool {
	h := w.next
	stmt, ok := prepare(source,
		"SELECT seq,kind,slot,data,digest FROM _sqlodin_journal WHERE seq>? ORDER BY seq LIMIT 128")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_bind_int64(stmt, 1, i64(w.cursor)) != db.OK || !db.begin_tx(h.consensus) do return false
	defer db.rollback_tx(h.consensus)
	bytes := 0
	for {
		rc := db.sqlite3_step(stmt)
		if rc == db.DONE do break
		if rc != db.ROW do return false
		size := len(column_blob(stmt, 3))
		if bytes > 0 && bytes+size > 1024*1024 do break
		bytes += size
		r: Record
		if !decode_row(stmt, &r) || r.seq != w.cursor+1 || r.previous != w.head do return false
		w.cursor = r.seq
		copy(w.head[:], column_blob(stmt, 4))
		if r.kind != 1 && r.slot <= h.generation_base.key.prefix do continue
		if !persist_record(h, &r) ||
			paxos.ledger_replay_fold(&h.node.ledger, record_write(&r)) != .None { return false }
	}
	if !commit_group_journal(h) do return false
	slot := h.engine.applied_through+1
	value, found, valid := chosen(h, slot)
	if !valid do return false
	if !found do return true
	return sql.engine_apply_outcome(&h.engine, slot, &value) == .None &&
		snapshot_observe_seal(h, slot, &value)
}

@(private)
generation_finalize_delta :: proc(source: ^Host, w: ^Generation_Work) -> bool {
	h := w.next
	if source.sequence != source.durable_sequence ||
		h.node.ledger.promised != source.node.ledger.promised ||
		!generation_publish_identity(h, source, w.cluster, nil) { return false }
	ledger := new(type_of(h.node.ledger))
	ledger^ = h.node.ledger
	defer free(ledger)
	noop := sql.mutation_make_skip(0, 0)
	return sql.node_restore(&h.node, source.node.id, source.node.membership, ledger^, noop,
		h.engine.applied_through) == .None
}
