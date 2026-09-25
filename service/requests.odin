package service

import "core:crypto/sha2"
import "core:math"
import "core:time"
import sql "../src"
import durable "../src/durable"
import tls "../transport/mtls"

respond :: proc(s: ^Server, c: ^Connection, error: string = "", changes: i64 = 0) -> bool {
	return enqueue(c, Response{status = "ok" if error == "" else "error", error = error,
		cluster = s.config.cluster, node = s.config.node, protocol = PROTOCOL,
		sequence = c.value.request.sequence, applied = s.host.engine.applied_through, changes = changes})
}

session_id :: proc(text, principal: string) -> (id: [16]u8, valid: bool) {
	if len(text) != 32 do return
	raw: [16]u8
	for ch, i in text {
		n: u8
		if ch >= '0' && ch <= '9' do n = u8(ch - '0')
		else if ch >= 'a' && ch <= 'f' do n = u8(ch - 'a' + 10)
		else do return
		raw[i / 2] |= n << (4 if i % 2 == 0 else 0)
	}
	if raw == ([16]u8{}) do return
	h: sha2.Context_256
	digest: [32]u8
	sha2.init_256(&h)
	sha2.update(&h, transmute([]u8)principal)
	sha2.update(&h, []u8{0})
	sha2.update(&h, raw[:])
	sha2.final(&h, digest[:])
	copy(id[:], digest[:16])
	return id, id != ([16]u8{})
}

request_value :: proc(s: ^Server, c: ^Connection, r: Request) -> (m: sql.Mutation, ok: bool) {
	session, valid := session_id(r.session, tls.peer_name(&c.tls))
	if r.op != "execute" { session[0] = 1; valid = true }
	sequence := r.sequence if r.op == "execute" else 1
	if !valid || len(r.parameters) > sql.MAX_MUTATION_COLS do return
	err: sql.Error
	m, err = sql.mutation_make_transaction(s.config.node, {session, sequence, r.session_epoch}, r.sql)
	if err != .None do return
	m.read_version = r.read_version
	for p in r.parameters {
		switch p.kind {
		case "text": err = sql.transaction_add_text(&m, p.text)
		case "integer": err = sql.transaction_add_int(&m, p.integer)
		case "vector": err = sql.mutation_add_vector(&m, "p", p.vector)
		case "null", "real":
			if p.kind == "real" && (math.is_nan(p.real) || math.is_inf(p.real)) do return
			err = sql.transaction_add_int(&m, 0)
			if err != .None do return
			m.col_values[m.col_count - 1].kind = .Null if p.kind == "null" else .Real
			m.col_values[m.col_count - 1].real_val = p.real
		case: return
		}
		if err != .None do return
	}
	return m, sql.mutation_validate(&m) == .None
}

