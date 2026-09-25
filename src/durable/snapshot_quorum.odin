package durable

import "core:sync"
import sql ".."
import snapshot "../snapshot"

snapshot_local_receipt :: proc(h: ^Host) -> (snapshot.Receipt, bool) {
	s := h.snapshot
	if s == nil || s.worker == nil || sync.atomic_load(&s.worker.done) == 0 ||
		s.worker.error != .None { return {}, false }
	return s.worker.receipt, true
}

// The service supplies authenticated_peer from its mTLS connection, never from
// the frame's claimed voter field. A duplicate receipt cannot add another vote.
snapshot_receive_receipt :: proc(
	h: ^Host, authenticated_peer: sql.Node_Id, receipt: snapshot.Receipt,
) -> bool {
	s := h.snapshot
	if s == nil || receipt.voter != authenticated_peer ||
		receipt.key.configuration != h.configuration ||
		receipt.key.engine != sql.engine_build_fingerprint() ||
		receipt.key.prefix != s.prefix || receipt.key.generation != s.prefix ||
		!snapshot.key_valid(receipt.key) || receipt.bytes == 0 || receipt.bytes > u64(max(i64)) ||
		receipt.image == ([32]u8{}) { return false }
	for member, i in sql.membership_slice(&h.node.membership) {
		if member != authenticated_peer do continue
		if s.receipts[i].voter != 0 && s.receipts[i] != receipt do return false
		s.receipts[i] = receipt
		return true
	}
	return false
}

snapshot_progress :: proc(h: ^Host, timestamp_ms: u64) -> Error {
	if h.poisoned do return .Poisoned
	s := h.snapshot
	if s == nil do return .None
	if snapshot_worker_failed(s) do return poison(h)
	if s.pending_token != 0 && s.pending_slot <= h.engine.applied_through do s.pending_token = 0
	if s.worker == nil || h.snapshot_sealed.key.prefix >= s.prefix do return .None
	local, ready := snapshot_local_receipt(h)
	if !ready do return .None
	if !snapshot_receive_receipt(h, h.node.id, local) do return poison(h)
	if s.seal_slot != 0 {
		_, complete, err := outcome(h, s.seal_slot, &s.seal_value)
		if err != .None do return err
		if complete || h.engine.applied_through < s.seal_slot do return .None
		s.seal_slot = 0 // A competing value displaced this proposal; retry its certificate.
	}
	receipts: [MAX_MEMBERS]snapshot.Receipt
	count := 0
	for receipt in s.receipts {
		if receipt.voter != 0 && receipt.key == local.key {
			receipts[count] = receipt; count += 1
		}
	}
	members := sql.membership_slice(&h.node.membership)
	certificate, err := snapshot.build(local.key, members, receipts[:count])
	if err == .No_Quorum do return .None
	if err != .None do return poison(h)
	encoded, encode_err := snapshot.encode(&certificate, local.key, members)
	if encode_err != .None do return poison(h)
	token := next_id(h, timestamp_ms) or_return
	value := sql.mutation_make_skip(h.node.id, 0)
	value.primary_key = token
	copy(value.sql_bytes[:], SNAPSHOT_SEAL)
	copy(value.sql_bytes[len(SNAPSHOT_SEAL):], encoded.bytes[:encoded.count])
	value.sql_len = u16(len(SNAPSHOT_SEAL) + encoded.count)
	s.seal_value = value
	slot, proposal_err := propose_internal(h, value)
	if proposal_err != .None do return proposal_err
	s.seal_slot = slot
	return .None
}
