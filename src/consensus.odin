package sqlodin

// Core consensus transitions: fast-path accepts, acknowledgements, commits,
// heartbeats, skips, and single message dispatch.

claim_live :: #force_inline proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	slot: Slot,
) -> (int, bool) {
	if slot <= node.memory_floor || slot - node.memory_floor > Slot(W) {
		return 0, false
	}
	l := &node.ledger
	cell := cell_of(slot, W)
	held := l.slot[cell]
	if held == slot do return cell, true
	if held == 0 || (held <= node.memory_floor && l.state[cell] == .Chosen) {
		ledger_open(l, cell, slot)
		return cell, true
	}
	return cell, false
}

// Releases every newly contiguous decision into effects.committed.
emit_contiguous :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
) {
	l := &node.ledger
	for node.delivered_through < max(Slot) {
		next := node.delivered_through + 1
		cell := cell_of(next, W)
		if l.slot[cell] != next || l.state[cell] != .Chosen do break
		effects_add_committed(effects, next, &l.value[cell])
		node.delivered_through = next
	}
}

broadcast_peers :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
	msg: Message(V),
) {
	for peer in membership_slice(&node.membership) {
		if peer != node.id {
			effects_add_message(effects, Envelope(V){
				from = node.id,
				to = peer,
				message = msg,
			})
		}
	}
}

broadcast_all :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
	msg: Message(V),
) {
	for peer in membership_slice(&node.membership) {
		effects_add_message(effects, Envelope(V){
			from = node.id,
			to = peer,
			message = msg,
		})
	}
}

send_accept :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	slot: Slot,
	ballot: Ballot,
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	l := &node.ledger
	cell, ok := claim_live(node, slot)
	if !ok do return .Window_Full
	if l.state[cell] == .Chosen do return .None

	node.lead_slot[cell] = slot
	node.lead_ballot[cell] = ballot
	node.acknowledgements[cell] = {}
	node.acknowledged[cell] = 0

	l.promised_at[cell] = max(l.promised_at[cell], ballot)
	ledger_record_vote(l, cell, ballot, value)
	effects_add_write(effects, Write_Vote(V){
		ballot = ballot,
		slot = slot,
		value = &l.value[cell],
	})

	if bit_set_insert(&node.acknowledgements[cell], node.self_index) {
		node.acknowledged[cell] += 1
	}

	if membership_write_quorum(&node.membership) == 1 {
		record_commit(node, slot, value, effects) or_return
	} else {
		broadcast_peers(node, effects, Accept_Message(V){
			ballot = ballot,
			slot = slot,
			value = &l.value[cell],
		})
	}
	return .None
}

record_commit :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	slot: Slot,
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	l := &node.ledger
	cell, ok := claim_live(node, slot)
	if !ok do return .Window_Full
	if l.state[cell] == .Chosen do return .None

	ledger_record_chosen(l, cell, value)
	effects_add_write(effects, Write_Chosen(V){
		slot = slot,
		value = &l.value[cell],
	})

	broadcast_peers(node, effects, Commit_Message(V){
		slot = slot,
		value = &l.value[cell],
	})

	emit_contiguous(node, effects)
	return .None
}

on_accept :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Accept_Message(V),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if msg.slot == 0 do return .Invalid_Slot
	l := &node.ledger
	if msg.slot <= l.anchor.chosen_trim_slot do return .None

	// Ballot round 0 belongs to the slot's owner alone.
	if ballot_round(msg.ballot) == 0 {
		if ballot_node(msg.ballot) != owner_of(node, msg.slot) do return .None
	}
	if msg.ballot < l.promised {
		effects_add_message(effects, Envelope(V){
			from = node.id,
			to = from,
			message = Nack_Message{
				rejected = msg.ballot,
				promised = l.promised,
				slot = msg.slot,
				decided_through = node.delivered_through,
			},
		})
		return .None
	}

	cell, ok := claim_live(node, msg.slot)
	if !ok do return .None
	node.highest_seen = max(node.highest_seen, msg.slot)

	if msg.ballot < l.promised_at[cell] {
		effects_add_message(effects, Envelope(V){
			from = node.id,
			to = from,
			message = Nack_Message{
				rejected = msg.ballot,
				promised = l.promised_at[cell],
				slot = msg.slot,
				decided_through = node.delivered_through,
			},
		})
		return .None
	}

	val := msg.value^
	l.promised_at[cell] = msg.ballot
	if l.state[cell] != .Chosen {
		ledger_record_vote(l, cell, msg.ballot, val)
		effects_add_write(effects, Write_Vote(V){
			ballot = msg.ballot,
			slot = msg.slot,
			value = &l.value[cell],
		})
	}

	effects_add_message(effects, Envelope(V){
		from = node.id,
		to = from,
		message = Accepted_Message{
			ballot = msg.ballot,
			slot = msg.slot,
			decided_through = node.delivered_through,
		},
	})
	return .None
}