dispatch :: proc(s: ^Server, c: ^Connection, r: Request) -> bool {
	if r.protocol != PROTOCOL || r.cluster != s.config.cluster do return false
	if c.peer != 0 {
		if !c.hello {
			if r.op != "hello" || r.node != c.peer || r.fingerprint != s.fingerprint do return false
			c.hello = true
			err := durable.catch_up(s.host, c.peer)
			if err != .None && err != .Backpressure { s.fatal = true; return false }
			return true
		}
		if r.op == "snapshot_receipt" do return receive_snapshot_receipt(s, c, r)
		if r.op == "snapshot_offer" do return receive_snapshot_offer(s, c, r)
		if r.op == "snapshot_fetch" do return send_snapshot_chunk(s, c, r)
		if r.op == "snapshot_chunk" do return receive_snapshot_chunk(s, c, r)
		if r.op == "frontier" do return respond_frontier(s, c, r)
		if r.op == "frontier_reply" do return receive_frontier(s, c, r)
		if r.op != "packet" || r.packet.from != c.peer || r.packet.to != s.config.node do return false
		packet: durable.Packet
		if !wire_decode(r.packet, &packet) do return false
		if r.packet.kind == 7 && r.packet.fields[0] > s.host.generation_base.key.prefix {
			c.snapshot_sending = false
		}
		if s.incoming_count == len(s.incoming) && !apply_packets(s) do return false
		s.incoming[s.incoming_count] = packet
		s.incoming_count += 1
		s.work_ready = true
		return true
	}
	if c.admission_rejected do return reject_client_admission(s, c, r.sequence)
	if c.pending != .None do return respond(s, c, "Busy")
	c.session_info = false
	if r.op == "session_epoch" || r.op == "retire_sessions" do return session_request(s, c, r)
	if r.op == "snapshot" do return respond_snapshot_request(s, c)
	if r.op == "status" do return respond_status(s, c)
	if r.op != "execute" && r.op != "query" && r.op != "begin" && r.op != "preview" {
		return respond(s, c, "Unsupported")
	}
	if r.timeout_ms < 1 || r.timeout_ms > 60000 do return respond(s, c, "Invalid_Request")
	if r.op == "query" && r.consistency != "linearizable" && r.consistency != "local" {
		return respond(s, c, "Invalid_Request")
	}
	input := r
	if r.op == "begin" || r.op == "preview" && r.sql == "" do input.sql = "SELECT 1"
	m, valid := request_value(s, c, input)
	if !valid do return respond(s, c, "Invalid_Request")
	c.value = m
	c.transaction_begin, c.preview = r.op == "begin", r.op == "preview"
	c.query_value = {}
	if c.preview {
		if r.sql == "" do c.value.sql_len = 0
		if r.read_version == 0 do return respond(s, c, "Invalid_Request")
		if r.read_sql != "" {
			input.op, input.sql, input.parameters = "query", r.read_sql, r.read_parameters
			c.query_value, valid = request_value(s, c, input)
			if !valid do return respond(s, c, "Invalid_Request")
		}
	}
	c.timeout = time.Duration(r.timeout_ms) * time.Millisecond
	c.pending_since = time.tick_now()
	c.pending = .Write if r.op == "execute" else .Read
	c.local_read = r.op == "query" && r.consistency == "local"
	if c.pending == .Write {
		// The owner admits this turn's complete requests together after draining
		// peer input. No acknowledgement or consensus effect occurs here.
		c.slot = 0
	}
	return true
}

poll_write :: proc(s: ^Server, c: ^Connection) -> bool {
	if c.slot == 0 do return true
	out, done, err := durable.outcome(s.host, c.slot, &c.value)
	if err != .None { s.fatal = true; return false }
	if done {
		c.pending = .None
		if c.value.kind == .Session_Epoch do return respond_epoch(s, c, outcome_name(out.kind))
		return respond(s, c, "" if out.kind == .Applied else outcome_name(out.kind), out.changes)
	}
	if s.host.engine.applied_through >= c.slot {
		slot, retry_err := durable.propose(s.host, c.value)
		err = retry_err
		if err == .None do c.slot = slot
		if err != .None && err != .Backpressure { s.fatal = true; return false }
	}
	return true
}

outcome_name :: proc(kind: sql.Transaction_Outcome) -> string {
	switch kind {
	case .Applied: return ""
	case .Constraint: return "Constraint"
	case .Policy: return "Policy"
	case .Sequence_Gap: return "Sequence_Gap"
	case .Expired: return "Expired"
	case .Identity_Conflict: return "Identity_Conflict"
	case .Session_Limit: return "Session_Limit"
	case .Invalid_SQL: return "Invalid_SQL"
	case .Conflict: return "Conflict"
	}
	return "Internal"
}

poll_read :: proc(s: ^Server, c: ^Connection) -> bool {
	if !c.local_read do return true // The closed cohort owns the single-use host ticket.
	return read_result(s, c)
}

read_result :: proc(s: ^Server, c: ^Connection) -> bool {
	c.pending = .None
	if c.session_info { c.session_info = false; return respond_epoch(s, c) }
	if c.transaction_begin || c.preview do return transaction_result(s, c)
	result, err := sql.engine_query(&s.host.engine, sql.mutation_sql(&c.value), &c.value,
		context.temp_allocator)
	if err != .None do return respond(s, c, "Query_Limit" if err == .Query_Limit else "Invalid_SQL")
	return enqueue(c, Response{status = "ok", cluster = s.config.cluster, protocol = PROTOCOL,
		node = s.config.node, applied = s.host.engine.applied_through,
		columns = result.columns, rows = result.rows})
}
