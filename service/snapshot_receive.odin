package service

import libc "core:c"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"
import sql "../src"
import durable "../src/durable"
import snapshot "../src/snapshot"

receive_snapshot_offer :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	if r.node != c.peer || r.packet.kind != 6 || r.packet.from != c.peer ||
		r.packet.to != s.config.node || s.host.snapshot == nil { return false }
	if s.host.snapshot_busy && s.transfer == nil || durable.snapshot_worker_running(s.host.snapshot) {
		return true
	}
	bytes: [snapshot.CANDIDATE_SIZE]u8
	decoded, decode_err := base64.decode_into_buf(bytes[:], r.receipt)
	if decode_err != nil do return false
	candidate, candidate_err := snapshot.candidate_decode_configuration(decoded, s.host.configuration,
		sql.engine_build_fingerprint())
	if candidate_err != .None || candidate.bytes > snapshot.DEFAULT_LOGICAL_LIMITS.image_bytes {
		return false
	}
	if candidate.key.prefix <= s.host.engine.applied_through do return true
	packet: durable.Packet
	if !wire_decode(r.packet, &packet) || durable.snapshot_control(&packet.value) != 2 do return false
	certificate, certificate_err := snapshot.decode_configuration(
		packet.value.sql_bytes[len(durable.SNAPSHOT_SEAL):packet.value.sql_len], s.host.configuration,
		sql.engine_build_fingerprint(), sql.membership_slice(&s.host.node.membership))
	seal := durable.Generation_Seal{certificate, r.packet.fields[0], packet.value}
	if certificate_err != .None || candidate.key != certificate.key ||
		!durable.generation_seal_valid(s.host, &seal) { return false }
	if s.transfer != nil {
		if s.transfer.complete || candidate.key.prefix <= s.transfer.candidate.key.prefix do return true
		snapshot_transfer_cancel(s)
	}
	if !durable.generation_space_available(s.host, candidate.bytes, receiving = true) {
		s.transfer_error = "Snapshot_Space_Reserve"
		return true
	}
	token, err := durable.next_id(s.host, 0)
	if err != .None { s.fatal = true; return false }
	path := fmt.aprintf("%s/incoming-%d-%d.db", s.host.snapshot.directory, candidate.key.prefix, token)
	if durable.register_snapshot_image(s.host, path, fmt.tprintf("%s.manifest", path),
		candidate.key.prefix, received = true) != .None {
		delete(path); s.transfer_error = "Snapshot_Storage"; return false
	}
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if file < 0 { delete(path); s.transfer_error = "Snapshot_Storage"; return false }
	t := new(Snapshot_Transfer)
	t.peer, t.candidate, t.seal, t.path, t.file = c.peer, candidate, seal, path, file
	t.activity = time.tick_now()
	sha2.init_256(&t.hash)
	s.transfer, s.transfer_error = t, ""
	s.host.snapshot_busy = true
	return true
}

receive_snapshot_chunk :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	t := s.transfer
	if r.node != c.peer do return false
	if t == nil || t.peer != c.peer || t.complete || r.snapshot_prefix != t.candidate.key.prefix {
		return true
	}
	if r.snapshot_offset < t.received do return true // repeated request/response
	if r.snapshot_offset != t.received do return false
	buffer := snapshot_transfer_buffer(s)
	bytes, err := base64.decode_into_buf(buffer[:], r.receipt)
	want := min(u64(len(buffer)), t.candidate.bytes-t.received)
	if err != nil || u64(len(bytes)) != want do return false
	position := 0
	for position < len(bytes) {
		remaining := len(bytes)-position
		n := posix.write(t.file, raw_data(bytes[position:]), libc.size_t(remaining))
		if n <= 0 { s.transfer_error = "Snapshot_Storage"; return false }
		position += int(n)
	}
	sha2.update(&t.hash, bytes)
	t.received += u64(len(bytes))
	t.activity, t.requested = time.tick_now(), {}
	s.work_ready = true
	if t.received != t.candidate.bytes do return true
	hash: [32]u8
	sha2.final(&t.hash, hash[:])
	if hash != t.candidate.image { s.transfer_error = "Snapshot_Checksum"; return false }
	if posix.fsync(t.file) != nil { s.transfer_error = "Snapshot_Storage"; return false }
	posix.close(t.file)
	t.file, t.complete = -1, true
	return true
}
