package tests

import "core:testing"
import "core:strings"
import sqlodin "../src"

@(test)
test_every_error_explains_problem_and_recovery :: proc(t: ^testing.T) {
	for err in sqlodin.Error {
		text := sqlodin.explain_error(err)
		testing.expect(t, len(text) > 0, "Missing explanation for error")
		if err != .None {
			testing.expect(t, strings.contains(text, "--"), "Error missing banner")
			testing.expect(t, strings.contains(text, "Hint:"), "Error missing Hint")
		}
	}
}
