package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_membership_validation :: proc(t: ^testing.T) {
	m: sqlodin.Membership(5)

	// Empty
	empty_ids: []sqlodin.Node_Id = {}
	testing.expect(t, sqlodin.membership_init(&m, empty_ids) == .Empty_Membership)

	// Zero ID
	zero_ids := [?]sqlodin.Node_Id{1, 0}
	testing.expect(t, sqlodin.membership_init(&m, zero_ids[:]) == .Invalid_Node_Id)

	// Duplicate ID
	dup_ids := [?]sqlodin.Node_Id{1, 2, 2}
	testing.expect(t, sqlodin.membership_init(&m, dup_ids[:]) == .Duplicate_Node_Id)

	// Valid 3-member cluster
	valid_ids := [?]sqlodin.Node_Id{3, 1, 2}
	testing.expect(t, sqlodin.membership_init(&m, valid_ids[:]) == .None)
	testing.expect_value(t, sqlodin.membership_count(&m), 3)
	testing.expect_value(t, sqlodin.membership_read_quorum(&m), 2)
	testing.expect_value(t, sqlodin.membership_write_quorum(&m), 2)

	// Sorted members: 1, 2, 3
	testing.expect_value(t, sqlodin.membership_get(&m, 0), 1)
	testing.expect_value(t, sqlodin.membership_get(&m, 1), 2)
	testing.expect_value(t, sqlodin.membership_get(&m, 2), 3)

	idx, found := sqlodin.membership_index_of(&m, 2)
	testing.expect(t, found)
	testing.expect_value(t, idx, 1)

	_, found_fake := sqlodin.membership_index_of(&m, 99)
	testing.expect(t, !found_fake)
}

@(test)
test_membership_quorums :: proc(t: ^testing.T) {
	m: sqlodin.Membership(5)
	ids := [?]sqlodin.Node_Id{1, 2, 3}

	// Non-intersecting quorums: read(1) + write(1) <= 3
	err := sqlodin.membership_init(
		&m, ids[:], read_quorum_override = 1, write_quorum_override = 1,
	)
	testing.expect(t, err == .Non_Intersecting_Quorums)

	// Intersecting quorums: read(1) + write(3) > 3
	err = sqlodin.membership_init(
		&m, ids[:], read_quorum_override = 1, write_quorum_override = 3,
	)
	testing.expect(t, err == .None)
}
