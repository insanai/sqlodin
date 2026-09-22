package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_durability_gate_lifecycle :: proc(t: ^testing.T) {
	e: sqlodin.Effects(sqlodin.Mutation, 3, 64, 16, .Host_Managed)
	sqlodin.effects_init(&e)

	m := sqlodin.mutation_make_skip(1, 0)
	sqlodin.effects_add_write(&e, sqlodin.Write_Promise{ballot = sqlodin.ballot_make(1, 0, 1)})
	sqlodin.effects_add_committed(&e, 1, &m)

	writes := sqlodin.effects_writes_slice(&e)
	testing.expect_value(t, len(writes), 1)

	committed := sqlodin.effects_committed_slice(&e)
	testing.expect_value(t, len(committed), 1)

	sqlodin.effects_confirm_writes_durable(&e)
	sqlodin.effects_reset(&e)

	testing.expect_value(t, len(sqlodin.effects_writes_slice(&e)), 0)
	testing.expect_value(t, len(sqlodin.effects_committed_slice(&e)), 0)
}
