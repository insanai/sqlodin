package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_ballot_packing :: proc(t: ^testing.T) {
	b := sqlodin.ballot_make(42, 5, 3)
	testing.expect_value(t, sqlodin.ballot_round(b), 42)
	testing.expect_value(t, sqlodin.ballot_priority(b), 5)
	testing.expect_value(t, sqlodin.ballot_node(b), sqlodin.Node_Id(3))
}

@(test)
test_ballot_ordering :: proc(t: ^testing.T) {
	b1 := sqlodin.ballot_make(1, 0, 1)
	b2 := sqlodin.ballot_make(1, 0, 2)
	b3 := sqlodin.ballot_make(1, 1, 1)
	b4 := sqlodin.ballot_make(2, 0, 1)

	testing.expect(t, b1 < b2)
	testing.expect(t, b2 < b3)
	testing.expect(t, b3 < b4)
}

@(test)
test_slot_arithmetic :: proc(t: ^testing.T) {
	testing.expect_value(t, sqlodin.cell_of(1, 64), 0)
	testing.expect_value(t, sqlodin.cell_of(64, 64), 63)
	testing.expect_value(t, sqlodin.cell_of(65, 64), 0)

	testing.expect_value(t, sqlodin.slot_add(10, 5), 15)
	testing.expect_value(t, sqlodin.slot_add(max(sqlodin.Slot) - 2, 5), max(sqlodin.Slot))
}
