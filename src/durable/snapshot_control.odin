package durable

import "core:strings"
import sql ".."
import snapshot "../snapshot"

SNAPSHOT_BARRIER :: "SQLodin/snapshot-barrier/v1"
SNAPSHOT_SEAL :: "SQLodin/snapshot-seal/v1"

// Host-only control records use uniquely reserved no-op identities. Their full
// payload participates in upstream value equality and the existing journal codec.
// Public SQL admission cannot submit a no-op with a nonzero primary key.
snapshot_control :: proc(value: ^sql.Mutation) -> int {
	if value.kind != .Skip || value.primary_key == 0 || int(value.sql_len) > sql.MAX_SQL_LEN do return 0
	bytes := string(value.sql_bytes[:value.sql_len])
	if bytes == SNAPSHOT_BARRIER do return 1
	if strings.has_prefix(bytes, SNAPSHOT_SEAL) do return 2
	return 0
}

begin_snapshot :: proc(h: ^Host, timestamp_ms: u64) -> (slot: sql.Slot, err: Error) {
	if h.poisoned do return 0, .Poisoned
	if h.snapshot_busy do return 0, .Backpressure
	s := h.snapshot
	if s == nil do return 0, .Invalid
	if !snapshot_space_available(h) do return 0, .Backpressure
	if s.pending_token != 0 || snapshot_worker_running(s) ||
		s.worker != nil && h.snapshot_sealed.key.prefix < s.prefix &&
		!snapshot_worker_failed(s) {
		return 0, .Backpressure
	}
	token := next_id(h, timestamp_ms) or_return
	value := sql.mutation_make_skip(h.node.id, 0)
	value.primary_key, value.sql_len = token, u16(len(SNAPSHOT_BARRIER))
	copy(value.sql_bytes[:], SNAPSHOT_BARRIER)
	s.pending_token = token
	slot, err = propose_internal(h, value)
	s.pending_slot = slot
	if err != .None do s.pending_token = 0
	return slot, err
}

// Split application groups at the ordered barrier. Pin its exact durable SQL
// prefix before applying another entry; copying/verifying then belongs to a worker.
apply_host_entries :: proc(h: ^Host, entries: []sql.Committed(sql.Mutation)) -> bool {
	first := 0
	for entry, i in entries {
		kind := snapshot_control(entry.value)
		if kind == 0 do continue
		if sql.engine_apply_outcomes(&h.engine, entries[first:i]) != .None do return false
		fresh := entry.slot > h.engine.applied_through
		if sql.engine_apply_outcomes(&h.engine, entries[i:i+1]) != .None do return false
		if kind == 1 && fresh && h.snapshot != nil do snapshot_pin(h, entry.slot)
		if kind == 2 && !snapshot_observe_seal(h, entry.slot, entry.value) do return false
		first = i+1
	}
	return sql.engine_apply_outcomes(&h.engine, entries[first:]) == .None
}

snapshot_observe_seal :: proc(h: ^Host, slot: sql.Slot, value: ^sql.Mutation) -> bool {
	if snapshot_control(value) != 2 do return true
	if h.consensus == nil do return false
	bytes := value.sql_bytes[len(SNAPSHOT_SEAL):value.sql_len]
	certificate, err := snapshot.decode_configuration(bytes, h.configuration,
		sql.engine_build_fingerprint(), sql.membership_slice(&h.node.membership))
	if err != .None || certificate.key.generation != certificate.key.prefix ||
		certificate.key.prefix >= slot { return false }
	if certificate.key.prefix > h.snapshot_sealed.key.prefix {
		h.snapshot_sealed, h.snapshot_seal_slot = certificate, slot
	}
	return true
}
