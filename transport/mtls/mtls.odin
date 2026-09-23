// Experimental nonblocking TLS primitive, not a listener, service or membership API.
package mtls

import "core:c"
import "core:strings"
import "core:sys/posix"

Role :: enum { Client, Server }
Status :: enum { Ready, Want_Read, Want_Write, Closed, Failed, Invalid }
Context :: struct { handle: rawptr }
Stream :: struct { handle: rawptr, authenticated, failed: bool }
MAX_IO :: 64 * 1024

// Own the returned context and destroy it after its streams. OpenSSL allocations
// use its own allocator. Private keys remain file inputs and are never logged.
context_open :: proc(cert_file, key_file, ca_file: string) -> (Context, Status) {
	for name in ([3]string{cert_file, key_file, ca_file}) {
		if name == "" || strings.contains(name, "\x00") do return {}, .Invalid
	}
	cert := strings.clone_to_cstring(cert_file)
	key := strings.clone_to_cstring(key_file)
	ca := strings.clone_to_cstring(ca_file)
	defer delete(cert)
	defer delete(key)
	defer delete(ca)
	handle := new_context(cert, key, ca)
	if handle == nil do return {}, .Failed
	return Context{handle}, .Ready
}

context_close :: proc(ctx: ^Context) {
	if ctx == nil || ctx.handle == nil do return
	free_context(ctx.handle)
	ctx.handle = nil
}

// The caller owns the connected socket and must keep it nonblocking. The exact
// peer SAN comes from trusted configuration, never an unauthenticated hello.
// The eventual service must separately authorize cluster, node, role and epoch.
// The executable must ignore SIGPIPE before networking; this library never changes
// process-global signal policy. Keep that policy in force for the stream lifetime.
stream_open :: proc(ctx: ^Context, fd: posix.FD, peer_dns: string, role: Role) -> (Stream, Status) {
	if ctx == nil || ctx.handle == nil || len(peer_dns) == 0 || len(peer_dns) > 253 {
		return {}, .Invalid
	}
	for ch in peer_dns {
		if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '.') {
			return {}, .Invalid
		}
	}
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 || flags & c.int(posix.O_NONBLOCK) == 0 do return {}, .Invalid
	name := strings.clone_to_cstring(peer_dns)
	defer delete(name)
	handle := new_stream(ctx.handle, c.int(fd), name, role)
	if handle == nil do return {}, .Failed
	return Stream{handle = handle}, .Ready
}

// Poll the requested direction under the caller's absolute deadline. No SQL or
// protocol payload is permitted until this returns Ready. Calls are serialized
// per stream; OpenSSL's error queue is cleared and consumed on the same thread.
handshake :: proc(s: ^Stream) -> Status {
	if s == nil || s.handle == nil do return .Invalid
	if s.failed do return .Failed
	if s.authenticated do return .Ready
	status := do_handshake(s.handle)
	s.authenticated = status == .Ready
	s.failed = status == .Failed || status == .Closed
	return status
}

// On Want_Read/Want_Write retry the same operation and unchanged buffer. The
// caller must bound frames, connections and deadlines. A stream cannot be copied
// or used concurrently. Close the socket on EOF/failure; no silent reconnect.
read :: proc(s: ^Stream, bytes: []u8) -> (int, Status) { return transfer(s, bytes, false) }
write :: proc(s: ^Stream, bytes: []u8) -> (int, Status) { return transfer(s, bytes, true) }

@(private)
transfer :: proc(s: ^Stream, bytes: []u8, writing: bool) -> (int, Status) {
	if s == nil || s.handle == nil || !s.authenticated || len(bytes) == 0 || len(bytes) > MAX_IO {
		return 0, .Invalid
	}
	if s.failed do return 0, .Failed
	n, status := do_io(s.handle, bytes, writing)
	s.failed = status == .Failed || status == .Closed
	return n, status
}

// Abortive TLS teardown only. The caller closes the borrowed socket. Graceful
// close_notify handling belongs to the service lifecycle and is not supplied yet.
stream_close :: proc(s: ^Stream) {
	if s == nil || s.handle == nil do return
	free_stream(s.handle)
	s^ = {}
}

// Every allowed identity is administrator-configured. The authenticated matched
// SAN is then mapped to a role by the server, before any protocol input is used.
stream_accept :: proc(ctx: ^Context, fd: posix.FD, allowed: []string) -> (Stream, Status) {
	if len(allowed) == 0 || len(allowed) > 32 do return {}, .Invalid
	s, status := stream_open(ctx, fd, allowed[0], .Server)
	if status != .Ready do return {}, status
	for name in allowed[1:] {
		valid := len(name) > 0 && len(name) <= 253
		for ch in name {
			if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '.') {
				valid = false
			}
		}
		if !valid {
			stream_close(&s)
			return {}, .Invalid
		}
		cname := strings.clone_to_cstring(name)
		ok := add_peer(s.handle, cname)
		delete(cname)
		if !ok { stream_close(&s); return {}, .Failed }
	}
	return s, .Ready
}
