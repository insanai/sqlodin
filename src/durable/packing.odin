package durable

// Format 4 losslessly packs zero runs in the existing logical-field encoding.
// Every inactive tail and floating-point bit survives: Paxos value equality is
// unchanged. This reduces journal bytes, not the in-memory Mutation footprint.
PACKED_CAPACITY :: 6 + 2 * WIRE_CAPACITY

pack_record :: proc(source, output: []u8) -> (packed: []u8, ok: bool) {
	if len(source) > WIRE_CAPACITY || len(output) < 6 do return nil, false
	output[0], output[1] = 0x53, 4
	for i in 0..<4 do output[2 + i] = u8(u32(len(source)) >> uint(8 * i))
	written := 6
	for start := 0; start < len(source); {
		zero := source[start] == 0
		end := start + 1
		for end < len(source) && end - start < 128 && (source[end] == 0) == zero do end += 1
		count := end - start
		needed := 1 if zero else count + 1
		if needed > len(output) - written do return nil, false
		output[written] = u8(count - 1)
		written += 1
		if !zero {
			output[written - 1] |= 0x80
			copy(output[written:written + count], source[start:end])
			written += count
		}
		start = end
	}
	return output[:written], true
}

unpack_record :: proc(source, output: []u8) -> (size: int, ok: bool) {
	if len(source) < 6 || source[0] != 0x53 || source[1] != 4 do return 0, false
	for i in 0..<4 do size |= int(source[2 + i]) << uint(8 * i)
	if size > WIRE_CAPACITY || size > len(output) do return 0, false
	written, cursor := 0, 6
	for cursor < len(source) {
		tag := source[cursor]
		cursor += 1
		count := int(tag & 0x7f) + 1
		if count > size - written do return 0, false
		if tag & 0x80 != 0 {
			if count > len(source) - cursor do return 0, false
			copy(output[written:written + count], source[cursor:cursor + count])
			cursor += count
		} else {
			for &b in output[written:written + count] do b = 0
		}
		written += count
	}
	return size, written == size
}
