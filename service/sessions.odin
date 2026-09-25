package service

import "core:time"
import sql "../src"
import durable "../src/durable"

session_request :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	if r.timeout_ms < 1 || r.timeout_ms > 60000 do return respond(s, c, "Invalid_Request")
	c.value, c.query_value = {}, {}
	c.transaction_begin, c.preview, c.local_read = false, false, false
	c.session_info = r.op == "session_epoch"
	c.timeout = time.Duration(r.timeout_ms)*time.Millisecond
	c.pending_since = time.tick_now()
	if c.session_info { c.pending = .Read; return true }
	value, err := sql.mutation_make_session_retirement(s.config.node, r.session_epoch)
	if err != .None do return respond(s, c, "Invalid_Request")
	c.value = value
	slot, proposed := durable.propose(s.host, c.value)
	if proposed == .Backpressure do return respond(s, c, "Busy")
	if proposed != .None { s.fatal = true; return false }
	c.slot, c.pending = slot, .Write
	return true
}

respond_epoch :: proc(s: ^Server, c: ^Connection, error: string = "") -> bool {
	epoch, err := sql.engine_session_epoch(&s.host.engine)
	if err != .None { s.fatal = true; return false }
	return enqueue(c, Response{status = "ok" if error == "" else "error", error = error,
		cluster = s.config.cluster, protocol = PROTOCOL, node = s.config.node,
		applied = s.host.engine.applied_through, session_epoch = epoch})
}
