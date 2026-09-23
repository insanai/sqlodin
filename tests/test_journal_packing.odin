package tests

import "core:testing"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

@(test)
test_journal_packing_roundtrip_and_bounds :: proc(t: ^testing.T) {
	raw: [durable.WIRE_CAPACITY]u8
	packed: [durable.PACKED_CAPACITY]u8
	decoded: [durable.WIRE_CAPACITY]u8
	seed: u64 = 984217
	for mode in 0..<5 {
		for &b, i in raw {
			seed = seed * 6364136223846793005 + 1
			switch mode {
			case 0: b = 0
			case 1: b = 255
			case 2: b = u8(i % 2)
			case 3: b = u8(seed >> 56)
			case 4: b = u8(seed >> 56) if i % 127 == 0 else 0
			}
		}
		for length in ([?]int{0, 1, 127, 128, 129, 255, 1024, len(raw)}) {
			bytes, ok := durable.pack_record(raw[:length], packed[:])
			testing.expect(t, ok)
			for &b in decoded do b = 0xff
			size, valid := durable.unpack_record(bytes, decoded[:])
			testing.expect(t, valid && size == length)
			for b, i in raw[:length] do testing.expect_value(t, decoded[i], b)
			if length > 0 {
				_, valid = durable.unpack_record(bytes[:len(bytes) - 1], decoded[:])
				testing.expect(t, !valid)
				_, valid = durable.unpack_record(bytes, decoded[:length - 1])
				testing.expect(t, !valid)
			}
		}
	}
}

@(test)
test_journal_packing_preserves_inactive_value_bits :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	m, err := sql.mutation_make_raw_sql(1, 0, "CREATE TABLE t(v);")
	testing.expect(t, err == .None)
	// Inactive values still participate in upstream whole-value equality.
	m.sql_bytes[len(m.sql_bytes) - 1] = 0xfa
	m.table_name[len(m.table_name) - 1] = 0xa7
	m.col_values[15].real_val = -13.25
	m.col_values[15].text_val[255] = 0x8b
	slot, propose_err := durable.propose(c.hosts[0], m)
	testing.expect(t, propose_err == .None)
	durable_test_reopen(t, c, 0, 1)
	testing.expect(t, durable.acknowledged(c.hosts[0], slot, &m))
	s, prepare_err := sql.engine_prepare(&c.hosts[0].engine,
		"SELECT max(length(data)) FROM _sqlodin_journal;")
	testing.expect(t, prepare_err == .None)
	defer db.sqlite3_finalize(s)
	testing.expect(t, db.sqlite3_step(s) == db.ROW)
	testing.expect(t, db.sqlite3_column_int64(s, 0) < 512)
}

@(test)
test_journal_unpack_rejects_malformed_bounds :: proc(t: ^testing.T) {
	data: [128]u8
	decoded: [durable.WIRE_CAPACITY]u8
	packed: [durable.PACKED_CAPACITY]u8
	seed: u64 = 1234567
	for _ in 0..<2000 {
		for &b in data {
			seed = seed * 6364136223846793005 + 1
			b = u8(seed >> 56)
		}
		data[0], data[1] = 0x53, 3
		data[4], data[5] = 0, 0
		length := 6 + int(seed % 123)
		size, valid := durable.unpack_record(data[:length], decoded[:])
		if valid {
			bytes, encoded := durable.pack_record(decoded[:size], packed[:])
			testing.expect(t, encoded && len(bytes) <= durable.PACKED_CAPACITY)
		}
	}
}
