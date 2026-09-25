package tests

import "core:encoding/base64"
import "core:testing"
import sql "../src"
import durable "../src/durable"
import service "../service"

@(test)
test_peer_wire_packing_preserves_complete_values_and_rejects_malformed_frames :: proc(t: ^testing.T) {
	packet: durable.Packet
	request := sql.Request_Id{sequence = 1}
	request.session[0] = 1
	packet.value, _ = sql.mutation_make_transaction(1, request, "UPDATE items SET visits=visits+1")
	packet.env = {from = 1, to = 2, message = sql.Commit_Message(sql.Mutation){7, &packet.value}}
	plain: durable.Codec
	durable.mutation_codec(&plain, &packet.value)
	wire := service.wire_encode(&packet)
	testing.expect(t, len(wire.value)*10 < plain.pos)
	// Upstream equality includes inactive array tails. Do not merely serialize
	// active SQL/parameters, or lose IEEE sign/payload bits through JSON numbers.
	packet.value.sql_bytes[sql.MAX_SQL_LEN-1] = 0xab
	packet.value.col_values[15].text_val[255] = 0xcd
	packet.value.vec_values[sql.MAX_MUTATION_VEC_VALUES-1] = transmute(f32)u32(0x80000000)
	plain = {}
	durable.mutation_codec(&plain, &packet.value)
	for kind in 0..<3 {
		switch kind {
		case 0: packet.env.message = sql.Commit_Message(sql.Mutation){7, &packet.value}
		case 1: packet.env.message = sql.Accept_Message(sql.Mutation){11, 7, &packet.value}
		case 2: packet.env.message = sql.Promise_Message(sql.Mutation){11, 7, 10, .Voted, &packet.value}
		}
		wire = service.wire_encode(&packet)
		decoded: durable.Packet
		testing.expect(t, service.wire_decode(wire, &decoded))
		actual: durable.Codec
		durable.mutation_codec(&actual, &decoded.value)
		testing.expect(t, actual.pos == plain.pos &&
			durable.digest(actual.bytes[:actual.pos]) == durable.digest(plain.bytes[:plain.pos]))
		for length in 0..<len(wire.value) {
			bad := wire
			bad.value = wire.value[:length]
			testing.expect(t, !service.wire_decode(bad, &decoded))
		}
		bad := wire
		bad.value = base64.encode(plain.bytes[:plain.pos], allocator = context.temp_allocator)
		testing.expect(t, !service.wire_decode(bad, &decoded))
		bad = wire
		bad.kind = 7
		testing.expect(t, !service.wire_decode(bad, &decoded))
	}
}
