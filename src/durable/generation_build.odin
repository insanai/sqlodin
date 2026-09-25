package durable

import "core:c"
import "core:strings"
import "core:time"
import sql ".."
import db "../sqlite"
import snapshot "../snapshot"

// Build a replacement in a private directory, retaining the source unchanged.
// The serialized owner must quiesce the host for this bounded maintenance call.
// Publication is separate: these paths must never be used until this returns
// success. Copy only application state from the certified image; promises, votes,
// reserved IDs and the chosen suffix always come from this local acceptor.
build_generation :: proc(
	source: ^Host, image, application, consensus, cluster: string,
	candidate: snapshot.Candidate, received: ^Generation_Seal = nil,
	max_bytes: u64 = 128*1024*1024*1024, seconds: u32 = DEFAULT_MAINTENANCE_SECONDS,
	checkpoint: proc(Generation_Phase) = nil,
	cancel: ^u32 = nil,
) -> Error {
	if source == nil || source.poisoned || source.consensus == nil || seconds == 0 ||
		seconds > 3600 ||
		source.sequence != source.durable_sequence { return .Invalid }
	certificate, seal_slot := source.snapshot_sealed, source.snapshot_seal_slot
	if received != nil {
		if !generation_seal_valid(source, received) do return .Invalid
		certificate, seal_slot = received.certificate, received.slot
	}
	if certificate.key.prefix <= source.generation_base.key.prefix ||
		received == nil && certificate.key.prefix > source.engine.applied_through { return .Invalid }
	limits := snapshot.DEFAULT_LOGICAL_LIMITS
	limits.cancel = cancel
	if snapshot.candidate_check(image, candidate, certificate.key, limits) != .None do return .Storage
	if checkpoint != nil do checkpoint(.Image_Checked)
	started := time.tick_now()
	h := new(Host)
	h.lock, h.consensus_lock = -1, -1
	history_attach(h, source)
	h.genesis, h.genesis_hash = source.genesis, source.genesis_hash
	defer close(h)
	h.configuration, h.node.membership = source.configuration, source.node.membership
	locked: bool
	h.lock, locked = lock_database(application, true)
	if !locked || !open_consensus(h, consensus, true) do return .Storage
	if !generation_copy_image(image, application, max_bytes, started, seconds, checkpoint, cancel) {
		return .Storage
	}
	if checkpoint != nil do checkpoint(.Application_Copied)
	err: sql.Error
	h.engine, err = sql.engine_open(application, source.node.id)
	if err != .None do return .Storage
	maintenance_handlers(h, cancel)
	defer maintenance_handlers(h, nil)
	if !check_storage(h) ||
		!application_identity(h, cluster, sql.membership_slice(&h.node.membership), false) ||
		!initialize(h, "sqlodin-generation-incomplete") { return .Storage }
	if !generation_trim_outcomes(h, checkpoint) do return .Storage
	if !generation_copy_suffix(source, h, certificate.key.prefix, started, seconds, checkpoint, cancel) {
		return .Storage
	}
	if checkpoint != nil do checkpoint(.Suffix_Copied)
	if received != nil && !generation_record_seal(h, received) do return .Storage
	if !store_generation_base(h, certificate, seal_slot, candidate, image, source.store_current) {
		return .Storage
	}
	if checkpoint != nil do checkpoint(.Base_Written)
	if sql.engine_install_limits(&h.engine) != .None ||
		sql.engine_install_function_policy(&h.engine) != .None || !recover_measured(h, cancel) ||
		h.engine.applied_through < source.engine.applied_through { return .Storage }
	if checkpoint != nil do checkpoint(.Recovered)
	if !generation_publish_identity(h, source, cluster, checkpoint) do return .Storage
	if checkpoint != nil do checkpoint(.Before_Directory_Sync)
	if !sync_directory(application) || !sync_directory(consensus) do return .Storage
	if checkpoint != nil do checkpoint(.Ready)
	if snapshot.cancelled(cancel) do return .Storage
	return .None
}

@(private)
generation_copy_image :: proc(
	image, application: string, max_bytes: u64, started: time.Tick, seconds: u32,
	checkpoint: proc(Generation_Phase), cancel: ^u32,
) -> bool {
	name := strings.clone_to_cstring(image)
	defer delete(name)
	input: db.Sqlite3
	if db.sqlite3_open_v2(name, &input, db.OPEN_READONLY | db.OPEN_NOFOLLOW, nil) != db.OK {
		if input != nil do db.close(input)
		return false
	}
	defer db.close(input)
	return migration_copy_application(input, application, max_bytes, started, seconds, checkpoint,
		cancel = cancel)
}

@(private)
generation_copy_suffix :: proc(old, h: ^Host, prefix: sql.Slot, started: time.Tick,
	seconds: u32, checkpoint: proc(Generation_Phase), cancel: ^u32) -> bool {
	if !db.begin_tx(h.consensus) do return false
	defer db.rollback_tx(h.consensus)
	promise := Record{kind = 1, ballot = old.node.ledger.promised}
	if !persist_record(h, &promise) do return false
	stmt, ok := prepare(old, "SELECT seq,kind,slot,data,digest FROM _sqlodin_journal ORDER BY seq")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	seq: u64
	head: [32]u8
	for {
		if snapshot.cancelled(cancel) ||
			time.tick_since(started) >= time.Duration(seconds)*time.Second { return false }
		rc := db.sqlite3_step(stmt)
		if rc == db.DONE do break
		if rc != db.ROW do return false
		r: Record
		if !decode_row(stmt, &r) || r.seq != seq+1 || r.previous != head do return false
		seq = r.seq
		copy(head[:], column_blob(stmt, 4))
		if r.kind != 1 && r.slot > prefix && !persist_record(h, &r) do return false
	}
	if seq != old.sequence || head != old.head do return false
	if checkpoint != nil do checkpoint(.Before_Suffix_Commit)
	return db.commit_tx(h.consensus)
}

@(private)
generation_publish_identity :: proc(h, old: ^Host, cluster: string,
	checkpoint: proc(Generation_Phase)) -> bool {
	if !db.begin_tx(h.consensus) do return false
	defer db.rollback_tx(h.consensus)
	ms, valid := migration_integer(old.consensus, "SELECT ms FROM _sqlodin_ids WHERE id=1")
	if !valid || ms < -1 || ms >= i64(1)<<42 do return false
	ids, ok := prepare(h, "UPDATE _sqlodin_ids SET ms=? WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(ids)
	if db.sqlite3_bind_int64(ids, 1, ms) != db.OK || db.sqlite3_step(ids) != db.DONE do return false
	ident := store_identity(h, cluster, old.node.id, sql.membership_slice(&old.node.membership))
	defer delete(ident)
	meta, prepared := prepare(h, "UPDATE _sqlodin_journal_meta SET identity=?,seq=?,digest=? WHERE id=1")
	if !prepared do return false
	defer db.sqlite3_finalize(meta)
	if db.sqlite3_bind_text(meta, 1, cstring(raw_data(ident)), c.int(len(ident)), nil) != db.OK ||
		db.sqlite3_bind_int64(meta, 2, i64(h.sequence)) != db.OK || !bind_blob(meta, 3, h.head[:]) ||
		db.sqlite3_step(meta) != db.DONE { return false }
	if checkpoint != nil do checkpoint(.Before_Identity_Commit)
	if !db.commit_tx(h.consensus) do return false
	h.durable_sequence = h.sequence
	return true
}
