package snapshot

explain :: proc(err: Error) -> string {
	switch err {
	case .None: return "Snapshot evidence accepted."
	case .Invalid_Membership:
		return "Invalid snapshot voter plan.\n" +
			"Hint: Supply one to five distinct configured voter IDs in 1..1023."
	case .Invalid_Key:
		return "Incomplete snapshot identity.\n" +
			"Hint: Supply nonzero digests, generation and applied prefix."
	case .Invalid_Image:
		return "Invalid image description.\n" +
			"Hint: Recreate and verify the complete image before recording evidence."
	case .Wrong_Voter:
		return "Receipt names an unknown voter.\n" +
			"Hint: Check the authenticated identity against the voter plan."
	case .Wrong_Key:
		return "Snapshot identities differ.\n" +
			"Hint: Collect receipts for the exact expected prefix and state."
	case .Duplicate_Voter:
		return "A voter appears more than once.\n" +
			"Hint: Count each authenticated voter once when building a quorum."
	case .No_Quorum:
		return "Too few distinct snapshot holders.\n" +
			"Hint: Retain matching images on a majority before certification."
	case .Invalid_Certificate:
		return "Malformed snapshot certificate.\n" +
			"Hint: Reload the complete canonical encoding; do not trim history."
	}
	unreachable()
}

explain_image :: proc(err: Image_Error) -> string {
	switch err {
	case .None: return "Image operation completed."
	case .Invalid:
		return "Invalid image operation.\n" +
			"Hint: Check the path, job phase, expected identity and positive limits."
	case .Invalid_Source:
		return "Image verification failed.\n" +
			"Hint: Check its hash, prefix, engine, integrity and application-only schema."
	case .Storage:
		return "Image storage operation failed.\n" +
			"Hint: Check free space, permissions and exclusive destination paths."
	case .Limit:
		return "Image verification exceeded its budget.\n" +
			"Hint: Inspect image size and raise the offline budget if safe."
	case .Cancelled:
		return "Image operation cancelled.\n" +
			"Hint: Keep partial files unadvertised; retry in a new staging directory."
	case .Timeout:
		return "Image operation exceeded its deadline.\n" +
			"Hint: Check storage health and retry in a new staging directory."
	}
	unreachable()
}
