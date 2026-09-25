package snapshot

// Check a closed image against independently supplied voter state. The caller
// must own an immutable private directory throughout both passes. File and
// logical checks have separate bounded budgets. Success does not publish a
// receipt: durable receipt storage and quorum sealing are separate operations.
candidate_check :: proc(
	path: string, candidate: Candidate, expected: Key,
	limits: Logical_Limits = DEFAULT_LOGICAL_LIMITS,
) -> Image_Error {
	if err := candidate_check_file(path, candidate, expected, limits.image_bytes,
		limits.seconds, limits.instructions, limits.cancel); err != .None do return err
	digest, err := logical_digest(path, expected.prefix, limits)
	if err != .None do return err
	if digest != expected.logical_state do return .Invalid_Source
	return .None
}
