package sqlodin

import paxos "../deps/paxos-odin/src"

// Compatibility aliases: protocol types and transitions belong to the pinned upstream library.
Node_Id :: paxos.Node_Id
Slot :: paxos.Slot
Ballot :: paxos.Ballot
BALLOT_ROUND_BITS :: paxos.BALLOT_ROUND_BITS
ballot_make :: paxos.ballot_make
ballot_round :: paxos.ballot_round
ballot_priority :: paxos.ballot_priority
ballot_node :: paxos.ballot_node
cell_of :: paxos.cell_of
slot_add :: paxos.slot_add

Bit_Set :: paxos.Bit_Set
bit_set_insert :: paxos.bit_set_insert
bit_set_remove :: paxos.bit_set_remove
bit_set_contains :: paxos.bit_set_contains
bit_set_count :: paxos.bit_set_count
bit_set_reset :: paxos.bit_set_reset
bit_set_next :: paxos.bit_set_next
bit_set_last :: paxos.bit_set_last

Membership :: paxos.Membership
membership_init :: paxos.membership_init
membership_index_of :: paxos.membership_index_of
membership_contains :: paxos.membership_contains
membership_count :: paxos.membership_count
membership_get :: paxos.membership_get
membership_slice :: paxos.membership_slice
membership_read_quorum :: paxos.membership_read_quorum
membership_write_quorum :: paxos.membership_write_quorum

Ledger :: paxos.Ledger
Cell_State :: paxos.Cell_State
Trim_Anchor :: paxos.Trim_Anchor
Write_Promise :: paxos.Write_Promise
Write_Promise_At :: paxos.Write_Promise_At
Write_Vote :: paxos.Write_Vote
Write_Chosen :: paxos.Write_Chosen
Write_Trim :: paxos.Write_Trim
Write :: paxos.Write
ledger_apply :: paxos.ledger_apply
ledger_vote_at :: paxos.ledger_vote_at
ledger_chosen_at :: paxos.ledger_chosen_at
ledger_is_chosen :: paxos.ledger_is_chosen

Prepare_Scope :: paxos.Prepare_Scope
Prepare_Message :: paxos.Prepare_Message
Promise_Message :: paxos.Promise_Message
Promise_Range_Message :: paxos.Promise_Range_Message
Accept_Message :: paxos.Accept_Message
Accepted_Message :: paxos.Accepted_Message
Commit_Message :: paxos.Commit_Message
Learn_Message :: paxos.Learn_Message
Nack_Message :: paxos.Nack_Message
Heartbeat_Message :: paxos.Heartbeat_Message
Message :: paxos.Message
Envelope :: paxos.Envelope
Committed :: paxos.Committed
message_value :: paxos.message_value
Serve_Range_Request :: paxos.Serve_Range_Request
Host_Request :: paxos.Host_Request

Durability_Gate :: paxos.Durability_Gate
Effects :: paxos.Effects
effects_init :: paxos.effects_init
effects_reset :: paxos.effects_reset
effects_confirm_writes_durable :: paxos.effects_confirm_writes_durable
effects_writes_slice :: paxos.effects_writes_slice
effects_messages_slice :: paxos.effects_messages_slice
effects_committed_slice :: paxos.effects_committed_slice
effects_requests_slice :: paxos.effects_requests_slice
effects_requires_power_loss_barrier :: paxos.effects_requires_power_loss_barrier
effects_add_write :: paxos.effects_add_write
effects_add_message :: paxos.effects_add_message

