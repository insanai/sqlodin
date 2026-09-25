package durable

import "core:fmt"
import db "../sqlite"

GENESIS_DOMAIN :: "SQLodin/restored-genesis/v1"

@(private)
genesis_digest :: proc(manifest: Backup_Manifest) -> [32]u8 {
	encoded := backup_manifest_encode(manifest)
	bytes: [len(GENESIS_DOMAIN)+BACKUP_MANIFEST_SIZE]u8
	copy(bytes[:], GENESIS_DOMAIN)
	copy(bytes[len(GENESIS_DOMAIN):], encoded[:])
	return digest(bytes[:])
}

// Genesis is a shared initial-state descriptor in a fresh namespace, never a
// certificate to reset an existing acceptor. Its digest participates in identity.
@(private)
load_genesis :: proc(h: ^Host, cluster: string) -> bool {
	if h.consensus == nil do return true
	count, valid := migration_integer(h.consensus,
		"SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_genesis'")
	if !valid do return false
	if count == 0 do return true
	stmt, ok := prepare(h, "SELECT backup,digest FROM _sqlodin_genesis WHERE id=1")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	if db.sqlite3_step(stmt) != db.ROW do return false
	manifest, decoded := backup_manifest_decode(column_blob(stmt, 0))
	if !decoded || string(manifest.cluster[:manifest.cluster_len]) == cluster do return false
	hash, actual := genesis_digest(manifest), column_blob(stmt, 1)
	if len(actual) != len(hash) do return false
	for byte, i in hash do if byte != actual[i] { return false }
	if db.sqlite3_step(stmt) != db.DONE do return false
	h.genesis, h.genesis_hash = manifest, hash
	return true
}

@(private)
store_genesis :: proc(h: ^Host) -> bool {
	if h.genesis_hash == ([32]u8{}) do return true
	if h.genesis_hash != genesis_digest(h.genesis) do return false
	if !db.exec(h.consensus, "CREATE TABLE _sqlodin_genesis(" +
		"id INTEGER PRIMARY KEY CHECK(id=1),backup BLOB NOT NULL,digest BLOB NOT NULL)") {
		return false
	}
	stmt, ok := prepare(h, "INSERT INTO _sqlodin_genesis VALUES(1,?,?)")
	if !ok do return false
	defer db.sqlite3_finalize(stmt)
	encoded := backup_manifest_encode(h.genesis)
	return bind_blob(stmt, 1, encoded[:]) && bind_blob(stmt, 2, h.genesis_hash[:]) &&
		db.sqlite3_step(stmt) == db.DONE
}

@(private)
genesis_identity :: proc(h: ^Host, identity: string) -> string {
	return fmt.aprintf("%s;genesis=%x", identity, h.genesis_hash)
}
