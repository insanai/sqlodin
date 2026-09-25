package service

import libc "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import sql "../src"
import durable "../src/durable"
import snapshot "../src/snapshot"

send_snapshot_offers :: proc(s: ^Server) {
	h := s.host
	if h.snapshot == nil || h.generation_base.key.prefix == 0 do return
	for member, index in sql.membership_slice(&h.node.membership) {
		if !h.snapshot_requests[index] do continue
		for &c in s.connections {
			if c.state != .Ready || !c.hello || c.peer != member do continue
			if c.snapshot_sending && c.snapshot_offered_prefix == h.generation_base.key.prefix {
				h.snapshot_requests[index] = false
				break
			}
			value, found, ok := durable.chosen(h, h.generation_seal)
			if !ok || !found { s.fatal = true; return }
			packet := durable.Packet{value = value}
			packet.env = {from = h.node.id, to = member,
				message = sql.Commit_Message(sql.Mutation){h.generation_seal, &packet.value}}
			encoded, err := snapshot.candidate_encode(h.generation_image, h.generation_base.key)
			if err != .None { s.fatal = true; return }
			if !enqueue(&c, Request{op = "snapshot_offer",
				cluster = s.config.cluster, protocol = PROTOCOL,
				node = h.node.id, packet = wire_encode(&packet),
				receipt = base64.encode(encoded.bytes[:encoded.count],
					allocator = context.temp_allocator)}) {
				connection_close(s, &c)
				break
			}
			// An offer may be declined while the receiver is capturing an image.
			// Suppress ordinary traffic only after it actually requests a chunk.
			c.snapshot_offered_prefix = h.generation_base.key.prefix
			h.snapshot_requests[index] = false
			break
		}
	}
}

send_snapshot_chunk :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	h := s.host
	if r.node != c.peer || h.snapshot == nil do return false
	if r.snapshot_prefix != h.generation_base.key.prefix {
		for member, index in sql.membership_slice(&h.node.membership) {
			if member == c.peer do h.snapshot_requests[index] = true
		}
		return true
	}
	if r.snapshot_offset >= h.generation_image.bytes do return false
	c.snapshot_sending, c.snapshot_offered_prefix = true, r.snapshot_prefix
	// Drain earlier bounded consensus output before reserving a full chunk.
	// The receiver retries this fetch; sending it twice would fill the queue.
	if c.queued > MAX_QUEUED/4 do return true
	path := fmt.tprintf("%s/%s", h.snapshot.directory, h.generation_image_name)
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.NOFOLLOW, .NONBLOCK})
	if file < 0 { s.transfer_error = "Snapshot_Image_Unavailable"; return false }
	defer posix.close(file)
	stat: posix.stat_t
	if posix.fstat(file, &stat) != nil || !posix.S_ISREG(stat.st_mode) ||
		u64(stat.st_size) != h.generation_image.bytes { return false }
	buffer := snapshot_transfer_buffer(s)
	want := int(min(u64(len(buffer)), h.generation_image.bytes-r.snapshot_offset))
	position := 0
	for position < want {
		n := posix.pread(file, raw_data(buffer[position:]), libc.size_t(want-position),
			posix.off_t(r.snapshot_offset+u64(position)))
		if n <= 0 do return false
		position += int(n)
	}
	return enqueue(c, Request{op = "snapshot_chunk", cluster = s.config.cluster, protocol = PROTOCOL,
		node = h.node.id, snapshot_prefix = r.snapshot_prefix, snapshot_offset = r.snapshot_offset,
		receipt = base64.encode(buffer[:want], allocator = context.temp_allocator)})
}
