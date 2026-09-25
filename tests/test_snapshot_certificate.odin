package tests

import "core:testing"
import snapshot "../src/snapshot"
import sql "../src"

@(test)
test_snapshot_certificate_requires_matching_distinct_quorum :: proc(t: ^testing.T) {
	members := [3]sql.Node_Id{1,2,3}
	key := snapshot.Key{generation = 1, prefix = 100}
	key.configuration[0], key.engine[0], key.logical_state[0] = 1, 2, 3
	receipts := [2]snapshot.Receipt{{1, key, {}, 4096}, {2, key, {}, 8192}}
	receipts[0].image[0], receipts[1].image[0] = 4, 5
	cert, err := snapshot.build(key, members[:], receipts[:])
	testing.expect(t, err == .None)
	hash: [32]u8
	hash, err = snapshot.digest(&cert, key, members[:])
	testing.expect(t, err == .None && hash != [32]u8{})
	reversed := [2]snapshot.Receipt{receipts[1], receipts[0]}
	other, other_err := snapshot.build(key, members[:], reversed[:])
	testing.expect(t, other_err == .None && other == cert)
	_, err = snapshot.build(key, members[:], receipts[:1])
	testing.expect(t, err == .No_Quorum)
	reversed[1] = reversed[0]
	_, err = snapshot.build(key, members[:], reversed[:])
	testing.expect(t, err == .Duplicate_Voter)
	reversed = receipts
	reversed[1].voter = 4
	_, err = snapshot.build(key, members[:], reversed[:])
	testing.expect(t, err == .Wrong_Voter)
	for field in 0..<5 {
		reversed = receipts
		switch field {
		case 0: reversed[1].key.configuration[0] += 1
		case 1: reversed[1].key.engine[0] += 1
		case 2: reversed[1].key.logical_state[0] += 1
		case 3: reversed[1].key.generation += 1
		case 4: reversed[1].key.prefix += 1
		}
		_, err = snapshot.build(key, members[:], reversed[:])
		testing.expect(t, err == .Wrong_Key)
	}
	// A parsed certificate cannot smuggle entries outside its declared length.
	other = cert
	other.receipts[2] = receipts[0]
	testing.expect(t, snapshot.validate(&other, key, members[:]) == .Invalid_Certificate)
	other = cert
	other.count = 255
	testing.expect(t, snapshot.validate(&other, key, members[:]) == .Invalid_Certificate)
	other = cert
	other.receipts[0].image[0] += 1
	changed, changed_err := snapshot.digest(&other, key, members[:])
	testing.expect(t, changed_err == .None && changed != hash)
	wrong := key
	wrong.prefix += 1
	testing.expect(t, snapshot.validate(&cert, wrong, members[:]) == .Wrong_Key)
	for size in 1..=snapshot.MAX_VOTERS {
		voters: [snapshot.MAX_VOTERS]sql.Node_Id
		evidence: [snapshot.MAX_VOTERS]snapshot.Receipt
		for i in 0..<size {
			voters[i] = sql.Node_Id(i+1)
			evidence[i] = receipts[0]
			evidence[i].voter = voters[i]
		}
		quorum := size/2+1
		_, err = snapshot.build(key, voters[:size], evidence[:quorum])
		testing.expect(t, err == .None)
		_, err = snapshot.build(key, voters[:size], evidence[:quorum-1])
		testing.expect(t, err == .No_Quorum)
	}
}

@(test)
test_snapshot_certificate_codec_rejects_malformed_frames :: proc(t: ^testing.T) {
	members := [3]sql.Node_Id{1,2,3}
	key := snapshot.Key{generation = 1, prefix = 100}
	key.configuration[0], key.engine[0], key.logical_state[0] = 1, 2, 3
	receipts := [2]snapshot.Receipt{{1, key, {}, 4096}, {2, key, {}, 8192}}
	receipts[0].image[0], receipts[1].image[0] = 4, 5
	cert, err := snapshot.build(key, members[:], receipts[:])
	testing.expect(t, err == .None)
	encoded, encode_err := snapshot.encode(&cert, key, members[:])
	testing.expect(t, encode_err == .None)
	decoded, decode_err := snapshot.decode(encoded.bytes[:encoded.count], key, members[:])
	testing.expect(t, decode_err == .None && decoded == cert)
	for length in 0..<encoded.count {
		decoded, decode_err = snapshot.decode(encoded.bytes[:length], key, members[:])
		testing.expect(t, decode_err != .None && decoded == (snapshot.Certificate{}))
	}
	_, decode_err = snapshot.decode(encoded.bytes[:encoded.count+1], key, members[:])
	testing.expect(t, decode_err == .Invalid_Certificate)
	original, digest_err := snapshot.digest(&cert, key, members[:])
	testing.expect(t, digest_err == .None)
	// Independent Python struct.pack('<Q') / hashlib vector fixes the wire ABI.
	expected := [32]u8{
		44,210,156,223,97,88,48,92,213,151,9,209,16,85,192,212,
		96,39,66,194,192,115,116,64,217,187,119,140,80,222,111,241,
	}
	testing.expect(t, encoded.count == 247 && original == expected)
	// Every one-bit change either fails validation or changes the sealed digest.
	for position in 0..<encoded.count {
		for bit in 0..<8 {
			changed := encoded
			changed.bytes[position] ~= u8(1 << uint(bit))
			decoded, decode_err = snapshot.decode(changed.bytes[:changed.count], key, members[:])
			if decode_err != .None do continue
			actual, actual_err := snapshot.digest(&decoded, key, members[:])
			testing.expect(t, actual_err == .None && actual != original)
		}
	}
}
