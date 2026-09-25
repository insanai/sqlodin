package durable

import "core:container/queue"
import sql ".."
import "core:time"

// Authenticated peers may request a bounded chosen suffix even when this node
// has no volatile leader hint after restore. Decisions still pass through step.
catch_up :: proc(h: ^Host, peer: sql.Node_Id) -> Error {
	if h.poisoned do return .Poisoned
	if peer == h.node.id || !sql.membership_contains(&h.node.membership, peer) do return .Invalid
	if queue.len(h.packets) >= 1024 do return .Backpressure
	if h.engine.applied_through == max(sql.Slot) do return .Invalid
	if sql.node_request_catch_up(&h.node, peer, h.engine.applied_through + 1,
		&h.effects) != .None { return .Invalid }
	return finish(h)
}

// The complete pinned library owns resubmission priority and skip budgeting.
// Commit its effects through the same durability boundary as step and tick.
progress :: proc(h: ^Host) -> Error {
	if h.poisoned do return .Poisoned
	if queue.len(h.packets) >= 1024 do return .Backpressure
	if sql.node_progress(&h.node, &h.effects) != .None do return poison(h)
	return finish(h)
}

Recovery_Stats :: struct { integrity, ledger, application: time.Duration }

recover_measured :: proc(h: ^Host, cancel: ^u32 = nil) -> bool {
	started := time.tick_now()
	if h.engine.applied_through < h.genesis.prefix do return false
	h.node.ledger.anchor = {h.genesis.prefix, h.genesis.prefix}
	if !load_generation_base(h) || !recover_ledger(h, cancel) ||
		!validate_generation_seal(h) { return false }
	h.recovery.ledger = time.tick_since(started)
	started = time.tick_now()
	if !recover_application(h, cancel) do return false
	h.recovery.application = time.tick_since(started)
	return true
}
