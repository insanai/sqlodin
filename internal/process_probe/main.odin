// One durable voter per process and directory. The Python controller routes messages
// over bounded framed pipes and records the scheduling/serialization measurement boundary.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import sql "../../src"
import durable "../../src/durable"

Request :: struct { client, sequence: u64, sql: string }
Command :: struct {
	action: string, writes: []Request, packets: []Wire, sql: string,
	ticket: durable.Read_Ticket,
}
Completion :: struct { client, sequence: u64, kind: sql.Transaction_Outcome, slot: sql.Slot }
Response :: struct {
	applied: sql.Slot,
	packets: [dynamic]Wire,
	completed: [dynamic]Completion,
	accepted: int,
	backpressure: bool,
	rows: int,
	sql_error: sql.Error,
	ticket: durable.Read_Ticket,
	read_result: durable.Read_Result,
}
Pending :: struct { active: bool, client, sequence: u64, slot: sql.Slot, value: sql.Mutation }
Worker :: struct {
	host: ^durable.Host,
	pending: [64]Pending,
	admission: [durable.CHUNK]sql.Mutation,
	slots: [durable.CHUNK]sql.Slot,
	incoming: [durable.MAX_STEP_BATCH]durable.Packet,
}
MAX_FRAME :: 8 * 1024 * 1024

must :: proc(ok: bool) { if !ok do panic("process probe contract failed") }

transfer :: proc(file: ^os.File, bytes: []u8, writing: bool) -> bool {
	for offset := 0; offset < len(bytes); {
		n: int
		err: os.Error
		if writing do n, err = os.write(file, bytes[offset:])
		else do n, err = os.read(file, bytes[offset:])
		if err != nil || n <= 0 do return false
		offset += n
	}
	return true
}

request_value :: proc(id: sql.Node_Id, r: Request) -> sql.Mutation {
	request := sql.Request_Id{sequence = r.sequence}
	for i in 0..<8 do request.session[i] = u8(r.client >> uint(8 * i))
	m, err := sql.mutation_make_transaction(id, request, r.sql)
	must(err == .None)
	return m
}

admit :: proc(w: ^Worker, requests: []Request, r: ^Response) {
	must(len(requests) <= durable.CHUNK)
	if len(requests) == 0 do return
	free: [durable.CHUNK]int
	count := 0
	for p, i in w.pending {
		if !p.active {
			free[count] = i
			count += 1
			if count == len(requests) do break
		}
	}
	if count != len(requests) { r.backpressure = true; return }
	for request, i in requests do w.admission[i] = request_value(w.host.node.id, request)
	_, err := durable.propose_batch(w.host, w.admission[:count], w.slots[:count])
	if err == .Backpressure { r.backpressure = true; return }
	must(err == .None)
	for request, i in requests {
		w.pending[free[i]] = Pending{true, request.client, request.sequence, w.slots[i], w.admission[i]}
	}
	r.accepted = count
}

respond :: proc(w: ^Worker, command: Command) -> Response {
	r := Response{packets = make([dynamic]Wire, 0, 32, context.temp_allocator),
		completed = make([dynamic]Completion, 0, 16, context.temp_allocator)}
	receive_packets(w, command.packets)
	switch command.action {
	case "drive": admit(w, command.writes, &r)
	case "tick": must(durable.tick(w.host) == .None)
	case "read":
		r.rows, r.sql_error = sql.engine_read_snapshot(&w.host.engine, command.sql)
	case "begin_read":
		err: durable.Error
		r.ticket, err = durable.begin_read(w.host, 0)
		must(err == .None)
	case "poll_read":
		err: durable.Error
		r.read_result, err = durable.poll_read(w.host, command.ticket, command.sql)
		must(err == .None)
	case: must(false)
	}
	for &p in w.pending {
		if !p.active do continue
		out, complete, err := durable.outcome(w.host, p.slot, &p.value)
		must(err == .None)
		if complete {
			append(&r.completed, Completion{p.client, p.sequence, out.kind, out.slot})
			p.active = false
		}
	}
	packet: durable.Packet
	for durable.pop(w.host, &packet) {
		must(len(r.packets) < 1024)
		append(&r.packets, wire_encode(&packet))
	}
	r.applied = w.host.engine.applied_through
	return r
}

receive_packets :: proc(w: ^Worker, packets: []Wire) {
	must(len(packets) <= 128)
	for first := 0; first < len(packets); {
		count := min(durable.MAX_STEP_BATCH, len(packets) - first)
		for packet, i in packets[first:first + count] do wire_decode(packet, &w.incoming[i])
		must(durable.step_batch(w.host, w.incoming[:count]) == .None)
		first += count
	}
}

main :: proc() {
	must(len(os.args) == 4)
	id, valid := strconv.parse_int(os.args[2])
	must(valid && id >= 1 && id <= 3)
	path := fmt.aprintf("%s/node.db", os.args[1])
	defer delete(path)
	ids := [3]sql.Node_Id{1, 2, 3}
	h, err := durable.open(path, "process-test", sql.Node_Id(id), ids[:], create = os.args[3] == "create")
	must(err == .None)
	defer durable.close(h)
	w := new(Worker)
	defer free(w)
	w.host = h
	buffer := make([]u8, MAX_FRAME)
	defer delete(buffer)
	for {
		free_all(context.temp_allocator)
		header: [4]u8
		if !transfer(os.stdin, header[:], false) do return
		size: u32
		for b, i in header do size |= u32(b) << uint(8 * i)
		must(size > 0 && size <= MAX_FRAME)
		must(transfer(os.stdin, buffer[:size], false))
		command: Command
		must(json.unmarshal(buffer[:size], &command, allocator = context.temp_allocator) == nil)
		response := respond(w, command)
		encoded, marshal_err := json.marshal(response, {use_enum_names = true},
			allocator = context.temp_allocator)
		must(marshal_err == nil && len(encoded) <= MAX_FRAME)
		for &b, i in header do b = u8(u32(len(encoded)) >> uint(8 * i))
		must(transfer(os.stdout, header[:], true) && transfer(os.stdout, encoded, true))
	}
}
