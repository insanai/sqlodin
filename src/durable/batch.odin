package durable

import "core:container/queue"
import sql ".."
import paxos "../../deps/paxos-odin/src"

// Submit up to CHUNK independent values in one upstream transition. The complete
// input is validated before admission; caller-owned slots receive proposal IDs,
// not acknowledgements. finish persists all vote effects before sending packets.
// Application outcomes may share a bounded outer commit while preserving each
// request's deferred constraints and ROLLBACK conflict semantics.
propose_batch :: proc(
	h: ^Host, values: []sql.Mutation, slots: []sql.Slot,
) -> (assigned: []sql.Slot, err: Error) {
	if h.poisoned do return nil, .Poisoned
	if len(values) == 0 || len(values) > CHUNK || len(slots) < len(values) {
		return nil, .Invalid
	}
	if queue.len(h.packets) >= 1024 do return nil, .Backpressure
	for &value in values {
		if value.kind == .Skip && value.primary_key != 0 do return nil, .Invalid
		if sql.mutation_validate(&value) != .None do return nil, .Invalid
	}
	result, consensus_err := sql.node_propose_batch(&h.node, values, slots, &h.effects)
	if consensus_err != .None do return nil, proposal_error(consensus_err)
	if finish(h) != .None do return nil, .Storage
	return result, .None
}

@(private)
proposal_error :: proc(err: paxos.Error) -> Error {
	if err == .Window_Full do return .Backpressure
	return .Consensus
}
