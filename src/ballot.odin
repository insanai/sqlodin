package sqlodin

// Stable identity of one member. Zero is reserved as a sentinel.
Node_Id :: u16

// One-based position in the global decree log. Zero means "no slot".
Slot :: u64

// A ballot is one packed 64-bit integer:
//   bits 63..24  round      (40 bits, the campaign counter; round 0 is reserved for
//                            slot owners under rotating ownership fast path)
//   bits 23..16  priority   (8 bits, breaks ties between rounds)
//   bits 15..0   node       (16 bits, the proposer; makes every ballot unique)
Ballot :: distinct u64

BALLOT_ZERO       :: Ballot(0)
BALLOT_ROUND_BITS :: 40
MAX_ROUND         :: u64(1) << BALLOT_ROUND_BITS - 1

ballot_make :: #force_inline proc(round: u64, priority: u8, node: Node_Id) -> Ballot {
	return Ballot(round << 24 | u64(priority) << 16 | u64(node))
}

ballot_round :: #force_inline proc(b: Ballot) -> u64 {
	return u64(b) >> 24
}

ballot_priority :: #force_inline proc(b: Ballot) -> u8 {
	return u8(u64(b) >> 16)
}

ballot_node :: #force_inline proc(b: Ballot) -> Node_Id {
	return Node_Id(u64(b))
}

// The window index of a slot. WINDOW is a power of two, so this is one mask.
cell_of :: #force_inline proc(slot: Slot, $WINDOW: int) -> int {
	return int((slot - 1) & Slot(WINDOW - 1))
}

// Adds without wrapping past the last slot.
slot_add :: #force_inline proc(slot, offset: Slot) -> Slot {
	return slot + min(offset, max(Slot) - slot)
}
