package service

import "core:fmt"
import "core:encoding/base64"
import snapshot "../src/snapshot"
import "core:time"
import sql "../src"
import durable "../src/durable"

snapshot_request_error :: proc(err: durable.Error) -> string {
	#partial switch err {
	case .Backpressure: return "Busy"
	case .Invalid: return "Unsupported"
	case: return "Storage"
	}
}

snapshot_prefix :: proc(s: ^Server) -> sql.Slot {
	return s.host.snapshot.prefix if s.host.snapshot != nil else 0
}

snapshot_error :: proc(s: ^Server) -> string {
	if s.transfer_error != "" do return s.transfer_error
	if s.maintenance_error != "" do return s.maintenance_error
	if s.host.snapshot != nil && durable.snapshot_worker_failed(s.host.snapshot) {
		return fmt.tprintf("%v", s.host.snapshot.worker.error)
	}
	return ""
}

drive_snapshots :: proc(s: ^Server) -> bool {
	if !snapshot_transfer_drive(s) do return false
	if !drive_maintenance(s) do return false
	err := durable.snapshot_progress(s.host, 0)
	if err != .None && err != .Backpressure { s.fatal = true; return false }
	if time.tick_since(s.last_snapshot_receipt) < time.Second do return true
	s.last_snapshot_receipt = time.tick_now()
	send_snapshot_offers(s)
	receipt, ready := durable.snapshot_local_receipt(s.host)
	if !ready do return true
	for &c in s.connections {
		if c.state != .Ready || !c.hello || c.peer == 0 || c.snapshot_sending do continue
		if !enqueue(&c, Request{op = "snapshot_receipt", cluster = s.config.cluster,
			protocol = PROTOCOL, node = receipt.voter,
			receipt = snapshot_encode_receipt(receipt)}) { connection_close(s, &c) }
	}
	return true
}

respond_snapshot_request :: proc(s: ^Server, c: ^Connection) -> bool {
	slot, err := durable.begin_snapshot(s.host, 0)
	if err != .None do return respond(s, c, snapshot_request_error(err))
	return enqueue(c, Response{status = "ok", cluster = s.config.cluster, node = s.config.node,
		protocol = PROTOCOL, snapshot_requested = slot})
}

snapshot_encode_receipt :: proc(receipt: snapshot.Receipt) -> string {
	candidate := snapshot.Candidate{receipt.key, receipt.image, receipt.bytes}
	encoded, err := snapshot.candidate_encode(candidate, receipt.key)
	if err != .None do return ""
	return base64.encode(encoded.bytes[:encoded.count], allocator = context.temp_allocator)
}

receive_snapshot_receipt :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	if r.node != c.peer do return false
	buffer: [snapshot.CANDIDATE_SIZE]u8
	bytes, decode_err := base64.decode_into_buf(buffer[:], r.receipt)
	if decode_err != nil do return false
	candidate, err := snapshot.candidate_decode_configuration(bytes, s.host.configuration,
		sql.engine_build_fingerprint())
	if err != .None do return false
	// A receipt can overtake recovery; periodic retransmission supplies it later.
	if s.host.snapshot == nil || candidate.key.prefix != s.host.snapshot.prefix do return true
	return durable.snapshot_receive_receipt(s.host, c.peer,
		snapshot.Receipt{c.peer, candidate.key, candidate.image, candidate.bytes})
}
