package tests

import "core:testing"
import service "../service"

@(test)
test_client_admission_keeps_peer_and_handshake_reserves :: proc(t: ^testing.T) {
	s := new(service.Server)
	defer free(s)
	for i in 0..<service.MAX_CLIENT_CONNECTIONS {
		testing.expect(t, service.client_admission_available(s))
		s.connections[i].state = .Ready
	}
	testing.expect(t, !service.client_admission_available(s))
	for i in service.MAX_CLIENT_CONNECTIONS..<28 {
		testing.expect(t, service.incoming_admission_available(s))
		s.connections[i].state = .Handshake
	}
	testing.expect(t, !service.incoming_admission_available(s))
	for i in 28..<32 { s.connections[i].state = .Ready; s.connections[i].peer = u16(i) }
	// Authentication as a peer releases handshake capacity, never client capacity.
	s.connections[24].state = .Ready
	s.connections[24].peer = 2
	testing.expect(t, service.incoming_admission_available(s))
	testing.expect(t, !service.client_admission_available(s))
	// A rejected client occupies the bounded pending pool until its response drains.
	s.connections[24].peer = 0
	s.connections[24].admission_rejected = true
	testing.expect(t, !service.incoming_admission_available(s))
	s.connections[0] = {}
	testing.expect(t, service.client_admission_available(s))
}
