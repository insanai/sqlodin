package service

import "core:c"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

address :: proc(text: string) -> (addr: posix.sockaddr_in, ok: bool) {
	i := strings.last_index(text, ":")
	if i <= 0 do return
	port, valid := strconv.parse_int(text[i + 1:])
	if !valid || port <= 0 || port > 65535 do return
	host := strings.clone_to_cstring(text[:i])
	defer delete(host)
	addr.sin_family = .INET
	addr.sin_port = u16be(port)
	when ODIN_OS == .Darwin do addr.sin_len = u8(size_of(addr))
	ok = posix.inet_pton(.INET, host, &addr.sin_addr) == .SUCCESS
	return
}

nonblocking :: proc(fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 || posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK)) != 0 do return false
	yes: c.int = 1
	return posix.setsockopt(fd, posix.IPPROTO_TCP, posix.Sock_Option(posix.TCP_NODELAY),
		&yes, size_of(yes)) == nil
}

socket_open :: proc(endpoint: string, listening: bool) -> posix.FD {
	addr, valid := address(endpoint)
	if !valid do return -1
	fd := posix.socket(.INET, .STREAM)
	if fd < 0 do return -1
	good := false
	defer if !good do posix.close(fd)
	if !nonblocking(fd) do return -1
	yes: c.int = 1
	if posix.setsockopt(fd, posix.SOL_SOCKET, .REUSEADDR, &yes, size_of(yes)) != nil do return -1
	if listening {
		if posix.bind(fd, cast(^posix.sockaddr)&addr, size_of(addr)) != nil ||
		   posix.listen(fd, 32) != nil { return -1 }
	} else {
		// A nonblocking connect is completed through poll + SO_ERROR in the event loop.
		_ = posix.connect(fd, cast(^posix.sockaddr)&addr, size_of(addr))
	}
	good = true
	return fd
}

connected :: proc(fd: posix.FD) -> (ready, failed: bool) {
	p := posix.pollfd{fd = fd, events = {.OUT}}
	if posix.poll(&p, 1, 0) <= 0 do return
	err: c.int
	n := posix.socklen_t(size_of(err))
	failed = posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &err, &n) != nil || err != 0
	ready = !failed
	return
}
