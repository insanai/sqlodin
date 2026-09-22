package sqlodin

import "base:intrinsics"

// A bounded set of small integers backed by Odin's native bit_set, one word per 64
// members. Memberships and window bitmaps use it; scans over a window walk words and
// count trailing zeros instead of touching every cell.

WORD_BITS :: 64
Word :: bit_set[0..<WORD_BITS]

Bit_Set :: struct($N: int) {
	words: [(N + WORD_BITS - 1) / WORD_BITS]Word,
}

// Inserts an index. Returns true when it was not present before.
bit_set_insert :: #force_inline proc(bs: ^Bit_Set($N), index: int) -> bool {
	w, b := index / WORD_BITS, index % WORD_BITS
	if b in bs.words[w] do return false
	bs.words[w] += {b}
	return true
}

bit_set_remove :: #force_inline proc(bs: ^Bit_Set($N), index: int) {
	bs.words[index / WORD_BITS] -= {index % WORD_BITS}
}

bit_set_contains :: #force_inline proc(bs: Bit_Set($N), index: int) -> bool {
	return (index % WORD_BITS) in bs.words[index / WORD_BITS]
}

bit_set_count :: proc(bs: Bit_Set($N)) -> int {
	total := 0
	for w in bs.words do total += card(w)
	return total
}

bit_set_reset :: #force_inline proc(bs: ^Bit_Set($N)) {
	bs^ = {}
}

// The smallest member at or after `from`, if any.
bit_set_next :: proc(bs: Bit_Set($N), from: int) -> (int, bool) {
	if from >= N do return 0, false
	w := from / WORD_BITS
	mask := transmute(u64)bs.words[w] & (max(u64) << uint(from % WORD_BITS))
	for {
		if mask != 0 {
			index := w * WORD_BITS + int(intrinsics.count_trailing_zeros(mask))
			return index, index < N
		}
		w += 1
		if w >= len(bs.words) do return 0, false
		mask = transmute(u64)bs.words[w]
	}
}

// The largest member, if any.
bit_set_last :: proc(bs: Bit_Set($N)) -> (int, bool) {
	for w := len(bs.words) - 1; w >= 0; w -= 1 {
		mask := transmute(u64)bs.words[w]
		if mask != 0 {
			return w * WORD_BITS + WORD_BITS - 1 - int(intrinsics.count_leading_zeros(mask)), true
		}
	}
	return 0, false
}
