package service

// Leave four slots for the maximum fixed peer set. Incoming TLS is not yet
// authenticated, so its separate bounded pool cannot consume those reserves.
// A hostile packet flood still requires network-level rate limiting; the same
// listener cannot identify a peer before its certificate has been verified.
incoming_admission_available :: proc(s: ^Server) -> bool {
	pending := 0
	for &c in s.connections {
		if c.state == .Unused || c.peer != 0 do continue
		if c.state != .Ready || c.admission_rejected do pending += 1
	}
	return pending < MAX_INCOMING_HANDSHAKES
}

client_admission_available :: proc(s: ^Server) -> bool {
	clients := 0
	for &c in s.connections {
		if c.state == .Ready && c.peer == 0 && !c.admission_rejected do clients += 1
	}
	return clients < MAX_CLIENT_CONNECTIONS
}

reject_client_admission :: proc(s: ^Server, c: ^Connection, sequence: u64) -> bool {
	c.value.request.sequence = sequence
	c.close_after_flush = true
	return respond(s, c, "Busy")
}
