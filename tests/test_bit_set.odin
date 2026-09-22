package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_bit_set_basic :: proc(t: ^testing.T) {
	bs: sqlodin.Bit_Set(128)
	testing.expect_value(t, sqlodin.bit_set_count(bs), 0)

	testing.expect(t, sqlodin.bit_set_insert(&bs, 5))
	testing.expect(t, !sqlodin.bit_set_insert(&bs, 5))
	testing.expect(t, sqlodin.bit_set_contains(bs, 5))
	testing.expect_value(t, sqlodin.bit_set_count(bs), 1)

	sqlodin.bit_set_remove(&bs, 5)
	testing.expect(t, !sqlodin.bit_set_contains(bs, 5))
	testing.expect_value(t, sqlodin.bit_set_count(bs), 0)
}

@(test)
test_bit_set_scans :: proc(t: ^testing.T) {
	bs: sqlodin.Bit_Set(128)
	sqlodin.bit_set_insert(&bs, 10)
	sqlodin.bit_set_insert(&bs, 64)
	sqlodin.bit_set_insert(&bs, 100)

	idx, ok := sqlodin.bit_set_next(bs, 0)
	testing.expect(t, ok)
	testing.expect_value(t, idx, 10)

	idx, ok = sqlodin.bit_set_next(bs, 11)
	testing.expect(t, ok)
	testing.expect_value(t, idx, 64)

	idx, ok = sqlodin.bit_set_next(bs, 65)
	testing.expect(t, ok)
	testing.expect_value(t, idx, 100)

	_, ok = sqlodin.bit_set_next(bs, 101)
	testing.expect(t, !ok)

	last, last_ok := sqlodin.bit_set_last(bs)
	testing.expect(t, last_ok)
	testing.expect_value(t, last, 100)
}
