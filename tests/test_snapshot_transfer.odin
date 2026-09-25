package tests

import "core:encoding/base64"
import "core:os"
import "core:strings"
import "core:testing"
import sql "../src"
import durable "../src/durable"
import snapshot "../src/snapshot"
import service "../service"

@(test)
test_snapshot_transfer_rejects_misbinding_offset_and_corruption :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	seal := install_test_seal(t, c)
	s := new(service.Server)
	defer free(s)
	defer delete(s.transfer_buffer)
	defer service.snapshot_transfer_cancel(s)
	s.host = c.hosts[2]
	s.config.cluster, s.config.node = "test", 3
	peer := service.Connection{peer = 1, hello = true}
	packet := durable.Packet{value = seal.value}
	packet.env = {from = 1, to = 3, message = sql.Commit_Message(sql.Mutation){seal.slot, &packet.value}}
	receipt, ready := durable.snapshot_local_receipt(c.hosts[0])
	testing.expect(t, ready)
	candidate := snapshot.Candidate{receipt.key, receipt.image, receipt.bytes}
	encoded, encode_err := snapshot.candidate_encode(candidate, candidate.key)
	testing.expect(t, encode_err == .None)
	offer := service.Request{op = "snapshot_offer", protocol = 1, cluster = "test", node = 1,
		packet = service.wire_encode(&packet),
		receipt = base64.encode(encoded.bytes[:encoded.count], allocator = context.temp_allocator)}
	peer.peer = 2
	testing.expect(t, !service.receive_snapshot_offer(s, &peer, offer) && s.transfer == nil)
	peer.peer = 1
	testing.expect(t, service.receive_snapshot_offer(s, &peer, offer) && s.transfer != nil)
	if s.transfer == nil do return
	_, busy := durable.begin_snapshot(s.host, 0)
	testing.expect(t, busy == .Backpressure)
	path := strings.clone(s.transfer.path)
	defer delete(path)
	chunk := service.Request{op = "snapshot_chunk", node = 1, snapshot_prefix = candidate.key.prefix,
		snapshot_offset = 1}
	testing.expect(t, !service.receive_snapshot_chunk(s, &peer, chunk))
	testing.expect(t, s.transfer.received == 0 && s.host.engine.applied_through == 1)
	bytes, read_err := os.read_entire_file(c.hosts[0].snapshot.worker.image, context.allocator)
	defer delete(bytes)
	testing.expect(t, read_err == nil && len(bytes) < service.SNAPSHOT_CHUNK_BYTES)
	bytes[0] ~= 1
	chunk.snapshot_offset = 0
	chunk.receipt = base64.encode(bytes, allocator = context.temp_allocator)
	testing.expect(t, !service.receive_snapshot_chunk(s, &peer, chunk))
	testing.expect(t, s.transfer_error == "Snapshot_Checksum" && !s.transfer.complete)
	service.snapshot_transfer_cancel(s)
	testing.expect(t, !os.exists(path) && s.host.generation_base.key.prefix == 0 && !s.host.poisoned)
	testing.expect(t, !s.host.snapshot_busy)
}

@(test)
test_snapshot_offer_retries_until_receiver_fetches_and_slow_peer_stays_connected :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	next, err := durable.compact_store(c.hosts[0], "test")
	testing.expect(t, err == .None)
	if err != .None do return
	durable.close(c.hosts[0])
	c.hosts[0] = next
	s := new(service.Server)
	defer free(s)
	defer delete(s.transfer_buffer)
	s.host, s.config.cluster, s.config.node = next, "test", 1
	peer := &s.connections[0]
	peer.state, peer.peer, peer.hello = .Ready, 3, true
	defer for bytes in peer.out do if bytes != nil { delete(bytes) }
	next.snapshot_requests[2] = true
	service.send_snapshot_offers(s)
	testing.expect(t, peer.out_count == 1 && !peer.snapshot_sending)
	// A busy recipient may ignore an offer. A subsequent Learn must offer again.
	next.snapshot_requests[2] = true
	service.send_snapshot_offers(s)
	testing.expect(t, peer.out_count == 2 && !peer.snapshot_sending)
	peer.queued = service.MAX_QUEUED
	request := service.Request{node = 3, snapshot_prefix = next.generation_base.key.prefix}
	testing.expect(t, service.send_snapshot_chunk(s, peer, request))
	testing.expect(t, peer.snapshot_sending && peer.out_count == 2)
	next.snapshot_requests[2] = true
	service.send_snapshot_offers(s)
	testing.expect(t, !next.snapshot_requests[2] && peer.out_count == 2)
	// Congestion drops retransmittable Paxos packets instead of resetting TLS.
	peer.snapshot_sending = false
	testing.expect(t, durable.catch_up(next, 3) == .None)
	service.route_packets(s)
	testing.expect(t, peer.state == .Ready && peer.queued == service.MAX_QUEUED)
}
