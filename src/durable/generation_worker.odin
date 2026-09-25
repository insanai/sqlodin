package durable

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import db "../sqlite"
import sql ".."
import snapshot "../snapshot"

// The worker owns an independent pinned consensus reader and private generation.
// It never reads the mutable service host. The owner later replays a bounded
// delta before one serialized catalog publication.
Generation_Work :: struct {
	source, next: ^Host,
	thread: ^thread.Thread,
	image, application, consensus, directory, name, cluster: string,
	candidate: snapshot.Candidate,
	cursor: u64,
	head: [32]u8,
	done, cancel: u32,
	error: Error,
	allocator: mem.Allocator,
}

begin_compaction :: proc(h: ^Host, cluster: string) -> Error {
	if h == nil || h.poisoned || !h.store_guard_owned || h.snapshot == nil ||
		h.snapshot_sealed.key.prefix <= h.generation_base.key.prefix { return .Invalid }
	if h.snapshot_busy || h.compaction != nil || snapshot_worker_running(h.snapshot) do return .Backpressure
	w := new(Generation_Work)
	w.allocator = context.allocator
	h.compaction = w
	good := false
	defer if !good do generation_release_worker(h)
	prefix := h.snapshot_sealed.key.prefix
	w.image = fmt.aprintf("%s/image-%d.db", h.snapshot.directory, prefix)
	manifest := fmt.aprintf("%s/image-%d.manifest", h.snapshot.directory, prefix)
	defer delete(manifest)
	err: snapshot.Image_Error
	w.candidate, err = snapshot.candidate_load(manifest, h.snapshot_sealed.key)
	if err != .None do return .Storage
	if !generation_space_available(h, w.candidate.bytes) do return .Backpressure
	token, token_err := next_id(h, 0)
	if token_err != .None do return token_err
	w.name = fmt.aprintf("generation-%d-%d", prefix, token)
	w.directory = fmt.aprintf("%s/%s", h.store_root, w.name)
	if !create_generation_directory(h, w.name) do return .Storage
	w.application, w.consensus = fmt.aprintf("%s/node.db", w.directory),
		fmt.aprintf("%s/consensus.db", w.directory)
	w.cluster = strings.clone(cluster)
	w.source = generation_pin_source(h, cluster)
	if w.source == nil do return .Storage
	w.cursor, w.head = w.source.sequence, w.source.head
	w.thread = thread.create(generation_worker)
	if w.thread == nil do return .Storage
	h.snapshot_busy = true
	w.thread.data = w
	thread.start(w.thread)
	good = true
	return .None
}

@(private)
generation_pin_source :: proc(h: ^Host, cluster: string) -> ^Host {
	source := new(Host)
	source.lock, source.consensus_lock = -1, -1
	good := false
	defer if !good do close(source)
	path := strings.clone_to_cstring(h.consensus_path)
	defer delete(path)
	if db.sqlite3_open_v2(path, &source.consensus,
		db.OPEN_READONLY | db.OPEN_PRIVATECACHE | db.OPEN_NOFOLLOW, nil) != db.OK { return nil }
	if !db.exec(source.consensus, "PRAGMA cache_size=-8192; PRAGMA query_only=ON; BEGIN") do return nil
	source.node.id, source.node.membership = h.node.id, h.node.membership
	source.genesis, source.genesis_hash = h.genesis, h.genesis_hash
	source.node.ledger.promised = h.node.ledger.promised
	source.engine.applied_through, source.configuration = h.engine.applied_through, h.configuration
	source.snapshot_sealed, source.snapshot_seal_slot = h.snapshot_sealed, h.snapshot_seal_slot
	source.generation_base = h.generation_base
	source.store_current = strings.clone(h.store_current)
	history_attach(source, h)
	ident := store_identity(source, cluster, h.node.id, sql.membership_slice(&source.node.membership))
	defer delete(ident)
	if !check_identity(source, ident) || source.sequence != h.sequence || source.head != h.head {
		return nil
	}
	good = true
	return source
}

@(private)
generation_worker :: proc(t: ^thread.Thread) {
	w := cast(^Generation_Work)t.data
	context.allocator = w.allocator
	defer sync.atomic_store(&w.done, 1)
	w.error = build_generation(w.source, w.image, w.application, w.consensus, w.cluster, w.candidate,
		cancel = &w.cancel)
	if w.error != .None do return
	w.next, w.error = open(w.application, w.cluster, w.source.node.id,
		sql.membership_slice(&w.source.node.membership), consensus_path = w.consensus, cancel = &w.cancel)
	if w.next != nil do history_attach(w.next, w.source)
	// Release the WAL pin before the owner starts copying newer journal records.
	close(w.source)
	w.source = nil
}

generation_release_worker :: proc(h: ^Host) {
	w := h.compaction
	if w == nil do return
	sync.atomic_store(&w.cancel, 1)
	if w.thread != nil { thread.join(w.thread); thread.destroy(w.thread) }
	close(w.source)
	close(w.next)
	delete(w.image); delete(w.application); delete(w.consensus)
	delete(w.directory); delete(w.name); delete(w.cluster)
	free(w)
	h.compaction, h.snapshot_busy = nil, false
}

poll_compaction :: proc(h: ^Host) -> (^Host, Error) {
	w := h.compaction
	if h.poisoned || w == nil do return nil, .Invalid
	if sync.atomic_load(&w.done) == 0 do return nil, .None
	if w.error != .None {
		err := w.error
		generation_release_worker(h)
		return nil, err
	}
	if !generation_copy_delta(h, w) {
		generation_release_worker(h)
		return nil, .Storage
	}
	if w.cursor != h.sequence || w.next.engine.applied_through < h.engine.applied_through {
		return nil, .None
	}
	if w.head != h.head || !generation_finalize_delta(h, w) {
		generation_release_worker(h)
		return nil, .Storage
	}
	next, err := publish_open_generation(h, w.next, w.application, w.directory, w.name, nil)
	if err == .None do w.next = nil
	generation_release_worker(h)
	return next, err
}
