package sqlodin

import "base:intrinsics"
import "core:container/small_array"
import "core:fmt"
import "core:os"

Durability_Gate :: enum {
	Enforced,
	Host_Managed,
}

// Caller-owned output of one consensus transition.
Effects :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
	$CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
	$GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
	writes:         small_array.Small_Array(2 * CHUNK_SLOTS + 1, Write(Value)),
	messages:       small_array.Small_Array(
		MAX_MEMBERS * CHUNK_SLOTS + 2 * MAX_MEMBERS + 1, Envelope(Value),
	),
	committed:      small_array.Small_Array(WINDOW_SLOTS + 1, Committed(Value)),
	writes_pending: bool,
}

host_order_violation :: proc(what: string) -> ! {
	fmt.eprintf(
		"-- DURABILITY ORDER VIOLATION --------------------------------------------------\n\n" +
		"%s.\n\n" +
		"Hint: Persist and sync pending writes before calling " +
		"effects_confirm_writes_durable(),\n" +
		"then transmit network messages and reset effects. Never confirm a failed write.\n",
		what,
	)
	os.exit(1)
}

effects_clear :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	e.writes.len = 0
	e.messages.len = 0
	e.committed.len = 0
	e.writes_pending = false
}

effects_init :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	effects_clear(e)
}

effects_reset :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	when G == .Enforced {
		if e.writes_pending {
			host_order_violation("reset discarded unconfirmed durable writes")
		}
	}
	effects_clear(e)
}

effects_confirm_writes_durable :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	e.writes_pending = false
}

effects_writes_slice :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) -> []Write(V) {
	return small_array.slice(&e.writes)
}

effects_messages_slice :: #force_inline proc(
	e: ^Effects($V, $M, $W, $C, $G),
) -> []Envelope(V) {
	when G == .Enforced {
		if e.writes_pending {
			host_order_violation("messages accessed before writes were confirmed durable")
		}
	}
	return small_array.slice(&e.messages)
}

effects_committed_slice :: #force_inline proc(
	e: ^Effects($V, $M, $W, $C, $G),
) -> []Committed(V) {
	return small_array.slice(&e.committed)
}

effects_add_write :: #force_inline proc(
	e: ^Effects($V, $M, $W, $C, $G),
	write: Write(V),
) {
	assert(e.writes.len < cap(e.writes.data), "Effects.writes buffer overrun")
	small_array.push_back(&e.writes, write)
	e.writes_pending = true
}

effects_add_message :: #force_inline proc(
	e: ^Effects($V, $M, $W, $C, $G),
	env: Envelope(V),
) {
	assert(e.messages.len < cap(e.messages.data), "Effects.messages buffer overrun")
	small_array.push_back(&e.messages, env)
}

effects_add_committed :: #force_inline proc(
	e: ^Effects($V, $M, $W, $C, $G),
	slot: Slot,
	value: ^V,
) {
	assert(e.committed.len < cap(e.committed.data), "Effects.committed buffer overrun")
	small_array.push_back(&e.committed, Committed(V){slot = slot, value = value})
}
