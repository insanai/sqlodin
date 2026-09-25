// Fixed-membership snapshot certificate validation. This package does not install
// snapshots or authorize trimming: durable retention and a chosen seal are separate.
package snapshot

import sql ".."

MAX_VOTERS :: 5
Key :: struct {
	configuration: [32]u8,
	engine: [32]u8,
	logical_state: [32]u8,
	generation: u64,
	prefix: sql.Slot,
}

// The host creates a receipt only after verifying and syncing its retained image.
// The transport must bind voter to its authenticated identity. These are evidence
// records under the non-Byzantine contract, not signatures or proof of file I/O.
Receipt :: struct {
	voter: sql.Node_Id,
	key: Key,
	image: [32]u8,
	bytes: u64,
}
Certificate :: struct {
	key: Key,
	receipts: [MAX_VOTERS]Receipt,
	count: u8,
}
Error :: enum {
	None, Invalid_Membership, Invalid_Key, Invalid_Image, Wrong_Voter,
	Wrong_Key, Duplicate_Voter, No_Quorum, Invalid_Certificate,
}

key_valid :: proc(key: Key) -> bool {
	return key.generation > 0 && key.generation <= u64(max(i64)) &&
		key.prefix > 0 && key.prefix <= u64(max(i64)) &&
		key.configuration != [32]u8{} && key.engine != [32]u8{} && key.logical_state != [32]u8{}
}

@(private)
membership_valid :: proc(members: []sql.Node_Id) -> bool {
	if len(members) < 1 || len(members) > MAX_VOTERS do return false
	for voter, i in members {
		if voter == 0 || voter > 1023 do return false
		for prior in members[:i] do if prior == voter do return false
	}
	return true
}

// Every receipt must name this exact configuration/engine/prefix/state/generation.
// Physical images may differ across voters while representing the same logical
// state. Their individual file hashes remain part of the sealed certificate.
build :: proc(key: Key, members: []sql.Node_Id, receipts: []Receipt) -> (Certificate, Error) {
	if !membership_valid(members) do return {}, .Invalid_Membership
	if !key_valid(key) do return {}, .Invalid_Key
	if len(receipts) > len(members) do return {}, .Invalid_Certificate
	result := Certificate{key = key}
	for receipt in receipts {
		found := false
		for voter in members do if receipt.voter == voter { found = true; break }
		if !found do return {}, .Wrong_Voter
		if receipt.key != key do return {}, .Wrong_Key
		if receipt.bytes == 0 || receipt.bytes > u64(max(i64)) || receipt.image == ([32]u8{}) {
			return {}, .Invalid_Image
		}
		for prior in result.receipts[:result.count] {
			if prior.voter == receipt.voter do return {}, .Duplicate_Voter
		}
		// Canonical voter order makes the seal digest independent of arrival order.
		position := int(result.count)
		for position > 0 && result.receipts[position-1].voter > receipt.voter {
			result.receipts[position] = result.receipts[position-1]
			position -= 1
		}
		result.receipts[position] = receipt
		result.count += 1
	}
	if int(result.count) < len(members)/2 + 1 do return {}, .No_Quorum
	return result, .None
}

// Revalidate deserialized state before digesting or considering it for a seal.
// expected binds the caller's independently checked configuration and snapshot.
validate :: proc(certificate: ^Certificate, expected: Key, members: []sql.Node_Id) -> Error {
	if certificate == nil || int(certificate.count) > MAX_VOTERS do return .Invalid_Certificate
	if certificate.key != expected do return .Wrong_Key
	canonical, err := build(expected, members, certificate.receipts[:certificate.count])
	if err != .None do return err
	if canonical != certificate^ do return .Invalid_Certificate
	return .None
}
