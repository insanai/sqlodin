package sqlodin

// Rotating slot ownership protocol (multi-master log partitioning).
//
// The slot line is partitioned round-robin across cluster members: member i
// owns every slot s where (s - 1) mod N == i. The ballot space is partitioned
// such that round 0 belongs exclusively to the owner. Any member receives writes
// locally and commits them in 1 RTT on the fast path without leader redirection.

owner_of :: #force_inline proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	slot: Slot,
) -> Node_Id {
	count := Slot(membership_count(&node.membership))
	return membership_get(&node.membership, int((slot - 1) % count))
}

ownership_ballot :: #force_inline proc(owner: Node_Id) -> Ballot {
	return ballot_make(0, 0, owner)
}

own_slot_from :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	from: Slot,
) -> Slot {
	count := Slot(membership_count(&node.membership))
	mine := Slot(node.self_index) + 1
	if from <= mine do return mine
	offset := (from - mine) % count
	return from if offset == 0 else slot_add(from, count - offset)
}

own_slot_probe :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	from: Slot,
) -> (slot: Slot, err: Error) {
	l := &node.ledger
	mine := ownership_ballot(node.id)
	if node.memory_floor == max(Slot) do return 0, .Global_Slot_Exhausted
	slot = from
	if slot <= node.memory_floor do slot = own_slot_from(node, node.memory_floor + 1)
	for {
		if slot == max(Slot) do return 0, .Global_Slot_Exhausted
		if slot - node.memory_floor > Slot(W) do return 0, .Window_Full
		cell := cell_of(slot, W)
		occupant := l.slot[cell]
		switch {
		case occupant == slot:
			if l.state[cell] != .Chosen && ledger_promise_for(l, cell) <= mine {
				return slot, .None
			}
		case occupant == 0 || (occupant <= node.memory_floor && l.state[cell] == .Chosen):
			if l.promised <= mine do return slot, .None
		case:
			return 0, .Window_Full
		}
		slot = own_slot_from(node, slot + 1)
	}
}

next_usable_own_slot :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
) -> (slot: Slot, err: Error) {
	slot = own_slot_probe(node, node.own_next) or_return
	node.own_next = slot
	return slot, .None
}

// Proposes a value in this node's next pre-owned slot (1 RTT fast path).
propose_owned :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> (slot: Slot, err: Error) {
	slot = next_usable_own_slot(node) or_return
	err = send_accept(node, slot, ownership_ballot(node.id), value, effects)
	err or_return
	node.own_next = own_slot_from(node, slot + 1)
	node.highest_seen = max(node.highest_seen, slot)
	return slot, .None
}

// Broadcasts skip messages for idle owned slots below the highest cluster frontier.
skip_idle_slots :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
) -> (sent: int, err: Error) {
	for node.own_next <= node.highest_seen && sent < 8 {
		slot := node.own_next
		cell, ok := claim_live(node, slot)
		if !ok do break
		ledger_record_chosen(&node.ledger, cell, node.noop)
		effects_add_write(effects, Write_Chosen(V){
			slot = slot,
			value = &node.ledger.value[cell],
		})
		broadcast_peers(node, effects, Skip_Message{
			slot = slot,
			ballot = ownership_ballot(node.id),
			owner = node.id,
			decided_through = node.delivered_through,
		})
		node.own_next = own_slot_from(node, slot + 1)
		sent += 1
	}
	emit_contiguous(node, effects)
	return sent, .None
}

node_tick :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	node.heartbeat_ticks += 1
	if node.heartbeat_ticks >= node.options.heartbeat_interval_ticks {
		node.heartbeat_ticks = 0
		broadcast_peers(node, effects, Heartbeat_Message{
			ballot = node.ballot,
			decided_through = node.delivered_through,
		})
	}

	// Advance idle slots to unblock contiguous release
	skip_idle_slots(node, effects)

	// Check for stalled peers
	if node.delivered_through < node.highest_seen {
		node.stall_ticks += 1
	} else {
		node.stall_ticks = 0
	}
	return .None
}

node_propose :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> (slot: Slot, err: Error) {
	effects_reset(effects)
	return propose_owned(node, value, effects)
}
