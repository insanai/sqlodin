// Durable, serialized host for fixed-membership Paxos. Transport belongs to the caller.
package durable

import "core:container/queue"
import "core:strings"
import snap "../snapshot"
import "core:time"
import "core:sys/posix"
import sql ".."
import db "../sqlite"

MAX_MEMBERS :: 5
WINDOW :: 64
CHUNK :: 16
JOURNAL_GROUP_COMMIT :: #config(SQLODIN_JOURNAL_GROUP_COMMIT, true)
when JOURNAL_GROUP_COMMIT {
	DURABILITY_GATE :: sql.Durability_Gate.Host_Managed
} else {
	DURABILITY_GATE :: sql.Durability_Gate.Enforced
}
Error :: enum { None, Invalid, Locked, Storage, Consensus, Poisoned, Backpressure }
Fault :: enum { None, Before_Journal_Commit, After_Journal_Commit, After_Application_Commit }
Packet :: struct { env: sql.Envelope(sql.Mutation), value: sql.Mutation }
Host :: struct {
	node: sql.MultiMaster_Node(sql.Mutation, MAX_MEMBERS, WINDOW, CHUNK, DURABILITY_GATE),
	effects: sql.Effects(sql.Mutation, MAX_MEMBERS, WINDOW, CHUNK, DURABILITY_GATE),
	engine: sql.Engine,
	configuration: [32]u8,
	genesis: Backup_Manifest,
	genesis_hash: [32]u8,
	application_path, consensus_path, store_root: string,
	history_root, history_current, history_previous: string, // detached writer budget scope
	store_current, generation_previous: string,
	compaction: ^Generation_Work,
	store_guard: posix.FD,
	store_guard_owned: bool,
	snapshot: ^Snapshot_State,
	snapshot_busy: bool,
	snapshot_sealed: snap.Certificate,
	snapshot_seal_slot: sql.Slot,
	snapshot_requests: [MAX_MEMBERS]bool,
	generation_base: snap.Certificate,
	generation_image: snap.Candidate,
	generation_image_name: string,
	generation_seal: sql.Slot,
	consensus: db.Sqlite3, // nil for the legacy combined format-4 store
	consensus_lock: posix.FD,
	packets: queue.Queue(Packet),
	sequence: u64,
	chosen_stmt: db.Sqlite3_Stmt,
	durable_sequence: u64,
	transition_group: ^Transition_Group,
	head: [32]u8,
	id_next: u64,
	id_end: u64,
	lock: posix.FD,
	poisoned: bool,
	recovery: Recovery_Stats,
	active_read: Read_Ticket,
	// Test-only interruption points. Production callers leave this at None.
	fault: Fault,
	checkpoint: proc(Fault),
}

