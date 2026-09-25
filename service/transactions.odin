package service

import "core:fmt"
import sql "../src"

transaction_result :: proc(s: ^Server, c: ^Connection) -> bool {
	if c.transaction_begin {
		version, err := sql.engine_read_version(&s.host.engine)
		if err != .None { s.fatal = true; return false }
		epoch, epoch_err := sql.engine_session_epoch(&s.host.engine)
		if epoch_err != .None { s.fatal = true; return false }
		return enqueue(c, Response{status = "ok", cluster = s.config.cluster, protocol = PROTOCOL,
			node = s.config.node, applied = s.host.engine.applied_through,
			read_version = version, session_epoch = epoch})
	}
	path := s.host.application_path
	if path == "" do path = fmt.tprintf("%s/node.db", s.config.data)
	e, open_err := sql.engine_open(path, s.config.node)
	if open_err != .None do return respond(s, c, "Preview_Error")
	defer sql.engine_close(&e)
	if sql.engine_install_limits(&e) != .None do return respond(s, c, "Preview_Error")
	result, out, changes, lastrowid, err := sql.engine_preview(&e, &c.value, &c.query_value,
		context.temp_allocator)
	if err != .None do return respond(s, c, "Query_Limit" if err == .Query_Limit else "Invalid_SQL")
	if out.kind != .Applied do return respond(s, c, outcome_name(out.kind))
	return enqueue(c, Response{status = "ok", cluster = s.config.cluster, protocol = PROTOCOL,
		node = s.config.node, applied = s.host.engine.applied_through, changes = changes,
		lastrowid = lastrowid, read_version = c.value.read_version,
		columns = result.columns, rows = result.rows})
}
