package service

import "core:fmt"
import vmem "core:mem/virtual"
import "core:time"
import "core:sys/posix"
import durable "../src/durable"
import tls "../transport/mtls"

start_connection :: proc(s: ^Server, fd: posix.FD, member: ^Member = nil) -> bool {
	if member == nil && !incoming_admission_available(s) do return false
	for &c in s.connections {
		if c.state != .Unused do continue
		stream: tls.Stream
		status: tls.Status
		if member == nil do stream, status = tls.stream_accept(&s.tls, fd, s.allowed[:s.allowed_count])
		else do stream, status = tls.stream_open(&s.tls, fd, member.identity, .Client)
		if status != .Ready do return false
		c = Connection{fd = fd, tls = stream, state = .Handshake,
			born = time.tick_now(), activity = time.tick_now()}
		if member != nil { c.state = .Connecting; c.peer = member.id }
		return true
	}
	return false
}

accept_connections :: proc(s: ^Server) {
	for _ in 0..<4 {
		fd := posix.accept(s.listener, nil, nil)
		if fd < 0 do return
		if !nonblocking(fd) || !start_connection(s, fd) do posix.close(fd)
	}
}

dial_peers :: proc(s: ^Server) {
	if time.tick_since(s.last_dial) < time.Second do return
	s.last_dial = time.tick_now()
	for &m in s.config.members {
		if m.id <= s.config.node do continue
		found := false
		for &c in s.connections do if c.state != .Unused && c.peer == m.id { found = true }
		if found do continue
		fd := socket_open(m.address, false)
		if fd < 0 do continue
		if !start_connection(s, fd, &m) do posix.close(fd)
	}
}

authenticate :: proc(s: ^Server, c: ^Connection) -> bool {
	if time.tick_since(c.born) > 5 * time.Second do return false
	if c.state == .Connecting {
		ready, failed := connected(c.fd)
		if failed do return false
		if !ready do return true
		c.state = .Handshake
	}
	status := tls.handshake(&c.tls)
	c.handshake_wait = status
	if status == .Want_Read || status == .Want_Write do return true
	if status != .Ready do return false
	name := tls.peer_name(&c.tls)
	for m in s.config.members {
		if m.identity != name do continue
		if m.id == s.config.node || c.peer != 0 && c.peer != m.id do return false
		c.peer = m.id
	}
	if c.peer == 0 {
		client := false
		for identity in s.config.clients do if identity == name { client = true }
		if !client do return false
		c.admission_rejected = !client_admission_available(s)
	} else {
		for &other in s.connections {
			if &other != c && other.state == .Ready && other.peer == c.peer do return false
		}
		if !enqueue(c, Request{op = "hello", cluster = s.config.cluster, protocol = PROTOCOL,
			node = s.config.node, fingerprint = s.fingerprint}) { return false }
	}
	c.state = .Ready
	return true
}

drive_connection :: proc(s: ^Server, c: ^Connection) -> bool {
	if c.state != .Ready do return authenticate(s, c)
	if !flush_ready(s, c) do return false
	if c.close_after_flush do return c.out_count > 0
	if c.admission_rejected && time.tick_since(c.born) > 5 * time.Second do return false
	if c.pending != .None {
		if time.tick_since(c.pending_since) >= c.timeout {
			release_read(s, c)
			error := "Unknown_Outcome" if c.pending == .Write else "Read_Timeout"
			if c.pending == .Write && c.slot == 0 do error = "Busy"
			c.pending = .None
			return respond(s, c, error)
		}
		if c.pending == .Write do return poll_write(s, c)
		return poll_read(s, c)
	}
	if time.tick_since(c.activity) > 120 * time.Second do return false
	return receive_ready(s, c)
}

route_packets :: proc(s: ^Server) {
	packet: durable.Packet
	for _ in 0..<256 {
		if !durable.pop(s.host, &packet) do return
		s.work_ready = true
		// Upstream phase-one broadcasts include the local acceptor. Deliver it
		// through the same durable transition boundary as a remote packet.
		if packet.env.to == s.config.node {
			err := durable.step(s.host, durable.envelope(&packet))
			if err != .None { s.fatal = true; return }
			continue
		}
		for &c in s.connections {
			if c.state != .Ready || !c.hello || c.peer != packet.env.to do continue
			// Catch-up owns this slow peer's bounded output queue until it has
			// installed the image; normal consensus traffic can be retransmitted.
			if c.snapshot_sending do break
			// A slow peer is packet loss, not a broken authenticated connection.
			// Leave room for snapshot control and let Paxos retransmit dropped work.
			if c.queued > MAX_QUEUED/4 do break
			request := Request{op = "packet", cluster = s.config.cluster, protocol = PROTOCOL,
				packet = wire_encode(&packet)}
			_ = enqueue(&c, request)
			break
		}
		// A disconnected peer is packet loss; upstream retransmission/catch-up recovers it.
	}
}

