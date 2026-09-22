package sqlodin

import "base:intrinsics"

DEFAULT_ELECTION_TIMEOUT_TICKS  :: 10
DEFAULT_HEARTBEAT_INTERVAL_TICKS :: 3
DEFAULT_RESEND_INTERVAL_TICKS   :: 10
DEFAULT_STALL_TIMEOUT_TICKS     :: 15

Role :: enum u8 {
	Follower,
	Candidate,
	Preparing,
	Owner,
}

Node_Options :: struct {
	priority:                 u8,
	election_timeout_ticks:   int,
	heartbeat_interval_ticks: int,
	resend_interval_ticks:    int,
	stall_timeout_ticks:      int,
}

MultiMaster_Node :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
	$CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
	$GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
	id:                     Node_Id,
	self_index:             int,
	role:                   Role,
	ballot:                 Ballot,
	membership:             Membership(MAX_MEMBERS),
	options:                Node_Options,
	ledger:                 Ledger(Value, WINDOW_SLOTS),

	memory_floor:           Slot,
	delivered_through:      Slot,
	highest_seen:           Slot,
	highest_observed_round: u64,

	// Phase 2 volatile state
	lead_slot:              [WINDOW_SLOTS]Slot,
	lead_ballot:            [WINDOW_SLOTS]Ballot,
	acknowledgements:       [WINDOW_SLOTS]Bit_Set(MAX_MEMBERS),
	acknowledged:           [WINDOW_SLOTS]u32,

	// Multi-master rotating slot state
	own_next:               Slot,
	stall_ticks:            int,
	election_ticks:         int,
	heartbeat_ticks:        int,
	resend_ticks:           int,
	peer_resend_cursor:     [MAX_MEMBERS]int,
	resubmits_dropped:      u64,
	noop:                   Value,
}

node_init :: proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
	noop: V,
	options: Node_Options = {},
) -> Error {
	#assert(M > 0 && M <= MAX_SUPPORTED_MEMBERS,
		"Invalid member capacity. Hint: Choose MAX_MEMBERS in 1..=65535.")
	#assert((W & (W - 1)) == 0 && W > 0,
		"WINDOW_SLOTS must be a power of two. Hint: Choose 64, 128, 256, 512, etc.")
	#assert(C > 0 && C <= W,
		"CHUNK_SLOTS must be in 1..=WINDOW_SLOTS. Hint: Choose CHUNK_SLOTS <= WINDOW_SLOTS.")

	if id == 0 do return .Invalid_Node_Id
	node^ = {}
	node.id = id
	node.membership = membership
	idx, found := membership_index_of(&node.membership, id)
	if !found do return .Not_Member
	node.self_index = idx
	node.role = .Owner
	node.noop = noop

	opts := options
	if opts.election_timeout_ticks == 0 {
		opts.election_timeout_ticks = DEFAULT_ELECTION_TIMEOUT_TICKS
	}
	if opts.heartbeat_interval_ticks == 0 {
		opts.heartbeat_interval_ticks = DEFAULT_HEARTBEAT_INTERVAL_TICKS
	}
	if opts.resend_interval_ticks == 0 {
		opts.resend_interval_ticks = DEFAULT_RESEND_INTERVAL_TICKS
	}
	if opts.stall_timeout_ticks == 0 {
		opts.stall_timeout_ticks = DEFAULT_STALL_TIMEOUT_TICKS
	}
	node.options = opts

	// First owned slot: 1-based index corresponding to self_index + 1
	node.own_next = Slot(node.self_index + 1)
	node.ballot = ballot_make(0, 0, id)
	return .None
}

node_role :: #force_inline proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
) -> Role {
	return node.role
}

node_ballot :: #force_inline proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
) -> Ballot {
	return node.ballot
}

node_decided_through :: #force_inline proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
) -> Slot {
	return node.delivered_through
}

node_own_next :: #force_inline proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
) -> Slot {
	return node.own_next
}

node_highest_seen :: #force_inline proc(
	node: ^MultiMaster_Node($V, $M, $W, $C, $G),
) -> Slot {
	return node.highest_seen
}
