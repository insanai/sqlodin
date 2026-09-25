package tests

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import durable "../src/durable"
import snapshot "../src/snapshot"
import sql "../src"

Generation_Cancel_Test :: struct { flag: u32, phase: durable.Generation_Phase }

generation_cancel_checkpoint :: proc(phase: durable.Generation_Phase) {
	state := cast(^Generation_Cancel_Test)context.user_ptr
	if phase == state.phase do sync.atomic_store(&state.flag, 1)
}

@(test)
test_generation_cancellation_preserves_source_and_releases_private_locks :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	image := fmt.aprintf("%s/image-%d.db", h.snapshot.directory, h.snapshot_sealed.key.prefix)
	manifest := fmt.aprintf("%s/image-%d.manifest", h.snapshot.directory, h.snapshot_sealed.key.prefix)
	defer delete(image); defer delete(manifest)
	candidate, loaded := snapshot.candidate_load(manifest, h.snapshot_sealed.key)
	testing.expect(t, loaded == .None)
	previous := context.user_ptr
	defer context.user_ptr = previous
	for phase in ([?]durable.Generation_Phase{
		.Image_Checked, .After_Application_Step, .Application_Copied, .Suffix_Copied,
		.Base_Written, .Recovered, .Ready,
	}) {
		directory := fmt.aprintf("%s/cancel-%v", c.directories[0], phase)
		defer delete(directory)
		testing.expect(t, os.make_directory(directory) == nil)
		application := fmt.aprintf("%s/node.db", directory)
		consensus := fmt.aprintf("%s/consensus.db", directory)
		defer delete(application); defer delete(consensus)
		state := Generation_Cancel_Test{phase = phase}
		context.user_ptr = &state
		err := durable.build_generation(h, image, application, consensus, "test", candidate,
			checkpoint = generation_cancel_checkpoint, cancel = &state.flag)
		testing.expect_value(t, err, durable.Error.Storage)
		testing.expect(t, state.flag == 1 && !h.poisoned && h.store_current == "")
		// Cancellation owns only the private build. The live acceptor still writes.
		insert, _ := sql.mutation_make_raw_sql(1, 0, "INSERT INTO t VALUES(9)")
		install_test_commit(t, h, h.engine.applied_through+1, insert)
		lock, locked := durable.lock_database(application, false)
		testing.expect(t, locked)
		if locked do posix.close(lock)
	}
}
