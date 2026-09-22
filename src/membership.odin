package sqlodin

import "core:container/small_array"
import "core:slice"

// The fixed voting membership of one cluster configuration with its quorum sizes.
// `members` is sorted by id whatever order the host listed them in, so every node
// derives the same stable index per member (and, under rotating ownership, the same
// owner per slot) and a lookup in a large membership is a binary search. Quorums
// satisfy B2: any phase-one quorum and any phase-two quorum intersect because
// read + write > count.
Membership :: struct($MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS) {
	members:           small_array.Small_Array(MAX_MEMBERS, Node_Id),
	read_quorum_size:  int,
	write_quorum_size: int,
}

LINEAR_LOOKUP_LIMIT :: 8

// Validates and installs a membership. Zero overrides select majorities.
membership_init :: proc(
	m: ^Membership($MAX_MEMBERS),
	node_ids: []Node_Id,
	read_quorum_override: int = 0,
	write_quorum_override: int = 0,
) -> Error {
	#assert(MAX_MEMBERS > 0 && MAX_MEMBERS <= MAX_SUPPORTED_MEMBERS,
		"Invalid member capacity. Hint: Choose MAX_MEMBERS in 1..=65535.")
	if len(node_ids) == 0 do return .Empty_Membership
	if len(node_ids) > MAX_MEMBERS do return .Too_Many_Members

	// Build a candidate so validation errors leave the caller's membership intact.
	validated: Membership(MAX_MEMBERS)
	for id in node_ids {
		if id == 0 do return .Invalid_Node_Id
		small_array.push_back(&validated.members, id)
	}
	total := len(node_ids)
	slice.sort(validated.members.data[:total])
	for i in 1..<total {
		if validated.members.data[i - 1] == validated.members.data[i] {
			return .Duplicate_Node_Id
		}
	}

	majority := total / 2 + 1
	read := read_quorum_override if read_quorum_override != 0 else majority
	write := write_quorum_override if write_quorum_override != 0 else majority
	if read <= 0 || read > total do return .Invalid_Read_Quorum
	if write <= 0 || write > total do return .Invalid_Write_Quorum
	if read + write <= total do return .Non_Intersecting_Quorums
	validated.read_quorum_size, validated.write_quorum_size = read, write
	m^ = validated
	return .None
}

// The stable index of `id`, or false. Linear for small memberships, binary search above
// LINEAR_LOOKUP_LIMIT members.
membership_index_of :: #force_inline proc(
	m: ^Membership($MAX_MEMBERS),
	id: Node_Id,
) -> (int, bool) {
	count := m.members.len
	if count <= LINEAR_LOOKUP_LIMIT {
		for i in 0..<count {
			if m.members.data[i] == id do return i, true
		}
		return -1, false
	}
	low, high := 0, count
	for low < high {
		mid := (low + high) / 2
		switch {
		case m.members.data[mid] == id: return mid, true
		case m.members.data[mid] < id:  low = mid + 1
		case:                           high = mid
		}
	}
	return -1, false
}

membership_contains :: #force_inline proc(
	m: ^Membership($MAX_MEMBERS),
	id: Node_Id,
) -> bool {
	_, found := membership_index_of(m, id)
	return found
}

membership_count :: #force_inline proc(m: ^Membership($MAX_MEMBERS)) -> int {
	return m.members.len
}

// The member at a stable index.
membership_get :: #force_inline proc(
	m: ^Membership($MAX_MEMBERS),
	index: int,
) -> Node_Id {
	return m.members.data[index]
}

membership_slice :: proc(m: ^Membership($MAX_MEMBERS)) -> []Node_Id {
	return small_array.slice(&m.members)
}

membership_read_quorum :: #force_inline proc(
	m: ^Membership($MAX_MEMBERS),
) -> int {
	return m.read_quorum_size
}

membership_write_quorum :: #force_inline proc(
	m: ^Membership($MAX_MEMBERS),
) -> int {
	return m.write_quorum_size
}