run :: proc(config_path: string, create: bool = false, duration_seconds: int = 0) -> bool {
	when RESOURCE_PROFILE {
		profile: Resource_Profile
		// Context changes are local to this procedure, not inherited from helpers.
		context.allocator, context.temp_allocator = resource_profile_begin(&profile)
		defer {
			context.allocator, context.temp_allocator = profile.heap.backing, profile.temporary.backing
			resource_profile_end(&profile)
		}
	}
	if posix.sigignore(.SIGPIPE) != nil || !install_signals() do return false
	config_arena: vmem.Arena
	if vmem.arena_init_growing(&config_arena) != nil do return false
	defer vmem.arena_destroy(&config_arena)
	cfg, valid := load_config(config_path, vmem.arena_allocator(&config_arena))
	if !valid { fmt.eprintln("Invalid service configuration"); return false }
	s, opened := server_open(cfg, create)
	if !opened { fmt.eprintln("Cannot open service; existing state is never replaced"); return false }
	defer server_close(s)
	started := time.tick_now()
	s.last_tick, s.last_dial = started, started
	fmt.printf("SQLodin node %d listening on %s (mTLS, cluster %s)\n",
		cfg.node, cfg.listen, cfg.cluster)
	for !s.fatal {
		s.work_ready = false
		free_all(context.temp_allocator)
		if stopping() do return true
		if duration_seconds > 0 &&
		   time.tick_since(started) >= time.Duration(duration_seconds) * time.Second {
			return true
		}
		accept_connections(s)
		dial_peers(s)
		repair_peers(s)
		for &c in s.connections {
			if c.state == .Unused do continue
			if !drive_connection(s, &c) do connection_close(s, &c)
			if s.fatal do break
		}
		if !apply_packets(s) && s.fatal do break
		if !finish_read_cohort(s) do break
		if !begin_read_cohort(s) do break
		if !admit_writes(s) do break
		if time.tick_since(s.last_tick) >= 100 * time.Millisecond {
			err := durable.tick(s.host)
			if err != .None && err != .Backpressure do s.fatal = true
			s.last_tick = time.tick_now()
		}
		err := durable.progress(s.host)
		if err != .None && err != .Backpressure { s.fatal = true; break }
		route_packets(s)
		if !drive_snapshots(s) do break
		wait_io(s)
	}
	fmt.eprintln("SQLodin stopped after a durable storage or consensus failure")
	if reason := snapshot_error(s); reason != "" do fmt.eprintf("Maintenance failure: %s\n", reason)
	return false
}

wait_io :: proc(s: ^Server) {
	fds: [MAX_CONNECTIONS + 1]posix.pollfd
	fds[0] = {fd = s.listener, events = {.IN}}
	count := 1
	for &c in s.connections {
		if c.state == .Unused do continue
		events: posix.Poll_Event
		if c.pending == .None || c.write_wait == .Want_Read do events |= {.IN}
		if c.state == .Connecting || c.handshake_wait == .Want_Write ||
		   c.read_wait == .Want_Write || c.out_count > 0 && c.write_wait != .Want_Read {
			events |= {.OUT}
		}
		fds[count] = {fd = c.fd, events = events}
		count += 1
	}
	_ = posix.poll(&fds[0], posix.nfds_t(count), 0 if s.work_ready else 10)
}

// Restart clears volatile peer frontiers. Poll retained decisions from every
// authenticated peer, including when ownership has no live leader hint. This
// repeats lost requests and advances through more than one bounded chunk.
repair_peers :: proc(s: ^Server) {
	if time.tick_since(s.last_repair) < time.Second do return
	s.last_repair = time.tick_now()
	for &c in s.connections {
		if c.state != .Ready || !c.hello || c.peer == 0 do continue
		err := durable.catch_up(s.host, c.peer)
		if err != .None && err != .Backpressure { s.fatal = true; return }
	}
}

// Frames own their Mutation payload before any receive arena is reset. The
// durable host withholds every dependent message until the group is committed.
apply_packets :: proc(s: ^Server) -> bool {
	if s.incoming_count == 0 do return true
	err := durable.step_batch(s.host, s.incoming[:s.incoming_count])
	if err == .Backpressure do return false
	if err != .None { s.fatal = true; return false }
	s.incoming_count = 0
	s.work_ready = true
	return true
}
