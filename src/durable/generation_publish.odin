package durable

import "core:fmt"
import "core:strings"
import db "../sqlite"
import sql ".."
import snapshot "../snapshot"

Generation_Phase :: enum {
	None, Image_Checked, Before_Application_Step, After_Application_Step, Application_Copied,
	Before_Suffix_Commit, Suffix_Copied, Base_Written, Recovered, Before_Identity_Commit,
	Before_Directory_Sync, Ready, After_Directory_Sync, Before_Publication,
	Before_Catalog_Commit, After_Publication,
	After_Retirement_Files, After_Retirement_Sync, Before_Retirement_Commit,
	Before_Outcome_Trim_Commit, After_Outcome_Trim_Commit,
	After_Root_Retirement_Files, After_Root_Retirement_Sync, Before_Root_Retirement_Commit,
	After_Image_Retirement_Files, After_Image_Retirement_Sync, Before_Image_Retirement_Commit,
}

// Explicit maintenance publication. The caller serializes the host and adopts
// the returned host before processing another request. The old host is poisoned
// at the publication attempt, including an ambiguous commit failure. Its files
// remain intact; it must be closed. The stable root guard transfers only after
// publication succeeds. Crash recovery always consults the root catalog.
compact_store :: proc(source: ^Host, cluster: string,
	checkpoint: proc(Generation_Phase) = nil) -> (^Host, Error) {
	if source == nil || source.poisoned || !source.store_guard_owned ||
		source.snapshot == nil || source.snapshot_busy || snapshot_worker_running(source.snapshot) ||
		source.snapshot_sealed.key.prefix <= source.generation_base.key.prefix { return nil, .Invalid }
	prefix := source.snapshot_sealed.key.prefix
	image := fmt.aprintf("%s/image-%d.db", source.snapshot.directory, prefix)
	manifest := fmt.aprintf("%s/image-%d.manifest", source.snapshot.directory, prefix)
	defer delete(image)
	defer delete(manifest)
	candidate, candidate_err := snapshot.candidate_load(manifest, source.snapshot_sealed.key)
	if candidate_err != .None do return nil, .Storage
	if !generation_space_available(source, candidate.bytes) do return nil, .Backpressure
	token, token_err := next_id(source, 0)
	if token_err != .None do return nil, token_err
	name := fmt.aprintf("generation-%d-%d", prefix, token)
	defer delete(name)
	directory := fmt.aprintf("%s/%s", source.store_root, name)
	defer delete(directory)
	if !create_generation_directory(source, name) do return nil, .Storage
	application := fmt.aprintf("%s/node.db", directory)
	consensus := fmt.aprintf("%s/consensus.db", directory)
	defer delete(application)
	defer delete(consensus)
	if err := build_generation(source, image, application, consensus,
		cluster, candidate, checkpoint = checkpoint); err != .None { return nil, err }
	return publish_built_generation(source, application, consensus, directory, name, cluster, checkpoint)
}

@(private)
publish_built_generation :: proc(source: ^Host, application, consensus, directory, name, cluster: string,
	checkpoint: proc(Generation_Phase)) -> (^Host, Error) {
	members := source.node.membership
	next, err := open(application, cluster, source.node.id, sql.membership_slice(&members),
		consensus_path = consensus)
	if err != .None do return nil, err
	result, publish_err := publish_open_generation(source, next, application, directory, name, checkpoint)
	if publish_err != .None do close(next)
	return result, publish_err
}

@(private)
publish_open_generation :: proc(source, next: ^Host, application, directory, name: string,
	checkpoint: proc(Generation_Phase)) -> (^Host, Error) {
	if source.snapshot != nil &&
		snapshot_enable(next, application, source.snapshot.directory) != .None { return nil, .Storage }
	if !sync_directory(application) || !sync_directory(directory) do return nil, .Storage
	if checkpoint != nil do checkpoint(.After_Directory_Sync)
	catalog, ok := open_catalog(source.store_root, verify = false)
	if !ok do return nil, .Storage
	defer db.close(catalog)
	if checkpoint != nil do checkpoint(.Before_Publication)
	source.poisoned = true
	if !write_generation(catalog, name, checkpoint) do return nil, .Storage
	if checkpoint != nil do checkpoint(.After_Publication)
	next.store_root = strings.clone(source.store_root)
	next.store_current = strings.clone(name)
	next.store_guard, next.store_guard_owned = source.store_guard, true
	source.store_guard_owned = false
	next.active_read = source.active_read
	return next, .None
}
