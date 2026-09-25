package snapshot

import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import sql ".."

// The host supplies its persisted identity and independently established key.
// It must own both paths exclusively and retain the image and manifest until a
// successor certificate permits deletion. This blocking worker operation is not
// a live-service integration or authorization to install/trim consensus state.
// Recovery must reverify a retained candidate before reconstructing its receipt.
retain :: proc(
	image_path, manifest_path: string, candidate: Candidate, expected: Key,
	voter: sql.Node_Id, members: []sql.Node_Id,
	limits: Logical_Limits = DEFAULT_LOGICAL_LIMITS, fault: Manifest_Fault = .None,
) -> (Receipt, Image_Error) {
	if !retain_voter(voter, members) || !candidate_path_valid(manifest_path) do return {}, .Invalid
	if err := candidate_check(image_path, candidate, expected, limits); err != .None do return {}, err
	// Verification alone does not make recently received image bytes durable.
	// Flush the image and its name before persisting the candidate description.
	if !retain_sync_image(image_path) do return {}, .Storage
	if err := candidate_store(manifest_path, candidate, expected, fault); err != .None do return {}, err
	return Receipt{voter, expected, candidate.image, candidate.bytes}, .None
}

// A crash may leave a complete manifest without a successful prior return.
// Reconstruct evidence only after rechecking identity, contents and durability;
// never trust existence of a manifest or an earlier in-memory verification flag.
recover_retained :: proc(
	image_path, manifest_path: string, expected: Key, voter: sql.Node_Id, members: []sql.Node_Id,
	limits: Logical_Limits = DEFAULT_LOGICAL_LIMITS,
) -> (Receipt, Image_Error) {
	if !retain_voter(voter, members) do return {}, .Invalid
	candidate, err := candidate_load(manifest_path, expected)
	if err != .None do return {}, err
	if check := candidate_check(image_path, candidate, expected, limits); check != .None do return {}, check
	if !retain_sync_image(image_path) || !retain_sync_image(manifest_path) do return {}, .Storage
	return Receipt{voter, expected, candidate.image, candidate.bytes}, .None
}

@(private)
retain_voter :: proc(voter: sql.Node_Id, members: []sql.Node_Id) -> bool {
	if !membership_valid(members) do return false
	for member in members do if member == voter { return true }
	return false
}

@(private)
retain_sync_image :: proc(path: string) -> bool {
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.RDWR, .NOFOLLOW, .NONBLOCK})
	if file < 0 do return false
	defer posix.close(file)
	stat: posix.stat_t
	if posix.fstat(file, &stat) != nil || !posix.S_ISREG(stat.st_mode) do return false
	parent := strings.clone_to_cstring(filepath.dir(path))
	defer delete(parent)
	dir := posix.open(parent, {.DIRECTORY, .NOFOLLOW})
	if dir < 0 do return false
	defer posix.close(dir)
	return manifest_sync_file(file) && posix.fsync(dir) == nil
}
