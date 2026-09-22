package sqlodin

VERSION :: "0.1.0"

// Proc group aliases for idiomatic Odin API surface.
init :: proc{
	node_init,
	effects_init,
	membership_init,
	engine_open,
}

propose :: proc{
	node_propose,
}

step :: proc{
	node_step,
}

tick :: proc{
	node_tick,
}

decided_through :: proc{
	node_decided_through,
}

own_next :: proc{
	node_own_next,
}

highest_seen :: proc{
	node_highest_seen,
}

applied_through :: proc{
	engine_applied_through,
}

explain :: proc{
	explain_error,
}
