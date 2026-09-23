// Test-only process receiving a connected nonblocking socket from the Python harness.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:time"
import tls "../../transport/mtls"

wait_ready :: proc(fd: posix.FD, status: tls.Status, start: time.Tick) -> bool {
	if time.tick_since(start) > 5 * time.Second do return false
	events: posix.Poll_Event
	#partial switch status {
	case .Want_Read: events = {.IN}
	case .Want_Write: events = {.OUT}
	case: return false
	}
	p := posix.pollfd{fd = fd, events = events}
	return posix.poll(&p, 1, 50) >= 0
}

transfer :: proc(s: ^tls.Stream, fd: posix.FD, bytes: []u8, writing: bool) -> bool {
	start := time.tick_now()
	for offset := 0; offset < len(bytes); {
		n: int
		status: tls.Status
		if writing do n, status = tls.write(s, bytes[offset:])
		else do n, status = tls.read(s, bytes[offset:])
		if status == .Ready { offset += n; continue }
		if !wait_ready(fd, status, start) do return false
	}
	return true
}

exercise :: proc() -> bool {
	if len(os.args) != 7 do return false
	role: tls.Role
	if os.args[1] == "client" do role = .Client
	else if os.args[1] == "server" do role = .Server
	else do return false
	number, valid := strconv.parse_int(os.args[2])
	if !valid do return false
	fd := posix.FD(number)
	defer posix.close(fd)
	ctx, status := tls.context_open(os.args[3], os.args[4], os.args[5])
	if status != .Ready do return false
	defer tls.context_close(&ctx)
	s, opened := tls.stream_open(&ctx, fd, os.args[6], role)
	if opened != .Ready do return false
	defer tls.stream_close(&s)
	buffer: [4]u8
	// Enforce the boundary: no application I/O before authentication.
	_, early := tls.read(&s, buffer[:])
	if early != .Invalid do return false
	start := time.tick_now()
	for {
		result := tls.handshake(&s)
		if result == .Ready do break
		if !wait_ready(fd, result, start) do return false
	}
	ping := [4]u8{'p', 'i', 'n', 'g'}
	pong := [4]u8{'p', 'o', 'n', 'g'}
	if role == .Client {
		if !transfer(&s, fd, ping[:], true) || !transfer(&s, fd, buffer[:], false) do return false
		return buffer == pong
	}
	if !transfer(&s, fd, buffer[:], false) || buffer != ping do return false
	return transfer(&s, fd, pong[:], true)
}

main :: proc() {
	// The executable owns process signal policy; the reusable TLS package does not.
	if posix.sigignore(.SIGPIPE) != nil do os.exit(1)
	if !exercise() { fmt.eprintln("mTLS probe rejected or timed out"); os.exit(1) }
	fmt.println("authenticated TLS 1.3 application exchange passed")
}