DEFAULT_MAX_MEMBERS :: paxos.DEFAULT_MAX_MEMBERS
DEFAULT_WINDOW_SLOTS :: paxos.DEFAULT_WINDOW_SLOTS
DEFAULT_CHUNK_SLOTS :: paxos.DEFAULT_CHUNK_SLOTS
MAX_SUPPORTED_MEMBERS :: paxos.MAX_SUPPORTED_MEMBERS
Node_Options :: paxos.Node_Options
Role :: paxos.Role
node_propose :: paxos.node_propose
node_propose_batch :: paxos.node_propose_batch
node_step :: paxos.node_step
node_decided_through :: paxos.node_decided_through
node_ballot :: paxos.node_ballot
node_role :: paxos.node_role
node_advance_memory_floor :: paxos.node_advance_memory_floor
node_install_chosen_trim :: paxos.node_install_chosen_trim
node_begin_recovery :: paxos.node_begin_recovery
node_request_catch_up :: paxos.node_request_catch_up
node_reconnected :: paxos.node_reconnected
node_resubmits_dropped :: paxos.node_resubmits_dropped

Consensus_Error :: paxos.Error
MultiMaster_Node :: paxos.Node

// Force rotating ownership for SQLodin while preserving all upstream timer options.
node_init :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
	noop: V,
	options: Node_Options = {},
) -> Consensus_Error {
	opts := options
	opts.rotating_ownership = true
	paxos.node_init(node, id, membership, opts) or_return
	node.noop = noop
	return .None
}

node_restore :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
	ledger: Ledger(V, W),
	noop: V,
	floor: Slot = 0,
	options: Node_Options = {},
) -> Consensus_Error {
	opts := options
	opts.rotating_ownership = true
	paxos.node_restore(node, id, membership, ledger, floor, opts) or_return
	node.noop = noop
	return .None
}

node_tick :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
) -> Consensus_Error {
	noop, ok := node.noop.(V)
	if !ok do return .Missing_Noop
	return paxos.node_tick(node, noop, effects)
}

// Bounded ownership work; logical failure-detector clocks do not advance.
node_progress :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
) -> Consensus_Error {
	noop, ok := node.noop.(V)
	if !ok do return .Missing_Noop
	return paxos.node_progress(node, noop, effects)
}

node_own_next :: proc(node: ^MultiMaster_Node($V, $M, $W, $C, $G)) -> Slot {
	return node.own_next
}

node_owner_of :: proc(node: ^MultiMaster_Node($V, $M, $W, $C, $G), slot: Slot) -> Node_Id {
	return paxos.owner_of(node, slot)
}

// SOD 0005 M2/M5: learn an owner's round-zero value without its Commit. Call
// after stepping `env`, inside the same durable group. Round zero of a slot
// belongs to its owner alone, whose vote is durable before its Accept leaves.
// M2 (Mencius simple consensus): every revoker offers a reported vote or this
// same no-op, so an owner's no-op is the slot's only choosable value. M5: with
// a write quorum of two, this voter's own round-zero vote for the same value
// and the owner's vote are a quorum, chosen once this group is durable.
owner_fast_commit :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G), env: Envelope(V),
) -> (Envelope(V), bool) {
	accept, is_accept := env.message.(Accept_Message(V))
	if !is_accept || accept.value == nil || accept.slot == 0 || !node.ownership do return {}, false
	if ballot_round(accept.ballot) != 0 || ballot_node(accept.ballot) != env.from ||
	   paxos.owner_of(node, accept.slot) != env.from || env.from == node.id {
		return {}, false
	}
	commit := Envelope(V){from = env.from, to = env.to,
		message = Commit_Message(V){slot = accept.slot, value = accept.value}}
	if noop, ok := node.noop.(V); ok && accept.value^ == noop do return commit, true
	if membership_write_quorum(&node.membership) != 2 do return {}, false
	ballot, voted, ok := paxos.ledger_vote_at(&node.ledger, accept.slot)
	if !ok || ballot != accept.ballot || voted^ != accept.value^ do return {}, false
	return commit, true
}

node_highest_seen :: proc(node: ^MultiMaster_Node($V, $M, $W, $C, $G)) -> Slot {
	return node.highest_seen
}

effects_add_committed :: proc(
	e: ^Effects($V, $M, $W, $C, $G), slot: Slot, value: ^V,
) {
	paxos.effects_add_committed(e, Committed(V){slot = slot, value = value})
}

explain_error :: proc{explain_engine_error, paxos.explain_error}
