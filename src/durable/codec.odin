package durable

import "core:crypto/sha2"
import sql ".."
import paxos "../../deps/paxos-odin/src"

// Logical fields are explicitly little endian, including IEEE floating point bits.
// Journal format 4 wraps these bytes with bounded, lossless zero-run packing.
// Encode every logical field (even unused array tails): upstream compares whole values.
WIRE_CAPACITY :: 8192 + sql.MAX_SQL_LEN + 4 * sql.MAX_MUTATION_VEC_VALUES
Codec :: struct {
	bytes: [WIRE_CAPACITY]u8,
	pos: int,
	reading, legacy: bool,
}
Record :: struct {
	seq: u64,
	previous: [32]u8,
	kind: u8,
	slot: sql.Slot,
	ballot: sql.Ballot,
	value: sql.Mutation,
	legacy: bool, // Read-only compatibility with pre-epoch record encoding.
}

scalar :: proc(c: ^Codec, value: ^$T) {
	bits: u64
	when T == f32 {
		bits = u64(transmute(u32)value^)
	} else when T == f64 {
		bits = transmute(u64)value^
	} else {
		bits = u64(value^)
	}
	if c.reading do bits = 0
	for i in 0..<size_of(T) {
		if c.reading {
			bits |= u64(c.bytes[c.pos]) << uint(8 * i)
		} else {
			c.bytes[c.pos] = u8(bits >> uint(8 * i))
		}
		c.pos += 1
	}
	if c.reading {
		when T == f32 {
			value^ = transmute(f32)u32(bits)
		} else when T == f64 {
			value^ = transmute(f64)bits
		} else {
			value^ = T(bits)
		}
	}
}

mutation_codec :: proc(c: ^Codec, m: ^sql.Mutation) {
	scalar(c, &m.kind)
	for &v in m.request.session do scalar(c, &v)
	scalar(c, &m.request.sequence)
	if !c.legacy do scalar(c, &m.request.epoch)
	scalar(c, &m.read_version)
	scalar(c, &m.origin_node)
	scalar(c, &m.timestamp_ms)
	scalar(c, &m.primary_key)
	for &v in m.table_name do scalar(c, &v)
	scalar(c, &m.table_len)
	scalar(c, &m.col_count)
	for &name in m.col_names do for &v in name do scalar(c, &v)
	for &v in m.col_name_lens do scalar(c, &v)
	for &v in m.col_values {
		scalar(c, &v.kind)
		scalar(c, &v.int_val)
		scalar(c, &v.real_val)
		for &b in v.text_val do scalar(c, &b)
		scalar(c, &v.text_len)
		scalar(c, &v.vec_offset)
		scalar(c, &v.vec_dim)
	}
	for &v in m.vec_values do scalar(c, &v)
	scalar(c, &m.vec_count)
	for &v in m.sql_bytes do scalar(c, &v)
	scalar(c, &m.sql_len)
}

record_codec :: proc(c: ^Codec, r: ^Record) {
	scalar(c, &r.seq)
	for &v in r.previous do scalar(c, &v)
	scalar(c, &r.kind)
	scalar(c, &r.slot)
	scalar(c, &r.ballot)
	if r.kind == 3 || r.kind == 4 do mutation_codec(c, &r.value)
}

digest :: proc(bytes: []u8) -> (hash: [32]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, bytes)
	sha2.final(&ctx, hash[:])
	return
}

record_write :: proc(r: ^Record) -> sql.Write(sql.Mutation) {
	switch r.kind {
	case 1: return sql.Write_Promise{ballot = r.ballot}
	case 2: return sql.Write_Promise_At{slot = r.slot, ballot = r.ballot}
	case 3: return sql.Write_Vote(sql.Mutation){r.ballot, r.slot, &r.value}
	case 4: return sql.Write_Chosen(sql.Mutation){r.slot, &r.value}
	}
	panic("Invalid journal record")
}

make_record :: proc(w: sql.Write(sql.Mutation)) -> (r: Record, ok: bool) {
	switch v in w {
	case sql.Write_Promise: r.kind, r.ballot = 1, v.ballot
	case sql.Write_Promise_At: r.kind, r.slot, r.ballot = 2, v.slot, v.ballot
	case sql.Write_Vote(sql.Mutation):
		r.kind, r.slot, r.ballot, r.value = 3, v.slot, v.ballot, v.value^
	case sql.Write_Chosen(sql.Mutation): r.kind, r.slot, r.value = 4, v.slot, v.value^
	case sql.Write_Trim: return {}, false // No snapshot/trim protocol in this format.
	}
	return r, r.kind != 0 && r.slot <= u64(max(i64))
}

// Instantiate upstream integer helpers required by its generic package imports.
@(private)
_vet_keep :: proc() {
	n: paxos.Node(u64, 3, 8, 2)
	e: paxos.Effects(u64, 3, 8, 2)
	_ = paxos.node_tick(&n, u64(0), &e)
}
