package tests

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import sql "../src"
import snapshot "../src/snapshot"
import durable "../src/durable"

@(test)
test_snapshot_cancellation_releases_copy_and_prevents_verification_receipt :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	source := fmt.aprintf("%s/source.db", root)
	image := fmt.aprintf("%s/image.db", root)
	defer delete(source); defer delete(image)
	e, err := sql.engine_open(source, 1)
	testing.expect(t, err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_exec(&e, "CREATE TABLE t(v); INSERT INTO t VALUES('kept');") == .None)
	skip := sql.mutation_make_skip(0, 0)
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &skip) == .None)
	flag: u32
	job: snapshot.Image_Copy
	testing.expect(t, snapshot.image_begin(&job, source, image, 1024*1024) == .None)
	job.cancel = &flag
	sync.atomic_store(&flag, 1)
	testing.expect_value(t, snapshot.image_step(&job), snapshot.Image_Error.Cancelled)
	testing.expect(t, job.source == nil && job.destination == nil && job.backup == nil)
	testing.expect(t, !job.file_open && !job.directory_open)
	expect_rows(t, &e, "SELECT * FROM t", 1)
	limits := snapshot.DEFAULT_LOGICAL_LIMITS
	limits.cancel = &flag
	_, logical_err := snapshot.logical_digest(source, 1, limits)
	testing.expect_value(t, logical_err, snapshot.Image_Error.Cancelled)
	key := snapshot.Key{generation = 1, prefix = 1, engine = sql.engine_build_fingerprint()}
	key.configuration[0], key.logical_state[0] = 1, 1
	candidate := snapshot.Candidate{key = key, bytes = 4096}
	candidate.image[0] = 1
	testing.expect_value(t, snapshot.candidate_check(source, candidate, key, limits),
		snapshot.Image_Error.Cancelled)
	// Owner cancellation reaches the worker before it can issue any receipt.
	work := durable.Snapshot_Work{cancel = 1}
	work.copy.phase = .Copying
	worker := thread.Thread{data = &work}
	durable.snapshot_worker(&worker)
	testing.expect_value(t, work.error, snapshot.Image_Error.Cancelled)
	testing.expect(t, sync.atomic_load(&work.done) == 1)
	testing.expect(t, work.receipt == snapshot.Receipt{})
}
