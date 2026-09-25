package tests

import "core:fmt"
import "core:os"
import "core:testing"
import sql "../src"
import snapshot "../src/snapshot"

@(test)
test_snapshot_receipt_requires_verified_durable_retention :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	source := fmt.aprintf("%s/application.db", dir)
	image := fmt.aprintf("%s/image.db", dir)
	defer delete(source)
	defer delete(image)
	e, open_err := sql.engine_open(source, 1)
	testing.expect(t, open_err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	skip := sql.mutation_make_skip(0, 0)
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &skip) == .None)
	job: snapshot.Image_Copy
	defer snapshot.image_cancel(&job)
	testing.expect(t, snapshot.image_begin(&job, source, image, 1024*1024) == .None)
	for _ in 0..<8 {
		if job.phase == .Copied do break
		testing.expect(t, snapshot.image_step(&job) == .None)
	}
	hash, hash_err := snapshot.logical_digest(image, 1)
	testing.expect_value(t, hash_err, snapshot.Image_Error.None)
	key := snapshot.Key{generation = 1, prefix = 1,
		engine = sql.engine_build_fingerprint(), logical_state = hash}
	key.configuration[0] = 1
	candidate, candidate_err := snapshot.candidate_from_copy(&job, key)
	testing.expect(t, candidate_err == .None)
	members := [3]sql.Node_Id{1, 2, 3}
	for fault in snapshot.Manifest_Fault {
		manifest := fmt.aprintf("%s/manifest-%d", dir, int(fault))
		defer delete(manifest)
		receipt, err := snapshot.retain(image, manifest, candidate, key, 1, members[:], fault = fault)
		if fault != .None {
			testing.expect(t, err == .Storage && receipt == snapshot.Receipt{})
			recovered, recovery_err := snapshot.recover_retained(image, manifest, key, 1, members[:])
			testing.expect(t, recovery_err == .None && recovered ==
				snapshot.Receipt{1, key, job.hash, job.bytes})
			wrong := key
			wrong.prefix += 1
			recovered, recovery_err = snapshot.recover_retained(image, manifest, wrong, 1, members[:])
			testing.expect(t, recovery_err == .Invalid_Source && recovered == snapshot.Receipt{})
			continue
		}
		testing.expect(t, err == .None && receipt == snapshot.Receipt{1, key, job.hash, job.bytes})
		loaded, load_err := snapshot.candidate_load(manifest, key)
		testing.expect(t, load_err == .None && loaded == candidate)
		testing.expect(t, snapshot.candidate_check(image, loaded, key) == .None)
	}
	manifest := fmt.aprintf("%s/rejected", dir)
	defer delete(manifest)
	receipt, err := snapshot.retain(image, manifest, candidate, key, 4, members[:])
	testing.expect(t, err == .Invalid && receipt == snapshot.Receipt{})
	candidate.key.logical_state[0] ~= 1
	receipt, err = snapshot.retain(image, manifest, candidate, candidate.key, 1, members[:])
	testing.expect(t, err == .Invalid_Source && receipt == snapshot.Receipt{})
	// Refusal must not leave a manifest that a later recovery could advertise.
	_, err = snapshot.candidate_load(manifest, candidate.key)
	testing.expect(t, err == .Storage)
}
