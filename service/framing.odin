package service

import "core:encoding/json"
import "core:time"
import "core:sys/posix"
import tls "../transport/mtls"

connection_close :: proc(s: ^Server, c: ^Connection) {
	if c.state == .Unused do return
	if s.transfer != nil && s.transfer.peer == c.peer do snapshot_transfer_cancel(s)
	release_read(s, c)
	tls.stream_close(&c.tls)
	posix.close(c.fd)
	delete(c.input)
	for bytes in c.out do if bytes != nil { delete(bytes) }
	c^ = {}
}

enqueue :: proc(c: ^Connection, value: $T) -> bool {
	data, err := json.marshal(value, {use_enum_names = true}, allocator = context.temp_allocator)
	limit := MAX_PEER_FRAME if c.peer != 0 else MAX_OUTPUT
	if err != nil || len(data) > limit || c.out_count == len(c.out) ||
	   c.queued + len(data) + 4 > MAX_QUEUED { return false }
	frame := make([]u8, len(data) + 4)
	for i in 0..<4 do frame[i] = u8(u32(len(data)) >> uint(i * 8))
	copy(frame[4:], data)
	profile_frame_copy(len(data))
	c.out[(c.out_head + c.out_count) % len(c.out)] = frame
	c.out_count += 1
	c.queued += len(frame)
	return true
}

flush :: proc(c: ^Connection) -> bool {
	if c.out_count == 0 do return true
	frame := c.out[c.out_head]
	end := min(len(frame), c.out_offset + tls.MAX_IO)
	n, status := tls.write(&c.tls, frame[c.out_offset:end])
	c.write_wait = status
	if status == .Want_Read || status == .Want_Write do return true
	if status != .Ready do return false
	c.out_offset += n
	if c.out_offset == len(frame) {
		c.queued -= len(frame)
		delete(frame)
		c.out[c.out_head] = nil
		c.out_head = (c.out_head + 1) % len(c.out)
		c.out_count -= 1
		c.out_offset = 0
	}
	return true
}

receive :: proc(s: ^Server, c: ^Connection) -> bool {
	// One bounded frame per call; authenticated consensus peers get a bounded burst.
	if c.header_used < 4 {
		n, status := tls.read(&c.tls, c.header[c.header_used:])
		c.read_wait = status
		if status == .Want_Read || status == .Want_Write do return true
		if status != .Ready do return false
		if n > 0 do s.work_ready = true
		c.header_used += n
		if c.header_used < 4 do return true
		size: u32
		for b, i in c.header do size |= u32(b) << uint(i * 8)
		limit := MAX_PEER_FRAME if c.peer != 0 && c.hello else MAX_INPUT
		if size == 0 || size > u32(limit) do return false
		c.input = make([]u8, int(size))
	}
	end := min(len(c.input), c.input_used+tls.MAX_IO)
	n, status := tls.read(&c.tls, c.input[c.input_used:end])
	c.read_wait = status
	if status == .Want_Read || status == .Want_Write do return true
	if status != .Ready do return false
	if n > 0 do s.work_ready = true
	c.input_used += n
	if n > 0 && s.transfer != nil && s.transfer.peer == c.peer {
		s.transfer.activity = time.tick_now()
	}
	if c.input_used < len(c.input) do return true
	if !json_depth_valid(c.input) do return false
	request: Request
	ok := json.unmarshal(c.input, &request, spec = .JSON, allocator = context.temp_allocator) == nil
	if ok do ok = dispatch(s, c, request)
	delete(c.input)
	c.input = nil
	c.input_used, c.header_used = 0, 0
	c.activity = time.tick_now()
	return ok
}
