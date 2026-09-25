package service

// SOD 0005: a peer link drains everything the socket accepts in one turn, and
// receives until the turn's packet buffer is full, so one turn's barrier covers
// all packets that arrived. Clients retain one frame per turn; snapshot
// controls and partial frames also stop after one receive operation. Bytes and
// frames per connection remain bounded by MAX_QUEUED and MAX_QUEUED_FRAMES.
PEER_IO_BURST :: MAX_INCOMING

receive_ready :: proc(s: ^Server, c: ^Connection) -> bool {
	if c.peer == 0 || !c.hello do return receive(s, c)
	for _ in 0..<PEER_IO_BURST {
		// Leave further frames in the socket rather than forcing an extra barrier.
		if s.incoming_count == len(s.incoming) do break
		before := s.incoming_count
		if !receive(s, c) do return false
		if s.incoming_count == before do break
	}
	return true
}

flush_ready :: proc(s: ^Server, c: ^Connection) -> bool {
	budget := MAX_QUEUED_FRAMES if c.peer != 0 && c.hello else 1
	for _ in 0..<budget {
		before, offset := c.queued, c.out_offset
		if !flush(c) do return false
		if c.queued == before && c.out_offset == offset do break
		s.work_ready = true
		if c.out_count == 0 do break
	}
	return true
}
