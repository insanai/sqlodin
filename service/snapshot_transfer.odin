package service

import "core:crypto/sha2"
import "core:os"
import "core:sys/posix"
import "core:time"
import durable "../src/durable"
import snapshot "../src/snapshot"
import sql "../src"

SNAPSHOT_CHUNK_BYTES :: 1024*1024
MAX_PEER_FRAME :: 2*1024*1024
Snapshot_Transfer :: struct {
	peer: sql.Node_Id,
	candidate: snapshot.Candidate,
	seal: durable.Generation_Seal,
	path: string,
	file: posix.FD,
	received: u64,
	hash: sha2.Context_256,
	activity, requested: time.Tick,
	complete, preserve: bool,
}

snapshot_transfer_cancel :: proc(s: ^Server) {
	t := s.transfer
	if t == nil do return
	if t.file >= 0 do posix.close(t.file)
	// Only the unadvertised transfer file belongs to this cleanup. A successful
	// installation transfers its ownership to the retained generation instead.
	if t.path != "" && !t.preserve do os.remove(t.path)
	delete(t.path)
	free(t)
	s.transfer = nil
	if s.host != nil do s.host.snapshot_busy = false
}

snapshot_transfer_drive :: proc(s: ^Server) -> bool {
	t := s.transfer
	if t == nil do return true
	if t.candidate.key.prefix <= s.host.engine.applied_through {
		snapshot_transfer_cancel(s)
		return true
	}
	if t.complete do return snapshot_transfer_install(s)
	if time.tick_since(t.activity) > 10*time.Second {
		// Reset the donor's streaming state as well as our partial file. A
		// local-only cancellation would leave its ordinary traffic suppressed.
		for &c in s.connections {
			if c.state != .Unused && c.peer == t.peer {
				connection_close(s, &c)
				return true
			}
		}
		snapshot_transfer_cancel(s)
		return true
	}
	if t.requested != (time.Tick{}) && time.tick_since(t.requested) < time.Second do return true
	for &c in s.connections {
		if c.state != .Ready || !c.hello || c.peer != t.peer do continue
		// TCP already guarantees delivery. A partial response or queued request
		// must finish before a retry can consume another full chunk of queue space.
		if c.input != nil || c.out_count != 0 do return true
		if !enqueue(&c, Request{op = "snapshot_fetch", cluster = s.config.cluster, protocol = PROTOCOL,
			node = s.config.node, snapshot_prefix = t.candidate.key.prefix, snapshot_offset = t.received}) {
			connection_close(s, &c)
			return true
		}
		t.requested = time.tick_now()
		s.work_ready = true
		break
	}
	return true
}

snapshot_transfer_install :: proc(s: ^Server) -> bool {
	t := s.transfer
	next, err := durable.install_store(s.host, t.peer, t.path, s.config.cluster, t.candidate, t.seal)
	if err == .Backpressure do return true
	t.preserve = true
	if err != .None {
		s.transfer_error = "Snapshot_Install_Failed"
		if s.host.poisoned { s.fatal = true; return false }
		snapshot_transfer_cancel(s)
		return true
	}
	old := s.host
	s.host = next
	durable.close(old)
	// The generation now owns its immutable image and manifest.
	delete(t.path)
	t.path = ""
	snapshot_transfer_cancel(s)
	s.transfer_error = ""
	s.work_ready = true
	return true
}

snapshot_transfer_buffer :: proc(s: ^Server) -> []u8 {
	if s.transfer_buffer == nil do s.transfer_buffer = make([]u8, SNAPSHOT_CHUNK_BYTES)
	return s.transfer_buffer
}