// create is explicit and exclusive: reopening a missing file must never reset an acceptor.
// The parent directory must already exist on durable storage. IDs and membership are immutable.
open :: proc(
	path, cluster: string, id: sql.Node_Id, members: []sql.Node_Id, create: bool = false,
	consensus_path: string = "", cancel: ^u32 = nil,
) -> (^Host, Error) {
	if path == "" || path == ":memory:" || strings.has_prefix(path, "file:") ||
	   cluster == "" || strings.contains(cluster, ";") {
		return nil, .Invalid
	}
	membership: sql.Membership(MAX_MEMBERS)
	if sql.membership_init(&membership, members) != .None ||
	   !sql.membership_contains(&membership, id) {
		return nil, .Invalid
	}
	fd, locked := lock_database(path, create)
	if !locked do return nil, .Locked
	h := new(Host)
	h.lock, h.consensus_lock = fd, -1
	h.application_path = strings.clone(path)
	if consensus_path != "" {
		if consensus_path == path || !open_consensus(h, consensus_path, create) {
			close(h)
			return nil, .Storage
		}
	}
	good := false
	defer if !good do close(h)
	if queue.init(&h.packets, 32) != nil do return nil, .Storage
	engine, err := sql.engine_open(path, id)
	if err != .None do return nil, .Storage
	h.engine = engine
	maintenance_handlers(h, cancel)
	defer maintenance_handlers(h, nil)
	started := time.tick_now()
	if !check_storage(h) do return nil, .Storage
	h.recovery.integrity = time.tick_since(started)
	if !load_genesis(h, cluster) do return nil, .Storage
	ident := store_identity(h, cluster, id, members)
	defer delete(ident)
	if !application_identity(h, cluster, members, create) do return nil, .Storage
	if create && (!initialize(h, ident) || !sync_directory(path) ||
		consensus_path != "" && !sync_directory(consensus_path)) { return nil, .Storage }
	configuration := store_identity(h, cluster, 0, members)
	h.configuration = digest(transmute([]u8)configuration)
	delete(configuration)
	h.node.membership = membership
	if generation_redirected(h) || !check_identity(h, ident) ||
	   sql.engine_install_limits(&h.engine) != .None ||
	   sql.engine_install_function_policy(&h.engine) != .None || !recover_measured(h, cancel) {
		return nil, .Storage
	}
	ledger := new(type_of(h.node.ledger))
	ledger^ = h.node.ledger
	defer free(ledger)
	noop := sql.mutation_make_skip(0, 0)
	if sql.node_restore(&h.node, id, membership, ledger^, noop,
		h.engine.applied_through) != .None {
		return nil, .Consensus
	}
	if sql.engine_open_reader(&h.engine, path) != .None do return nil, .Storage
	good = true
	if !application_cache_mode(h) do return nil, .Storage
	return h, .None
}

close :: proc(h: ^Host) {
	if h == nil do return
	generation_release_worker(h)
	snapshot_close(h)
	if h.chosen_stmt != nil do db.sqlite3_finalize(h.chosen_stmt)
	sql.engine_close(&h.engine)
	if h.consensus != nil do db.close(h.consensus)
	if h.consensus_lock >= 0 do posix.close(h.consensus_lock)
	if h.transition_group != nil do free(h.transition_group)
	queue.destroy(&h.packets)
	if h.lock >= 0 do posix.close(h.lock)
	if h.store_guard_owned do posix.close(h.store_guard)
	delete(h.generation_image_name)
	delete(h.history_current)
	delete(h.history_previous)
	delete(h.history_root)
	delete(h.store_root)
	delete(h.store_current)
	delete(h.generation_previous)
	delete(h.application_path)
	delete(h.consensus_path)
	free(h)
}

poison :: proc(h: ^Host) -> Error {
	h.poisoned = true
	return .Storage
}

propose :: proc(h: ^Host, value: sql.Mutation) -> (sql.Slot, Error) {
	// Nonzero no-op keys are reserved for host-generated, fresh read barriers.
	if value.kind == .Skip && value.primary_key != 0 do return 0, .Invalid
	if err := history_admission(h); err != .None do return 0, err
	return propose_internal(h, value)
}

@(private)
propose_internal :: proc(h: ^Host, value: sql.Mutation) -> (sql.Slot, Error) {
	if h.poisoned do return 0, .Poisoned
	if queue.len(h.packets) >= 1024 do return 0, .Backpressure
	v := value
	if sql.mutation_validate(&v) != .None do return 0, .Invalid
	slot, err := sql.node_propose(&h.node, value, &h.effects)
	if err != .None do return 0, proposal_error(err)
	return slot, finish(h)
}

step :: proc(h: ^Host, env: sql.Envelope(sql.Mutation)) -> Error {
	if h.poisoned do return .Poisoned
	if queue.len(h.packets) >= 1024 do return .Backpressure
	if value, ok := sql.message_value(env.message); ok {
		if sql.mutation_validate(value) != .None do return .Invalid
	}
	if sql.node_step(&h.node, env, &h.effects) != .None do return poison(h)
	return finish(h)
}

tick :: proc(h: ^Host) -> Error {
	if h.poisoned do return .Poisoned
	if queue.len(h.packets) >= 1024 do return .Backpressure
	if sql.node_tick(&h.node, &h.effects) != .None do return poison(h)
	return finish(h)
}

