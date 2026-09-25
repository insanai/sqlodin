// Versioned service packet codec. Values own their bytes before the next transition.
package service

import "core:encoding/base64"
import sql "../src"
import durable "../src/durable"

Wire :: struct {
	from, to: sql.Node_Id,
	kind: u8,
	fields: [8]u64,
	value: string,
}

words :: proc(values: ..u64) -> (result: [8]u64) {
	copy(result[:], values)
	return
}

wire_encode :: proc(p: ^durable.Packet) -> Wire {
	w := Wire{from = p.env.from, to = p.env.to}
	switch m in p.env.message {
	case sql.Prepare_Message:
		w.kind, w.fields = 1, words(u64(m.ballot), m.first, m.last, u64(m.scope))
	case sql.Promise_Message(sql.Mutation):
		w.kind, w.fields = 2, words(u64(m.ballot), m.slot, u64(m.vote), u64(m.state))
	case sql.Promise_Range_Message:
		w.kind, w.fields = 3, words(u64(m.ballot), m.anchor.trim_id, m.anchor.chosen_trim_slot,
			m.chosen_through, m.first, m.last, u64(m.reported), u64(m.more))
	case sql.Accept_Message(sql.Mutation):
		w.kind, w.fields = 4, words(u64(m.ballot), m.slot)
	case sql.Accepted_Message:
		w.kind, w.fields = 5, words(u64(m.ballot), m.slot, m.decided_through)
	case sql.Commit_Message(sql.Mutation): w.kind, w.fields = 6, words(m.slot)
	case sql.Learn_Message: w.kind, w.fields = 7, words(m.from_slot, u64(m.count))
	case sql.Nack_Message:
		w.kind, w.fields = 8, words(u64(m.rejected), u64(m.promised), m.slot, m.decided_through)
	case sql.Heartbeat_Message: w.kind, w.fields = 9, words(u64(m.ballot), m.decided_through)
	}
	if _, present := sql.message_value(p.env.message); present {
		c: durable.Codec
		durable.mutation_codec(&c, &p.value)
		storage: [durable.PACKED_CAPACITY]u8
		packed, ok := durable.pack_record(c.bytes[:c.pos], storage[:])
		if !ok do return {}
		w.value = base64.encode(packed, allocator = context.temp_allocator)
	}
	return w
}

wire_decode :: proc(w: Wire, p: ^durable.Packet) -> bool {
	if w.from == 0 || w.to == 0 || w.from > 1023 || w.to > 1023 do return false
	p^ = {}
	p.env.from, p.env.to = w.from, w.to
	f := w.fields
	switch w.kind {
	case 1:
		if f[3] > 1 do return false
		p.env.message = sql.Prepare_Message{sql.Ballot(f[0]), f[1], f[2], sql.Prepare_Scope(f[3])}
	case 2:
		if f[3] > 2 do return false
		p.env.message = sql.Promise_Message(sql.Mutation){sql.Ballot(f[0]), f[1], sql.Ballot(f[2]), 
			sql.Cell_State(f[3]), nil}
	case 3:
		if f[6] > u64(max(u32)) || f[7] > 1 do return false
		p.env.message = sql.Promise_Range_Message{sql.Ballot(f[0]), {f[1], f[2]}, f[3], f[4], f[5],
			u32(f[6]), f[7] != 0}
	case 4: p.env.message = sql.Accept_Message(sql.Mutation){sql.Ballot(f[0]), f[1], nil}
	case 5: p.env.message = sql.Accepted_Message{sql.Ballot(f[0]), f[1], f[2]}
	case 6: p.env.message = sql.Commit_Message(sql.Mutation){f[0], nil}
	case 7:
		if f[1] > u64(max(u32)) do return false
		p.env.message = sql.Learn_Message{f[0], u32(f[1])}
	case 8: p.env.message = sql.Nack_Message{sql.Ballot(f[0]), sql.Ballot(f[1]), f[2], f[3]}
	case 9: p.env.message = sql.Heartbeat_Message{sql.Ballot(f[0]), f[1]}
	case: return false
	}
	if _, present := sql.message_value(p.env.message); present {
		c: durable.Codec
		durable.mutation_codec(&c, &p.value)
		expected := c.pos
		if len(w.value)%4 != 0 do return false
		storage: [durable.PACKED_CAPACITY]u8
		bytes, err := base64.decode_into_buf(storage[:], w.value)
		if err != nil do return false
		size, unpacked := durable.unpack_record(bytes, c.bytes[:])
		if !unpacked || size != expected do return false
		c.pos, c.reading = 0, true
		durable.mutation_codec(&c, &p.value)
		if sql.mutation_validate(&p.value) != .None do return false
	} else if w.value != "" { return false }
	return true
}
