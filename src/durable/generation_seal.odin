package durable

import sql ".."
import snapshot "../snapshot"
import db "../sqlite"

// Transport attests that an authenticated voter learned this chosen value, just
// as for a normal Commit_Message. The full certificate must independently match
// this acceptor's fixed configuration and engine. It never supplies local votes.
Generation_Seal :: struct {
	certificate: snapshot.Certificate,
	slot: sql.Slot,
	value: sql.Mutation,
}

generation_seal_valid :: proc(h: ^Host, seal: ^Generation_Seal) -> bool {
	if seal == nil || snapshot_control(&seal.value) != 2 ||
		seal.slot <= seal.certificate.key.prefix || seal.slot > u64(max(i64)) ||
		seal.certificate.key.generation != seal.certificate.key.prefix { return false }
	actual, err := snapshot.decode_configuration(
		seal.value.sql_bytes[len(SNAPSHOT_SEAL):seal.value.sql_len], h.configuration,
		sql.engine_build_fingerprint(), sql.membership_slice(&h.node.membership))
	return err == .None && actual == seal.certificate
}

@(private)
generation_record_seal :: proc(h: ^Host, seal: ^Generation_Seal) -> bool {
	value, found, ok := chosen(h, seal.slot)
	if !ok do return false
	if found do return value == seal.value
	if !db.begin_tx(h.consensus) do return false
	defer db.rollback_tx(h.consensus)
	record := Record{kind = 4, slot = seal.slot, value = seal.value}
	return persist_record(h, &record) && db.commit_tx(h.consensus)
}
