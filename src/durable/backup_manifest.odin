package durable

import sql ".."

BACKUP_DOMAIN :: "SQLodin/application-backup/v1"
BACKUP_MANIFEST_SIZE :: len(BACKUP_DOMAIN)+96+16+2+128+1+2*MAX_MEMBERS+32
Backup_Manifest :: struct {
	engine, configuration, image: [32]u8,
	prefix: sql.Slot,
	bytes: u64,
	cluster: [128]u8,
	cluster_len: u16,
	members: [MAX_MEMBERS]sql.Node_Id,
	member_count: u8,
}

backup_manifest_encode :: proc(m: Backup_Manifest) -> (out: [BACKUP_MANIFEST_SIZE]u8) {
	copy(out[:], BACKUP_DOMAIN)
	position := len(BACKUP_DOMAIN)
	for hash in ([3][32]u8{m.engine, m.configuration, m.image}) {
		for byte, i in hash do out[position+i] = byte
		position += 32
	}
	for word in ([2]u64{m.prefix, m.bytes}) {
		backup_put_word(out[:], &position, word, 8)
	}
	backup_put_word(out[:], &position, u64(m.cluster_len), 2)
	for byte, i in m.cluster do out[position+i] = byte
	position += 128
	out[position] = m.member_count; position += 1
	for member in m.members do backup_put_word(out[:], &position, u64(member), 2)
	hash := digest(out[:position])
	copy(out[position:], hash[:])
	return
}

backup_manifest_decode :: proc(bytes: []u8) -> (m: Backup_Manifest, valid: bool) {
	if len(bytes) != BACKUP_MANIFEST_SIZE || string(bytes[:len(BACKUP_DOMAIN)]) != BACKUP_DOMAIN {
		return
	}
	hash := digest(bytes[:len(bytes)-32])
	for byte, i in hash do if byte != bytes[len(bytes)-32+i] { return }
	position := len(BACKUP_DOMAIN)
	copy(m.engine[:], bytes[position:position+32]); position += 32
	copy(m.configuration[:], bytes[position:position+32]); position += 32
	copy(m.image[:], bytes[position:position+32]); position += 32
	m.prefix = backup_get_word(bytes, &position, 8)
	m.bytes = backup_get_word(bytes, &position, 8)
	m.cluster_len = u16(backup_get_word(bytes, &position, 2))
	copy(m.cluster[:], bytes[position:position+128]); position += 128
	m.member_count = bytes[position]; position += 1
	for &member in m.members do member = sql.Node_Id(backup_get_word(bytes, &position, 2))
	if m.engine != sql.engine_build_fingerprint() || m.configuration == ([32]u8{}) ||
		m.image == ([32]u8{}) || m.bytes < 4096 || m.bytes > 128*1024*1024*1024 ||
		m.prefix > u64(max(i64)) || m.cluster_len == 0 || m.cluster_len > 128 ||
		m.member_count == 0 || m.member_count > MAX_MEMBERS { return m, false }
	for byte, i in m.cluster {
		if i < int(m.cluster_len) {
			if byte == 0 || byte == ';' do return m, false
		} else if byte != 0 { return m, false }
	}
	membership: sql.Membership(MAX_MEMBERS)
	if sql.membership_init(&membership, m.members[:m.member_count]) != .None do return m, false
	for member in m.members[m.member_count:] do if member != 0 { return m, false }
	return m, true
}

@(private)
backup_put_word :: proc(bytes: []u8, position: ^int, word: u64, size: int) {
	for i in 0..<size do bytes[position^+i] = u8(word >> uint(8*i))
	position^ += size
}

@(private)
backup_get_word :: proc(bytes: []u8, position: ^int, size: int) -> (word: u64) {
	for i in 0..<size do word |= u64(bytes[position^+i]) << uint(8*i)
	position^ += size
	return
}
