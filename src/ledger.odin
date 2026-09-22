package sqlodin

import "base:intrinsics"

DEFAULT_WINDOW_SLOTS    :: 256
DEFAULT_CHUNK_SLOTS     :: 64
DEFAULT_MAX_MEMBERS     :: 7
MAX_SUPPORTED_MEMBERS   :: 65535

Cell_State :: enum u8 {
	Empty,
	Voted,
	Chosen,
}

// The trim anchor: every slot at or below `chosen_trim_slot` is chosen and has been
// materialized into the SQLite state image identified by `trim_id`.
Trim_Anchor :: struct {
	trim_id:          u64,
	chosen_trim_slot: Slot,
}

Ledger :: struct($Value: typeid, $WINDOW: int = DEFAULT_WINDOW_SLOTS)
	where intrinsics.type_is_comparable(Value) {
	promised:    Ballot,
	anchor:      Trim_Anchor,
	slot:        [WINDOW]Slot,
	promised_at: [WINDOW]Ballot,
	vote_ballot: [WINDOW]Ballot,
	state:       [WINDOW]Cell_State,
	value:       [WINDOW]Value,
	used:        Bit_Set(WINDOW),
	chosen:      Bit_Set(WINDOW),
}

// Durable records the host journals, in order.
Write_Promise :: struct {
	ballot: Ballot,
}

Write_Promise_At :: struct {
	ballot: Ballot,
	slot:   Slot,
}

Write_Vote :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	value:  ^Value,
}

Write_Chosen :: struct($Value: typeid) {
	slot:  Slot,
	value: ^Value,
}

Write_Trim :: Trim_Anchor

Write :: union($Value: typeid) {
	Write_Promise,
	Write_Promise_At,
	Write_Vote(Value),
	Write_Chosen(Value),
	Write_Trim,
}

// The effective promise for one cell: the greater of the global and per-decree promise.
ledger_promise_for :: #force_inline proc(
	l: ^Ledger($Value, $WINDOW),
	cell: int,
) -> Ballot {
	return max(l.promised, l.promised_at[cell])
}

// A cell that currently holds `slot`, or false.
ledger_cell :: #force_inline proc(
	l: ^Ledger($Value, $WINDOW),
	slot: Slot,
) -> (int, bool) {
	cell := cell_of(slot, WINDOW)
	return cell, l.slot[cell] == slot
}

ledger_vote_at :: proc(
	l: ^Ledger($Value, $WINDOW),
	slot: Slot,
) -> (Ballot, ^Value, bool) {
	if slot == 0 do return BALLOT_ZERO, nil, false
	cell, held := ledger_cell(l, slot)
	if !held || l.state[cell] != .Voted do return BALLOT_ZERO, nil, false
	return l.vote_ballot[cell], &l.value[cell], true
}

ledger_chosen_at :: proc(
	l: ^Ledger($Value, $WINDOW),
	slot: Slot,
) -> (^Value, bool) {
	if slot == 0 do return nil, false
	cell, held := ledger_cell(l, slot)
	if !held || l.state[cell] != .Chosen do return nil, false
	return &l.value[cell], true
}

ledger_is_chosen :: #force_inline proc(
	l: ^Ledger($Value, $WINDOW),
	slot: Slot,
) -> bool {
	cell, held := ledger_cell(l, slot)
	return held && l.state[cell] == .Chosen
}

// Retags a cell for `slot`, clearing everything but the value storage.
ledger_open :: #force_inline proc(
	l: ^Ledger($Value, $WINDOW),
	cell: int,
	slot: Slot,
) {
	l.slot[cell] = slot
	l.promised_at[cell] = BALLOT_ZERO
	l.vote_ballot[cell] = BALLOT_ZERO
	l.state[cell] = .Empty
	bit_set_remove(&l.used, cell)
	bit_set_remove(&l.chosen, cell)
}

ledger_claim :: proc(l: ^Ledger($Value, $WINDOW), slot: Slot) -> (int, bool) {
	cell := cell_of(slot, WINDOW)
	held := l.slot[cell]
	if held == slot do return cell, true
	closed := l.state[cell] == .Chosen || held <= l.anchor.chosen_trim_slot
	if held == 0 || (held < slot && closed) {
		ledger_open(l, cell, slot)
		return cell, true
	}
	return cell, false
}

ledger_record_vote :: #force_inline proc(
	l: ^Ledger($Value, $WINDOW),
	cell: int,
	ballot: Ballot,
	value: Value,
) {
	l.vote_ballot[cell] = ballot
	l.value[cell] = value
	l.state[cell] = .Voted
	bit_set_insert(&l.used, cell)
}

ledger_record_chosen :: #force_inline proc(
	l: ^Ledger($Value, $WINDOW),
	cell: int,
	value: Value,
) {
	l.value[cell] = value
	l.state[cell] = .Chosen
	bit_set_insert(&l.used, cell)
	bit_set_insert(&l.chosen, cell)
}

ledger_highest_ballot :: proc(l: ^Ledger($Value, $WINDOW)) -> Ballot {
	highest := l.promised
	for cell in 0..<WINDOW {
		highest = max(highest, l.promised_at[cell], l.vote_ballot[cell])
	}
	return highest
}

ledger_highest_used :: proc(l: ^Ledger($Value, $WINDOW)) -> Slot {
	highest: Slot
	cell, more := bit_set_next(l.used, 0)
	for more {
		highest = max(highest, l.slot[cell])
		cell, more = bit_set_next(l.used, cell + 1)
	}
	return highest
}

ledger_apply :: proc(l: ^Ledger($Value, $WINDOW), write: Write(Value)) -> Error {
	switch w in write {
	case Write_Promise:
		if w.ballot < l.promised do return .Promise_Regression
		l.promised = w.ballot
	case Write_Promise_At:
		if w.slot == 0 do return .Invalid_Slot
		cell, ok := ledger_claim(l, w.slot)
		if !ok do return .Window_Full
		if w.ballot < l.promised_at[cell] do return .Promise_Regression
		l.promised_at[cell] = w.ballot
	case Write_Vote(Value):
		if w.slot == 0 do return .Invalid_Slot
		if w.ballot < l.promised do return .Promise_Regression
		cell, ok := ledger_claim(l, w.slot)
		if !ok do return .Window_Full
		if w.ballot < l.promised_at[cell] do return .Promise_Regression
		val := w.value^
		if l.state[cell] == .Voted && l.vote_ballot[cell] == w.ballot && l.value[cell] != val {
			return .Conflicting_Value
		}
		if l.state[cell] == .Chosen && l.value[cell] != val do return .Conflicting_Commit
		l.promised_at[cell] = w.ballot
		if l.state[cell] != .Chosen do ledger_record_vote(l, cell, w.ballot, val)
	case Write_Chosen(Value):
		if w.slot == 0 do return .Invalid_Slot
		cell, ok := ledger_claim(l, w.slot)
		if !ok do return .None
		val := w.value^
		if l.state[cell] == .Chosen && l.value[cell] != val do return .Conflicting_Commit
		ledger_record_chosen(l, cell, val)
	case Write_Trim:
		if w.trim_id < l.anchor.trim_id || w.chosen_trim_slot < l.anchor.chosen_trim_slot {
			return .Trim_Regression
		}
		l.anchor = w
	}
	return .None
}
