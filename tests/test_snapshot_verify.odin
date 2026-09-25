package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import sql "../src"
import snapshot "../src/snapshot"

@(test)
test_snapshot_verifier_rejects_foreign_keys_and_nonempty_wal :: proc(t: ^testing.T) {
	dir := snapshot_test_directory(t)
	defer delete(dir)
	defer os.remove_all(dir)
	source := fmt.aprintf("%s/application.db", dir)
	defer delete(source)
	e, open_err := sql.engine_open(source, 1)
	testing.expect(t, open_err == .None)
	defer sql.engine_close(&e)
	testing.expect(t, sql.engine_initialize_outcomes(&e))
	testing.expect(t, sql.engine_exec(&e, "PRAGMA foreign_keys=OFF;" +
		"CREATE TABLE parent(id INTEGER PRIMARY KEY);" +
		"CREATE TABLE child(id INTEGER PRIMARY KEY,p REFERENCES parent(id));") == .None)
	for pass in 1..=2 {
		if pass == 2 do testing.expect(t, sql.engine_exec(&e, "INSERT INTO child VALUES(1,999);") == .None)
		skip := sql.mutation_make_skip(0, 0)
		testing.expect(t, sql.engine_apply_outcome(&e, sql.Slot(pass), &skip) == .None)
		path := fmt.aprintf("%s/image-%d.db", dir, pass)
		defer delete(path)
		job: snapshot.Image_Copy
		defer snapshot.image_cancel(&job)
		testing.expect(t, snapshot.image_begin(&job, source, path, 1024*1024) == .None)
		for _ in 0..<8 {
			if job.phase == .Copied do break
			testing.expect(t, snapshot.image_step(&job) == .None)
		}
		testing.expect(t, job.phase == .Copied)
		key := snapshot.Key{generation = 1, prefix = job.prefix, engine = sql.engine_build_fingerprint()}
		key.configuration[0], key.logical_state[0] = 1, 3
		candidate, err := snapshot.candidate_from_copy(&job, key)
		testing.expect(t, err == .None)
		expected := snapshot.Image_Error.None if pass == 1 else .Invalid_Source
		testing.expect_value(t, snapshot.candidate_check_file(path, candidate, key, 1024*1024), expected)
		if pass == 2 do continue
		wrong := candidate
		wrong.key.engine[0] ~= 1
		testing.expect(t, snapshot.candidate_check_file(path, wrong, wrong.key,
			1024*1024) == .Invalid_Source)
		wal := fmt.aprintf("%s-wal", path)
		defer delete(wal)
		name := strings.clone_to_cstring(wal)
		defer delete(name)
		fd := posix.open(name, {.WRONLY, .CREAT, .TRUNC, .NOFOLLOW}, {.IRUSR, .IWUSR})
		testing.expect(t, fd >= 0)
		byte: u8 = 1
		testing.expect(t, posix.write(fd, &byte, 1) == 1)
		posix.close(fd)
		testing.expect(t, snapshot.candidate_check_file(path, candidate, key, 1024*1024) == .Invalid_Source)
	}
}
