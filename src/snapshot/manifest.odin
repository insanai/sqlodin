// An immutable candidate-image description. It is not a certificate or CURRENT
// generation pointer, and cannot authorize installing or trimming any voter state.
package snapshot

import "core:crypto/sha2"

CANDIDATE_DOMAIN :: "SQLodin/image-candidate/v1"
CANDIDATE_SIZE :: len(CANDIDATE_DOMAIN) + 96 + 16 + 32 + 8 + 32
#assert(CANDIDATE_SIZE <= ENCODED_CAPACITY)
Candidate :: struct { key: Key, image: [32]u8, bytes: u64 }

candidate_from_copy :: proc(job: ^Image_Copy, key: Key) -> (Candidate, Error) {
	if job == nil || job.phase != .Copied || job.error != .None do return {}, .Invalid_Image
	if job.prefix != key.prefix do return {}, .Wrong_Key
	result := Candidate{key, job.hash, job.bytes}
	if err := candidate_validate(result, key); err != .None do return {}, err
	return result, .None
}

candidate_validate :: proc(candidate: Candidate, expected: Key) -> Error {
	if !key_valid(expected) do return .Invalid_Key
	if candidate.key != expected do return .Wrong_Key
	if candidate.image == ([32]u8{}) || candidate.bytes == 0 || candidate.bytes > u64(max(i64)) {
		return .Invalid_Image
	}
	return .None
}

candidate_encode :: proc(candidate: Candidate, expected: Key) -> (Encoding, Error) {
	if err := candidate_validate(candidate, expected); err != .None do return {}, err
	out: Encoding
	copy(out.bytes[:], CANDIDATE_DOMAIN)
	out.count = len(CANDIDATE_DOMAIN)
	put_hash(&out, expected.configuration)
	put_hash(&out, expected.engine)
	put_hash(&out, expected.logical_state)
	put_word(&out, expected.generation)
	put_word(&out, expected.prefix)
	put_hash(&out, candidate.image)
	put_word(&out, candidate.bytes)
	put_hash(&out, manifest_hash(out.bytes[:out.count]))
	return out, .None
}

candidate_decode :: proc(bytes: []u8, expected: Key) -> (Candidate, Error) {
	if len(bytes) != CANDIDATE_SIZE || string(bytes[:len(CANDIDATE_DOMAIN)]) != CANDIDATE_DOMAIN {
		return {}, .Invalid_Image
	}
	checksum := manifest_hash(bytes[:len(bytes)-32])
	for byte, i in checksum do if bytes[len(bytes)-32+i] != byte { return {}, .Invalid_Image }
	result: Candidate
	pos := len(CANDIDATE_DOMAIN)
	copy(result.key.configuration[:], bytes[pos:pos+32]); pos += 32
	copy(result.key.engine[:], bytes[pos:pos+32]); pos += 32
	copy(result.key.logical_state[:], bytes[pos:pos+32]); pos += 32
	result.key.generation = get_word(bytes, pos); pos += 8
	result.key.prefix = get_word(bytes, pos); pos += 8
	copy(result.image[:], bytes[pos:pos+32]); pos += 32
	result.bytes = get_word(bytes, pos)
	if err := candidate_validate(result, expected); err != .None do return {}, err
	return result, .None
}

@(private)
manifest_hash :: proc(bytes: []u8) -> (result: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, bytes)
	sha2.final(&ctx, result[:])
	return
}

// Decode peer candidate metadata bound to this independently known configuration
// and engine. This validates framing/identity, not the existence of its image.
candidate_decode_configuration :: proc(
	bytes: []u8, configuration, engine: [32]u8,
) -> (Candidate, Error) {
	if len(bytes) != CANDIDATE_SIZE || string(bytes[:len(CANDIDATE_DOMAIN)]) != CANDIDATE_DOMAIN {
		return {}, .Invalid_Image
	}
	key := Key{configuration = configuration, engine = engine}
	position := len(CANDIDATE_DOMAIN)+64
	copy(key.logical_state[:], bytes[position:position+32]); position += 32
	key.generation = get_word(bytes, position); position += 8
	key.prefix = get_word(bytes, position)
	return candidate_decode(bytes, key)
}