on_accepted :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Accepted_Message,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	l := &node.ledger
	cell, held := ledger_cell(l, msg.slot)
	if !held || l.state[cell] != .Voted do return .None
	if node.lead_slot[cell] != msg.slot || node.lead_ballot[cell] != msg.ballot {
		return .None
	}

	sender_idx, found := membership_index_of(&node.membership, from)
	if !found do return .Not_Member

	if bit_set_insert(&node.acknowledgements[cell], sender_idx) {
		node.acknowledged[cell] += 1
		if int(node.acknowledged[cell]) >= membership_write_quorum(&node.membership) {
			record_commit(node, msg.slot, l.value[cell], effects) or_return
		}
	}
	return .None
}

on_commit :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	msg: Commit_Message(V),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if msg.slot == 0 do return .Invalid_Slot
	cell, ok := claim_live(node, msg.slot)
	if !ok do return .None
	l := &node.ledger
	if l.state[cell] == .Chosen do return .None

	val := msg.value^
	ledger_record_chosen(l, cell, val)
	effects_add_write(effects, Write_Chosen(V){
		slot = msg.slot,
		value = &l.value[cell],
	})

	node.highest_seen = max(node.highest_seen, msg.slot)
	emit_contiguous(node, effects)
	return .None
}

on_skip :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	msg: Skip_Message,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if msg.slot == 0 do return .Invalid_Slot
	cell, ok := claim_live(node, msg.slot)
	if !ok do return .None
	l := &node.ledger
	if l.state[cell] == .Chosen do return .None

	ledger_record_chosen(l, cell, node.noop)
	effects_add_write(effects, Write_Chosen(V){
		slot = msg.slot,
		value = &l.value[cell],
	})

	node.highest_seen = max(node.highest_seen, msg.slot)
	emit_contiguous(node, effects)
	return .None
}

on_heartbeat :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Heartbeat_Message,
	effects: ^Effects(V, M, W, C, G),
) {
	node.highest_seen = max(node.highest_seen, msg.decided_through)
	if msg.decided_through > node.delivered_through {
		effects_add_message(effects, Envelope(V){
			from = node.id,
			to = from,
			message = Learn_Message{
				from_slot = node.delivered_through + 1,
				count = u32(C),
			},
		})
	}
}

on_learn :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Learn_Message,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if msg.from_slot == 0 do return .Invalid_Slot
	l := &node.ledger
	cell, chosen := bit_set_next(l.chosen, 0)
	for chosen {
		slot := l.slot[cell]
		if slot >= msg.from_slot && slot < msg.from_slot + Slot(msg.count) {
			effects_add_message(effects, Envelope(V){
				from = node.id,
				to = from,
				message = Commit_Message(V){
					slot = slot,
					value = &l.value[cell],
				},
			})
		}
		cell, chosen = bit_set_next(l.chosen, cell + 1)
	}
	return .None
}

node_step :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	envelope: Envelope(V),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if envelope.to != node.id do return .Wrong_Recipient
	if !membership_contains(&node.membership, envelope.from) do return .Not_Member

	switch msg in envelope.message {
	case Accept_Message(V):
		return on_accept(node, envelope.from, msg, effects)
	case Accepted_Message:
		return on_accepted(node, envelope.from, msg, effects)
	case Commit_Message(V):
		return on_commit(node, msg, effects)
	case Skip_Message:
		return on_skip(node, msg, effects)
	case Heartbeat_Message:
		on_heartbeat(node, envelope.from, msg, effects)
		return .None
	case Learn_Message:
		return on_learn(node, envelope.from, msg, effects)
	case Prepare_Message, Promise_Message(V), Promise_Range_Message,
	     Nack_Message:
		return .None
	}
	return .None
}
