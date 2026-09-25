package durable

import "core:strings"
import "core:os"
import "core:time"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

Migration_Phase :: enum {
	Validate, Source, Copy_Application, Separate_Application, Initialize_Consensus,
	Copy_Consensus, Recover, Complete,
}

migration_phase :: proc(out: ^Migration_Phase, phase: Migration_Phase) {
	if out != nil do out^ = phase
}

// Offline, explicit format-4 -> separated format-5 migration. Output files must
// not exist. Source is locked and opened read-only; its main file/WAL are never
// rewritten. Caller owns private directories and must preserve failed outputs
// for inspection or remove them explicitly before a new attempt.
// Incomplete output uses an unopenable identity until all acceptor state commits.
migrate_format4 :: proc(
	source, application, consensus, cluster: string, id: sql.Node_Id, members: []sql.Node_Id,
	max_bytes: u64 = 128*1024*1024*1024, seconds: u32 = DEFAULT_MAINTENANCE_SECONDS,
	phase: ^Migration_Phase = nil,
) -> Error {
	migration_phase(phase, .Validate)
	membership: sql.Membership(MAX_MEMBERS)
	if sql.membership_init(&membership, members) != .None ||
		!sql.membership_contains(&membership, id) || cluster == "" || strings.contains(cluster, ";") ||
		max_bytes < 4096 || max_bytes > u64(max(i64)) || seconds == 0 || seconds > 3600 {
		return .Invalid
	}
	for path in ([3]string{source, application, consensus}) {
		if path == "" || path == ":memory:" || strings.has_prefix(path, "file:") ||
			strings.contains(path, "\x00") { return .Invalid }
	}
	if source == application || source == consensus || application == consensus do return .Invalid
	migration_phase(phase, .Source)
	lock, locked := lock_database(source, false)
	if !locked do return .Locked
	defer posix.close(lock)
	canonical, path_err := os.get_absolute_path(source, context.allocator)
	if path_err != nil do return .Storage
	defer delete(canonical)
	name := strings.clone_to_cstring(canonical)
	defer delete(name)
	old := new(Host)
	defer free(old)
	if db.sqlite3_open_v2(name, &old.consensus, db.OPEN_READONLY | db.OPEN_NOFOLLOW, nil) != db.OK {
		if old.consensus != nil do db.close(old.consensus)
		return .Storage
	}
	defer db.close(old.consensus)
	if !db.exec(old.consensus, "PRAGMA query_only=ON; BEGIN;") ||
		!migration_source_identity(old, cluster, id, members) { return .Storage }
	started := time.tick_now()
	h := new(Host)
	h.lock, h.consensus_lock = -1, -1
	defer close(h)
	file_locked: bool
	h.lock, file_locked = lock_database(application, true)
	if !file_locked do return .Storage
	if !open_consensus(h, consensus, true) do return .Storage
	migration_phase(phase, .Copy_Application)
	if !migration_copy_application(old.consensus, application, max_bytes, started, seconds) {
		return .Storage
	}
	engine, err := sql.engine_open(application, id)
	if err != .None do return .Storage
	h.engine = engine
	migration_phase(phase, .Separate_Application)
	if !check_storage(h) || !migration_application_identity(h, cluster, members) do return .Storage
	migration_phase(phase, .Initialize_Consensus)
	if !initialize(h, "sqlodin-migration-incomplete") do return .Storage
	migration_phase(phase, .Copy_Consensus)
	if !migration_copy_consensus(old, h, cluster, id, members, started, seconds) {
		return .Storage
	}
	migration_phase(phase, .Recover)
	if sql.engine_install_limits(&h.engine) != .None ||
		sql.engine_install_function_policy(&h.engine) != .None || !recover_measured(h) ||
		!sync_directory(application) || !sync_directory(consensus) { return .Storage }
	migration_phase(phase, .Complete)
	return .None
}

@(private)
migration_application_identity :: proc(h: ^Host, cluster: string, members: []sql.Node_Id) -> bool {
	if !db.begin_tx(h.engine.db) do return false
	defer db.rollback_tx(h.engine.db)
	if sql.engine_upgrade_session_epoch(&h.engine) != .None do return false
	if !db.exec(h.engine.db, "DROP TABLE _sqlodin_journal; DROP TABLE _sqlodin_journal_meta; " +
		"DROP TABLE _sqlodin_ids; " +
		"ALTER TABLE _sqlodin_state ADD COLUMN identity TEXT NOT NULL DEFAULT '';") {
		return false
	}
	ident := store_identity(h, cluster, 0, members)
	defer delete(ident)
	return set_application_identity(h, ident) && db.commit_tx(h.engine.db)
}

@(private)
migration_source_identity :: proc(h: ^Host, cluster: string, id: sql.Node_Id,
	members: []sql.Node_Id) -> bool {
	for policy in ([4]int{sql.REPLICATION_POLICY, 8, 7, 6}) {
		ident := identity(cluster, id, members, policy)
		matched := check_identity(h, ident)
		delete(ident)
		if matched do return true
	}
	return false
}
