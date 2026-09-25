package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import snapshot "../src/snapshot"

snapshot_test_candidate :: proc() -> snapshot.Candidate {
	key := snapshot.Key{generation = 1, prefix = 100}
	key.configuration[0], key.engine[0], key.logical_state[0] = 1, 2, 3
	result := snapshot.Candidate{key = key, bytes = 4096}
	result.image[0] = 4
	return result
}

@(test)
test_snapshot_manifest_detects_every_truncation_and_bit_change :: proc(t: ^testing.T) {
	candidate := snapshot_test_candidate()
	encoded, err := snapshot.candidate_encode(candidate, candidate.key)
	testing.expect(t, err == .None && encoded.count == snapshot.CANDIDATE_SIZE)
	actual, decode_err := snapshot.candidate_decode(encoded.bytes[:encoded.count], candidate.key)
	testing.expect(t, decode_err == .None && actual == candidate)
	for size in 0..<encoded.count {
		_, decode_err = snapshot.candidate_decode(encoded.bytes[:size], candidate.key)
		testing.expect(t, decode_err == .Invalid_Image)
	}
	for position in 0..<encoded.count {
		for bit in 0..<8 {
			changed := encoded
			changed.bytes[position] ~= u8(1 << uint(bit))
			_, decode_err = snapshot.candidate_decode(changed.bytes[:changed.count], candidate.key)
			testing.expect(t, decode_err == .Invalid_Image)
		}
	}
	key := candidate.key
	key.prefix += 1
	_, decode_err = snapshot.candidate_decode(encoded.bytes[:encoded.count], key)
	testing.expect(t, decode_err == .Wrong_Key)
	job: snapshot.Image_Copy
	_, err = snapshot.candidate_from_copy(&job, candidate.key)
	testing.expect(t, err == .Invalid_Image)
}

@(test)
test_snapshot_manifest_exclusive_storage_and_failure_boundaries :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	candidate := snapshot_test_candidate()
	for step in 0..<4 {
		path := fmt.aprintf("%s/manifest-%d.bin", dir, step)
		defer delete(path)
		fault := snapshot.Manifest_Fault(step)
		err := snapshot.candidate_store(path, candidate, candidate.key, fault)
		expected := snapshot.Image_Error.None if fault == .None else .Storage
		testing.expect(t, err == expected)
		// Injected return failures must not report durable publication. The file
		// can already be complete; loading it never implies a receipt or trim seal.
		loaded, load_err := snapshot.candidate_load(path, candidate.key)
		testing.expect(t, load_err == .None && loaded == candidate)
		testing.expect(t, snapshot.candidate_store(path, candidate, candidate.key) == .Storage)
		name := strings.clone_to_cstring(path)
		defer delete(name)
		fd := posix.open(name, {.WRONLY, .NOFOLLOW})
		testing.expect(t, fd >= 0)
		testing.expect(t, posix.ftruncate(fd, snapshot.CANDIDATE_SIZE-1) == nil)
		posix.close(fd)
		_, load_err = snapshot.candidate_load(path, candidate.key)
		testing.expect(t, load_err == .Invalid_Source)
	}
}
