package durable

import sql ".."
import "core:path/filepath"
import "core:strings"
import "core:c"
import "core:crypto/sha2"
import db "../sqlite"
import snapshot "../snapshot"

// A generation starts at a certified application prefix. The complete seal must
// also occur as a chosen value in its retained suffix; a numeric trim ID alone
// can never establish this base. The local database identity remains voter-local.
load_generation_base :: proc(h: ^Host) -> bool {
	if h.consensus == nil do return true
	count, ok := migration_integer(h.consensus,
		"SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_generation_base'")
	if !ok do return false
	if count == 0 do return true
	stmt, prepared := prepare(h,
		"SELECT seal,certificate,image,name,previous,digest FROM _sqlodin_generation_base WHERE id=1")
	if !prepared do return false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_step(stmt) != db.ROW do return false
	seal := db.sqlite3_column_int64(stmt, 0)
	certificate, err := snapshot.decode_configuration(column_blob(stmt, 1), h.configuration,
		sql.engine_build_fingerprint(), sql.membership_slice(&h.node.membership))
	if err != .None || seal <= 0 || u64(seal) <= certificate.key.prefix ||
		certificate.key.generation != certificate.key.prefix ||
		certificate.key.prefix < h.genesis.prefix ||
		h.engine.applied_through < certificate.key.prefix {
		return false
	}
	image, image_err := snapshot.candidate_decode(column_blob(stmt, 2), certificate.key)
	name := string(db.sqlite3_column_text(stmt, 3))
	previous := string(db.sqlite3_column_text(stmt, 4))
	if image_err != .None || !generation_image_name_valid(name) ||
		previous != "" && !valid_generation_name(previous) { return false }
	expected := generation_descriptor_digest(u64(seal), column_blob(stmt, 1),
		column_blob(stmt, 2), name, previous)
	actual := column_blob(stmt, 5)
	if len(actual) != len(expected) do return false
	for byte, i in actual do if byte != expected[i] { return false }
	h.generation_image, h.generation_image_name = image, strings.clone(name)
	h.generation_previous = strings.clone(previous)
	if db.sqlite3_step(stmt) != db.DONE do return false
	h.generation_base, h.generation_seal = certificate, sql.Slot(seal)
	h.snapshot_sealed, h.snapshot_seal_slot = certificate, sql.Slot(seal)
	h.node.ledger.anchor = {certificate.key.generation, certificate.key.prefix}
	return true
}

store_generation_base :: proc(h: ^Host, certificate: snapshot.Certificate, seal: sql.Slot,
	image: snapshot.Candidate, image_path, previous: string) -> bool {
	copy := certificate
	encoded, err := snapshot.encode(&copy, certificate.key, sql.membership_slice(&h.node.membership))
	if err != .None || seal <= certificate.key.prefix do return false
	image_bytes, image_err := snapshot.candidate_encode(image, certificate.key)
	name := filepath.base(image_path)
	if image_err != .None || !generation_image_name_valid(name) ||
		previous != "" && !valid_generation_name(previous) { return false }
	if !db.exec(h.consensus, "CREATE TABLE _sqlodin_generation_base(" +
		"id INTEGER PRIMARY KEY CHECK(id=1),seal INTEGER NOT NULL,certificate BLOB NOT NULL," +
		"image BLOB NOT NULL,name TEXT NOT NULL,previous TEXT NOT NULL,digest BLOB NOT NULL)") {
		return false
	}
	stmt, ok := prepare(h, "INSERT INTO _sqlodin_generation_base VALUES(1,?,?,?,?,?,?)")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	hash := generation_descriptor_digest(seal, encoded.bytes[:encoded.count],
		image_bytes.bytes[:image_bytes.count], name, previous)
	previous_text := cstring("") if previous == "" else cstring(raw_data(previous))
	return db.sqlite3_bind_int64(stmt, 1, i64(seal)) == db.OK &&
		bind_blob(stmt, 2, encoded.bytes[:encoded.count]) &&
		bind_blob(stmt, 3, image_bytes.bytes[:image_bytes.count]) &&
		db.sqlite3_bind_text(stmt, 4, cstring(raw_data(name)), c.int(len(name)), nil) == db.OK &&
		db.sqlite3_bind_text(stmt, 5, previous_text, c.int(len(previous)), nil) == db.OK &&
		bind_blob(stmt, 6, hash[:]) &&
		db.sqlite3_step(stmt) == db.DONE
}

@(private)
generation_descriptor_digest :: proc(seal: u64, certificate, image: []u8,
	name, previous: string) -> (result: [32]u8) {
	h: sha2.Context_256
	sha2.init_256(&h)
	bytes: [8]u8
	for i in 0..<8 do bytes[i] = u8(seal >> uint(8*i))
	sha2.update(&h, bytes[:])
	sha2.update(&h, certificate)
	sha2.update(&h, image)
	sha2.update(&h, transmute([]u8)name)
	sha2.update(&h, []u8{0})
	sha2.update(&h, transmute([]u8)previous)
	sha2.final(&h, result[:])
	return
}

validate_generation_seal :: proc(h: ^Host) -> bool {
	if h.generation_base.key.prefix == 0 do return true
	value, found, ok := chosen(h, h.generation_seal)
	if !ok || !found || snapshot_control(&value) != 2 do return false
	certificate, err := snapshot.decode_configuration(value.sql_bytes[len(SNAPSHOT_SEAL):value.sql_len],
		h.configuration, sql.engine_build_fingerprint(), sql.membership_slice(&h.node.membership))
	return err == .None && certificate == h.generation_base
}

@(private)
generation_image_name_valid :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > 128 || name == "." || name == ".." do return false
	for ch in name {
		if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '.') {
			return false
		}
	}
	return true
}
