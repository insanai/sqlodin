package service

// Drain a bounded burst so a proposal batch can reach the existing sixteen-
// packet durable transition group. Clients retain one frame per turn; snapshot
// controls and partial frames also stop after one receive operation.
PEER_IO_BURST :: 8

receive_ready :: proc(s: ^Server, c: ^Connection) -> bool {
	if c.peer == 0 || !c.hello do return receive(s, c)
	for _ in 0..<PEER_IO_BURST {
		before := s.incoming_count
		if !receive(s, c) do return false
		if s.incoming_count == before do break
	}
	return true
}

flush_ready :: proc(s: ^Server, c: ^Connection) -> bool {
	budget := PEER_IO_BURST if c.peer != 0 && c.hello else 1
	for _ in 0..<budget {
		before, offset := c.queued, c.out_offset
		if !flush(c) do return false
		if c.queued == before && c.out_offset == offset do break
		s.work_ready = true
		if c.out_count == 0 do break
	}
	return true
}
