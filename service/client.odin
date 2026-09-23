package service

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"
import "core:sys/posix"
import tls "../transport/mtls"

Client_Config :: struct { cluster, address, identity, certificate, key, ca: string }

client_wait :: proc(fd: posix.FD, status: tls.Status, started: time.Tick, timeout: time.Duration) -> bool {
	if time.tick_since(started) >= timeout do return false
	if status != .Want_Read && status != .Want_Write do return false
	p := posix.pollfd{fd = fd, events = {.IN} if status == .Want_Read else {.OUT}}
	_ = posix.poll(&p, 1, 20)
	return true
}

client_transfer :: proc(
	s: ^tls.Stream, fd: posix.FD, bytes: []u8, writing: bool, start: time.Tick, timeout: time.Duration,
) -> bool {
	offset := 0
	for offset < len(bytes) {
		if time.tick_since(start) >= timeout do return false
		part := bytes[offset:min(len(bytes), offset + tls.MAX_IO)]
		n: int
		status: tls.Status
		if writing do n, status = tls.write(s, part)
		else do n, status = tls.read(s, part)
		if status == .Ready { offset += n; continue }
		if !client_wait(fd, status, start, timeout) do return false
	}
	return true
}

client_exchange :: proc(
	cfg: Client_Config, request: Request, timeout: time.Duration = 60 * time.Second,
	tls_context: ^tls.Context = nil,
) -> (reply: []u8, ok: bool) {
	owned: tls.Context
	ctx := tls_context
	if ctx == nil {
		status: tls.Status
		owned, status = tls.context_open(cfg.certificate, cfg.key, cfg.ca)
		if status != .Ready do return
		ctx = &owned
	}
	defer tls.context_close(&owned)
	fd := socket_open(cfg.address, false)
	if fd < 0 do return
	defer posix.close(fd)
	start := time.tick_now()
	for {
		ready, failed := connected(fd)
		if failed do return
		if ready do break
		if !client_wait(fd, .Want_Write, start, timeout) do return
	}
	stream, opened := tls.stream_open(ctx, fd, cfg.identity, .Client)
	if opened != .Ready do return
	defer tls.stream_close(&stream)
	for {
		state := tls.handshake(&stream)
		if state == .Ready do break
		if !client_wait(fd, state, start, timeout) do return
	}
	data, err := json.marshal(request, allocator = context.temp_allocator)
	if err != nil || len(data) > MAX_INPUT do return
	frame := make([]u8, len(data) + 4, context.temp_allocator)
	for i in 0..<4 do frame[i] = u8(u32(len(data)) >> uint(i * 8))
	copy(frame[4:], data)
	if !client_transfer(&stream, fd, frame, true, start, timeout) do return
	header: [4]u8
	if !client_transfer(&stream, fd, header[:], false, start, timeout) do return
	size: u32
	for byte, i in header do size |= u32(byte) << uint(i * 8)
	if size == 0 || size > MAX_OUTPUT do return
	reply = make([]u8, int(size), context.temp_allocator)
	return reply, client_transfer(&stream, fd, reply, false, start, timeout)
}

// The request file owns a write's stable identity. This command never invents a
// new identity after failure. Python provides the higher-level recovery API.
request_file :: proc(config_path, request_path: string) -> int {
	if posix.sigignore(.SIGPIPE) != nil do return 2
	cfg_bytes, cfg_err := os.read_entire_file(config_path, context.temp_allocator)
	request_bytes, request_err := os.read_entire_file(request_path, context.temp_allocator)
	if cfg_err != nil || request_err != nil || len(cfg_bytes) > MAX_INPUT ||
	   len(request_bytes) > MAX_INPUT { return 2 }
	cfg: Client_Config
	r: Request
	if json.unmarshal(cfg_bytes, &cfg, spec = .JSON, allocator = context.temp_allocator) != nil ||
	   json.unmarshal(request_bytes, &r, spec = .JSON, allocator = context.temp_allocator) != nil {
		return 2
	}
	r.cluster, r.protocol = cfg.cluster, PROTOCOL
	if r.timeout_ms == 0 do r.timeout_ms = 10000
	if r.op == "query" && r.consistency == "" do r.consistency = "linearizable"
	bytes, ok := client_exchange(cfg, r)
	if !ok {
		fmt.eprintln("No verified result. A write may have committed; retry the same request file.")
		return 2
	}
	response: Response
	if json.unmarshal(bytes, &response, spec = .JSON, allocator = context.temp_allocator) != nil ||
	   response.cluster != cfg.cluster || response.protocol != PROTOCOL ||
	   r.op == "execute" && response.sequence != r.sequence { return 2 }
	fmt.println(string(bytes))
	return 0 if response.status == "ok" else 1
}