append_packet :: proc(h: ^Host, env: sql.Envelope(sql.Mutation)) -> bool {
	if h.sequence > h.durable_sequence do return false
	p := Packet{env = env}
	if value, ok := sql.message_value(env.message); ok do p.value = value^
	ok, err := queue.push_back(&h.packets, p)
	return ok && err == nil
}

serve :: proc(h: ^Host, request: sql.Serve_Range_Request) -> bool {
	// Bound peer work; the peer can request the next chunk on subsequent ticks.
	for i in 0..<min(request.count, u32(CHUNK)) {
		slot := request.first + u64(i)
		if slot < request.first || slot > h.engine.applied_through do break
		if slot <= max(h.generation_base.key.prefix, h.genesis.prefix) {
			for member, index in sql.membership_slice(&h.node.membership) {
				if member == request.peer do h.snapshot_requests[index] = true
			}
			return true
		}
		value, found, ok := chosen(h, slot)
		if !ok || !found do return false
		env := sql.Envelope(sql.Mutation){from = h.node.id, to = request.peer,
			message = sql.Commit_Message(sql.Mutation){slot, &value}}
		if !append_packet(h, env) do return false
	}
	return true
}

finish :: proc(h: ^Host) -> Error {
	if !persist(h) do return poison(h)
	if h.sequence != h.durable_sequence do return poison(h)
	sql.effects_confirm_writes_durable(&h.effects)
	if !apply_host_entries(h, sql.effects_committed_slice(&h.effects)) {
		return poison(h)
	}
	if h.checkpoint != nil do h.checkpoint(.After_Application_Commit)
	if h.fault == .After_Application_Commit do return poison(h)
	for env in sql.effects_messages_slice(&h.effects) {
		if !append_packet(h, env) do return poison(h)
	}
	for request in sql.effects_requests_slice(&h.effects) {
		switch r in request {
		case sql.Serve_Range_Request: if !serve(h, r) do return poison(h)
		}
	}
	if sql.node_advance_memory_floor(&h.node, h.engine.applied_through) != .None {
		return poison(h)
	}
	sql.effects_reset(&h.effects)
	return .None
}

// Copy into caller-owned stable storage before rebinding borrowed message pointers.
pop :: proc(h: ^Host, packet: ^Packet) -> bool {
	if h.poisoned || h.sequence > h.durable_sequence do return false
	p, ok := queue.pop_front_safe(&h.packets)
	if ok do packet^ = p
	return ok
}

envelope :: proc(p: ^Packet) -> sql.Envelope(sql.Mutation) {
	env := p.env
	#partial switch &m in env.message {
	case sql.Promise_Message(sql.Mutation): m.value = &p.value
	case sql.Accept_Message(sql.Mutation): m.value = &p.value
	case sql.Commit_Message(sql.Mutation): m.value = &p.value
	}
	return env
}

// A proposal slot alone is not an acknowledgement: recovery can choose a different value.
acknowledged :: proc(h: ^Host, slot: sql.Slot, expected: ^sql.Mutation) -> bool {
	result, complete, err := outcome(h, slot, expected)
	return err == .None && complete && result.kind == .Applied
}

// Read a durable completion, including a SQL rejection. A displaced proposal is
// not completed here: callers retry the same Request_Id, never invent a new one.
outcome :: proc(
	h: ^Host, slot: sql.Slot, expected: ^sql.Mutation,
) -> (result: sql.Outcome, complete: bool, err: Error) {
	if h.poisoned do return {}, false, .Poisoned
	if slot == 0 || slot > h.engine.applied_through do return {}, false, .None
	value, found, ok := chosen(h, slot)
	if !ok do return {}, false, poison(h)
	if !found || value != expected^ do return {}, false, .None
	read_err: sql.Error
	result, complete, read_err = sql.engine_outcome(&h.engine, slot)
	if read_err != .None || !complete do return {}, false, poison(h)
	return result, true, .None
}
