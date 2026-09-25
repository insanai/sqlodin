package snapshot

import "core:crypto/sha2"
import sql ".."

DOMAIN :: "SQLodin/snapshot-certificate/v1"
HEADER_SIZE :: len(DOMAIN) + 96 + 24
RECEIPT_SIZE :: 48
ENCODED_CAPACITY :: HEADER_SIZE + MAX_VOTERS * RECEIPT_SIZE
Encoding :: struct { bytes: [ENCODED_CAPACITY]u8, count: int }

@(private)
put_word :: proc(out: ^Encoding, word: u64) {
	for i in 0..<8 { out.bytes[out.count] = u8(word >> uint(8*i)); out.count += 1 }
}

@(private)
put_hash :: proc(out: ^Encoding, hash: [32]u8) {
	for byte in hash { out.bytes[out.count] = byte; out.count += 1 }
}

// Fixed, versioned little-endian representation, independent of Odin layout.
encode :: proc(certificate: ^Certificate, expected: Key, members: []sql.Node_Id) -> (Encoding, Error) {
	if err := validate(certificate, expected, members); err != .None do return {}, err
	out: Encoding
	copy(out.bytes[:], DOMAIN)
	out.count = len(DOMAIN)
	for hash in ([3][32]u8{expected.configuration, expected.engine, expected.logical_state}) {
		put_hash(&out, hash)
	}
	for word in ([3]u64{expected.generation, expected.prefix, u64(certificate.count)}) {
		put_word(&out, word)
	}
	for receipt in certificate.receipts[:certificate.count] {
		put_word(&out, u64(receipt.voter))
		put_word(&out, receipt.bytes)
		put_hash(&out, receipt.image)
	}
	return out, .None
}

@(private)
get_word :: proc(bytes: []u8, offset: int) -> (word: u64) {
	for i in 0..<8 do word |= u64(bytes[offset+i]) << uint(8*i)
	return
}

// Check the entire framing before reading any receipt. Rejected input never
// produces a partial certificate. Unknown versions and trailing bytes fail closed.
decode :: proc(bytes: []u8, expected: Key, members: []sql.Node_Id) -> (Certificate, Error) {
	if len(bytes) < HEADER_SIZE || len(bytes) > ENCODED_CAPACITY do return {}, .Invalid_Certificate
	if string(bytes[:len(DOMAIN)]) != DOMAIN do return {}, .Invalid_Certificate
	key: Key
	pos := len(DOMAIN)
	copy(key.configuration[:], bytes[pos:pos+32]); pos += 32
	copy(key.engine[:], bytes[pos:pos+32]); pos += 32
	copy(key.logical_state[:], bytes[pos:pos+32]); pos += 32
	key.generation = get_word(bytes, pos); pos += 8
	key.prefix = get_word(bytes, pos); pos += 8
	count := get_word(bytes, pos); pos += 8
	if count > MAX_VOTERS || len(bytes) != HEADER_SIZE + int(count)*RECEIPT_SIZE {
		return {}, .Invalid_Certificate
	}
	certificate := Certificate{key = key, count = u8(count)}
	for &receipt in certificate.receipts[:int(count)] {
		voter := get_word(bytes, pos); pos += 8
		if voter > 1023 do return {}, .Wrong_Voter
		receipt.voter, receipt.key = sql.Node_Id(voter), key
		receipt.bytes = get_word(bytes, pos); pos += 8
		copy(receipt.image[:], bytes[pos:pos+32]); pos += 32
	}
	if err := validate(&certificate, expected, members); err != .None do return {}, err
	return certificate, .None
}

// Publication must bind this full digest to its chosen seal, not truncate it to
// upstream's numeric trim ID. This function alone never certifies storage I/O.
digest :: proc(certificate: ^Certificate, expected: Key, members: []sql.Node_Id) -> ([32]u8, Error) {
	out, err := encode(certificate, expected, members)
	if err != .None do return {}, err
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, out.bytes[:out.count])
	result: [32]u8
	sha2.final(&ctx, result[:])
	return result, .None
}

// Validate a quorum certificate for a known configuration/engine when the caller
// does not hold a local image at that historical prefix. Logical equivalence is
// attested by the distinct durable receipts, under the non-Byzantine contract.
decode_configuration :: proc(
	bytes: []u8, configuration, engine: [32]u8, members: []sql.Node_Id,
) -> (Certificate, Error) {
	if len(bytes) < HEADER_SIZE || len(bytes) > ENCODED_CAPACITY ||
		string(bytes[:len(DOMAIN)]) != DOMAIN { return {}, .Invalid_Certificate }
	key := Key{configuration = configuration, engine = engine}
	position := len(DOMAIN) + 64
	copy(key.logical_state[:], bytes[position:position+32]); position += 32
	key.generation = get_word(bytes, position); position += 8
	key.prefix = get_word(bytes, position)
	return decode(bytes, key, members)
}
