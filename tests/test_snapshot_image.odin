package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:sys/posix"
import sql "../src"
import db "../src/sqlite"
import durable "../src/durable"
import snapshot "../src/snapshot"

snapshot_test_directory :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "sqlodin-image-", context.allocator)
	testing.expect(t, err == nil)
	defer delete(path)
	// macOS's /var and /tmp are aliases. The copier deliberately requires paths
	// without symlinks, including ancestors; resolve this trusted test directory.
	canonical, canonical_err := os.get_absolute_path(path, context.allocator)
	testing.expect(t, canonical_err == nil)
	return canonical
}

@(test)
test_snapshot_image_pins_prefix_during_wal_writes :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	source := fmt.aprintf("%s/application.db", dir)
	destination := fmt.aprintf("%s/image.db", dir)
	defer delete(source)
	defer delete(destination)
	e, open_err := sql.engine_open(source, 1)
	testing.expect(t, open_err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_exec(&e,
		"CREATE TABLE items(id INTEGER PRIMARY KEY, payload TEXT);" +
		"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<5000) " +
		"INSERT INTO items SELECT i,hex(zeroblob(128)) FROM n;") == .None)
	skip := sql.mutation_make_skip(0, 0)
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &skip) == .None)
	job: snapshot.Image_Copy
	defer snapshot.image_cancel(&job)
	testing.expect(t, snapshot.image_begin(&job, source, destination, 8*1024*1024) == .None)
	testing.expect(t, job.prefix == 1)
	testing.expect(t, snapshot.image_step(&job) == .None && job.phase == .Copying)
	// A different WAL connection commits after the copier has pinned prefix one.
	testing.expect(t, sql.engine_exec(&e,
		"DELETE FROM items; INSERT INTO items VALUES(6000,'later');") == .None)
	testing.expect(t, sql.engine_apply_outcome(&e, 2, &skip) == .None)
	for _ in 0..<32 {
		if job.phase == .Copied do break
		testing.expect(t, snapshot.image_step(&job) == .None)
	}
	testing.expect(t, job.phase == .Copied && job.prefix == 1 && job.bytes > 1024*1024)
	testing.expect(t, job.hash != [32]u8{} && !job.file_open && job.source == nil)
	bytes, read_err := os.read_entire_file(destination, context.allocator)
	testing.expect(t, read_err == nil && u64(len(bytes)) == job.bytes)
	testing.expect(t, durable.digest(bytes) == job.hash)
	delete(bytes)
	check_snapshot_candidate(t, &job, destination)
	image, image_err := sql.engine_open(destination, 1)
	testing.expect(t, image_err == .None)
	defer sql.engine_close(&image)
	testing.expect(t, image.applied_through == 1)
	expect_rows(t, &image, "SELECT * FROM items WHERE id BETWEEN 1 AND 5000;", 5000)
	expect_rows(t, &image, "SELECT * FROM items WHERE id=6000;", 0)
	// Destination reuse must fail, preserving the already completed image.
	other: snapshot.Image_Copy
	defer snapshot.image_cancel(&other)
	testing.expect(t, snapshot.image_begin(&other, source, destination, 8*1024*1024) == .Storage)
}

check_snapshot_candidate :: proc(t: ^testing.T, job: ^snapshot.Image_Copy, path: string) {
	key := snapshot.Key{generation = 1, prefix = job.prefix, engine = sql.engine_build_fingerprint()}
	key.configuration[0] = 1
	logical, logical_err := snapshot.logical_digest(path, job.prefix)
	testing.expect_value(t, logical_err, snapshot.Image_Error.None)
	key.logical_state = logical
	candidate, err := snapshot.candidate_from_copy(job, key)
	testing.expect(t, err == .None)
	manifest := fmt.aprintf("%s.manifest", path)
	defer delete(manifest)
	testing.expect(t, snapshot.candidate_store(manifest, candidate, key) == .None)
	loaded, load_err := snapshot.candidate_load(manifest, key)
	testing.expect(t, load_err == .None && loaded == candidate)
	testing.expect(t, snapshot.candidate_check(path, loaded, key) == .None)
	wrong_logical := loaded
	wrong_logical.key.logical_state[0] ~= 1
	// A valid byte hash and self-consistent manifest must not mask wrong SQL state.
	testing.expect(t, snapshot.candidate_check(path, wrong_logical,
		wrong_logical.key) == .Invalid_Source)
	testing.expect(t, snapshot.candidate_check_file(path, loaded, key, 4096) == .Limit)
	testing.expect_value(t, snapshot.candidate_check_file(path, loaded, key,
		8*1024*1024, instructions = 1000), snapshot.Image_Error.Limit)
	wrong := loaded
	wrong.image[0] ~= 1
	testing.expect(t, snapshot.candidate_check_file(path, wrong, key, 8*1024*1024) == .Invalid_Source)
	wrong = loaded
	wrong.bytes -= 1
	testing.expect(t, snapshot.candidate_check_file(path, wrong, key, 8*1024*1024) == .Invalid_Source)
}

@(test)
test_snapshot_image_refuses_acceptor_state :: proc(t: ^testing.T) {
	c := durable_test_open(t, 1)
	defer durable_test_close(c)
	transaction_test_schema(t, c.hosts[0], "CREATE TABLE t(v);")
	destination := fmt.aprintf("%s/rejected.db", c.dir)
	defer delete(destination)
	job: snapshot.Image_Copy
	defer snapshot.image_cancel(&job)
	source, path_err := os.get_absolute_path(c.paths[0], context.allocator)
	testing.expect(t, path_err == nil)
	defer delete(source)
	testing.expect(t, snapshot.image_begin(&job, source, destination, 8*1024*1024) == .Invalid_Source)
	testing.expect(t, job.source == nil && job.destination == nil && !job.file_open)
	// A rejected format-4 export must leave the live database usable.
	testing.expect(t, db.exec(c.hosts[0].engine.db, "PRAGMA integrity_check"))
}

@(test)
test_snapshot_image_cancellation_limits_and_short_file :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	source := fmt.aprintf("%s/application.db", dir)
	defer delete(source)
	e, open_err := sql.engine_open(source, 1)
	testing.expect(t, open_err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	skip := sql.mutation_make_skip(0, 0)
	testing.expect(t, sql.engine_apply_outcome(&e, 1, &skip) == .None)
	for mode in 0..<4 {
		destination := fmt.aprintf("%s/image-%d.db", dir, mode)
		defer delete(destination)
		job: snapshot.Image_Copy
		defer snapshot.image_cancel(&job)
		limit := u64(4096) if mode == 0 else 1024*1024
		err := snapshot.image_begin(&job, source, destination, limit)
		if mode == 0 {
			testing.expect(t, err == .Invalid_Source)
		} else {
			testing.expect(t, err == .None)
			switch mode {
			case 1:
				snapshot.image_cancel(&job)
				testing.expect(t, job.phase == .Cancelled)
			case 2:
				job.deadline = 0
				testing.expect(t, snapshot.image_step(&job) == .Timeout && job.phase == .Failed)
			case 3:
				testing.expect(t, snapshot.image_step(&job) == .None && job.phase == .Hashing)
				testing.expect(t, posix.ftruncate(job.file, 0) == nil)
				testing.expect(t, snapshot.image_step(&job) == .Storage && job.phase == .Failed)
			}
		}
		testing.expect(t, job.source == nil && job.destination == nil && !job.file_open)
		testing.expect(t, job.hash == [32]u8{})
	}
	testing.expect(t, sql.engine_apply_outcome(&e, 2, &skip) == .None)
}
