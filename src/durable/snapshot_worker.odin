package durable

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:sys/posix"
import sql ".."
import snapshot "../snapshot"

Snapshot_Work :: struct {
	copy: snapshot.Image_Copy,
	image, manifest: string,
	key: snapshot.Key,
	voter: sql.Node_Id,
	members: [MAX_MEMBERS]sql.Node_Id, count: int,
	receipt: snapshot.Receipt,
	error: snapshot.Image_Error,
	done, cancel: u32,
}
Snapshot_State :: struct {
	source, directory: string,
	worker: ^Snapshot_Work, thread: ^thread.Thread,
	prefix: sql.Slot,
	pending_token: u64, pending_slot: sql.Slot,
	receipts: [MAX_MEMBERS]snapshot.Receipt,
	seal_slot: sql.Slot, seal_value: sql.Mutation,
}

snapshot_enable :: proc(h: ^Host, source, directory: string) -> Error {
	if h.consensus == nil || h.snapshot != nil do return .Invalid
	name := strings.clone_to_cstring(directory)
	defer delete(name)
	if posix.mkdir(name, {.IRUSR, .IWUSR, .IXUSR}) != nil && posix.errno() != .EEXIST do return .Storage
	if !sync_directory(directory) do return .Storage
	canonical_source, source_err := os.get_absolute_path(source, context.allocator)
	if source_err != nil do return .Storage
	canonical_dir, dir_err := os.get_absolute_path(directory, context.allocator)
	if dir_err != nil { delete(canonical_source); return .Storage }
	h.snapshot = new(Snapshot_State)
	h.snapshot.source, h.snapshot.directory = canonical_source, canonical_dir
	return .None
}

snapshot_release_worker :: proc(s: ^Snapshot_State) {
	if s.worker != nil do sync.atomic_store(&s.worker.cancel, 1)
	if s.thread != nil { thread.join(s.thread); thread.destroy(s.thread); s.thread = nil }
	if s.worker != nil {
		snapshot.image_cancel(&s.worker.copy)
		delete(s.worker.image); delete(s.worker.manifest)
		free(s.worker); s.worker = nil
	}
}

snapshot_close :: proc(h: ^Host) {
	if h.snapshot == nil do return
	snapshot_release_worker(h.snapshot)
	delete(h.snapshot.source); delete(h.snapshot.directory)
	free(h.snapshot); h.snapshot = nil
}

snapshot_pin :: proc(h: ^Host, prefix: sql.Slot) {
	if h.snapshot_busy do return
	s := h.snapshot
	s.pending_token = 0
	if snapshot_worker_running(s) do return
	if s.worker != nil && h.snapshot_sealed.key.prefix < s.prefix && !snapshot_worker_failed(s) do return
	snapshot_release_worker(s)
	s.prefix, s.receipts, s.seal_slot = prefix, {}, 0
	work := new(Snapshot_Work)
	s.worker = work
	work.image = fmt.aprintf("%s/image-%d.db", s.directory, prefix)
	work.manifest = fmt.aprintf("%s/image-%d.manifest", s.directory, prefix)
	work.key = {configuration = h.configuration, engine = sql.engine_build_fingerprint(),
		generation = prefix, prefix = prefix}
	work.voter = h.node.id
	members := sql.membership_slice(&h.node.membership)
	work.count = len(members)
	copy(work.members[:], members)
	if !snapshot_space_available(h) ||
		register_snapshot_image(h, work.image, work.manifest, prefix) != .None {
		work.error = .Storage
		sync.atomic_store(&work.done, 1)
		return
	}
	work.error = snapshot.image_begin(&work.copy, s.source, work.image,
		snapshot.DEFAULT_LOGICAL_LIMITS.image_bytes, DEFAULT_MAINTENANCE_SECONDS)
	if work.error != .None || work.copy.prefix != prefix {
		work.error = .Invalid_Source if work.error == .None else work.error
		snapshot.image_cancel(&work.copy)
		sync.atomic_store(&work.done, 1)
		return
	}
	s.thread = thread.create(snapshot_worker)
	if s.thread == nil {
		work.error = .Storage
		snapshot.image_cancel(&work.copy)
		sync.atomic_store(&work.done, 1)
		return
	}
	s.thread.data = work
	thread.start(s.thread)
}

snapshot_worker :: proc(t: ^thread.Thread) {
	work := cast(^Snapshot_Work)t.data
	defer sync.atomic_store(&work.done, 1)
	work.copy.cancel = &work.cancel
	for work.copy.phase != .Copied {
		work.error = snapshot.image_step(&work.copy)
		if work.error != .None do return
	}
	limits := snapshot.DEFAULT_LOGICAL_LIMITS
	limits.cancel = &work.cancel
	work.key.logical_state, work.error = snapshot.logical_digest(work.image, work.key.prefix, limits)
	if work.error != .None do return
	candidate, err := snapshot.candidate_from_copy(&work.copy, work.key)
	if err != .None { work.error = .Invalid_Source; return }
	work.receipt, work.error = snapshot.retain(work.image, work.manifest, candidate, work.key,
		work.voter, work.members[:work.count], limits)
}

snapshot_worker_failed :: proc(s: ^Snapshot_State) -> bool {
	return s.worker != nil && sync.atomic_load(&s.worker.done) != 0 && s.worker.error != .None
}

snapshot_worker_running :: proc(s: ^Snapshot_State) -> bool {
	return s.worker != nil && sync.atomic_load(&s.worker.done) == 0
}
