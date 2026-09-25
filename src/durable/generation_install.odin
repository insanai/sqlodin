package durable

import "core:fmt"
import "core:os"
import "core:path/filepath"
import sql ".."
import snapshot "../snapshot"

// Install a received, independently verified image and its authenticated chosen
// seal. Only the local journal contributes promises, votes, IDs and suffix state.
// The serialized owner must stop accepting transitions during this maintenance
// call and replace the host with the returned one before processing more input.
install_store :: proc(
	source: ^Host, authenticated_peer: sql.Node_Id, image, cluster: string,
	candidate: snapshot.Candidate, seal: Generation_Seal,
	checkpoint: proc(Generation_Phase) = nil,
) -> (^Host, Error) {
	if source == nil || source.poisoned || !source.store_guard_owned || source.snapshot == nil ||
		authenticated_peer == source.node.id ||
		!sql.membership_contains(&source.node.membership, authenticated_peer) { return nil, .Invalid }
	if source.compaction != nil || snapshot_worker_running(source.snapshot) do return nil, .Backpressure
	chosen_seal := seal
	if !generation_seal_valid(source, &chosen_seal) || candidate.key != seal.certificate.key ||
		candidate.key.prefix <= source.engine.applied_through { return nil, .Invalid }
	if !generation_space_available(source, candidate.bytes) do return nil, .Backpressure
	canonical, path_err := os.get_absolute_path(image, context.allocator)
	if path_err != nil do return nil, .Storage
	defer delete(canonical)
	if filepath.dir(canonical) != source.snapshot.directory do return nil, .Invalid
	manifest := fmt.aprintf("%s.manifest", canonical)
	defer delete(manifest)
	if !retain_received_image(source, canonical, manifest, candidate) do return nil, .Storage
	token, token_err := next_id(source, 0)
	if token_err != .None do return nil, token_err
	name := fmt.aprintf("generation-%d-%d", candidate.key.prefix, token)
	defer delete(name)
	directory := fmt.aprintf("%s/%s", source.store_root, name)
	defer delete(directory)
	if !create_generation_directory(source, name) do return nil, .Storage
	application := fmt.aprintf("%s/node.db", directory)
	consensus := fmt.aprintf("%s/consensus.db", directory)
	defer delete(application)
	defer delete(consensus)
	if err := build_generation(source, canonical, application, consensus, cluster, candidate,
		received = &chosen_seal, checkpoint = checkpoint); err != .None { return nil, err }
	return publish_built_generation(source, application, consensus, directory, name, cluster, checkpoint)
}

@(private)
retain_received_image :: proc(h: ^Host, image, manifest: string, candidate: snapshot.Candidate) -> bool {
	members := sql.membership_slice(&h.node.membership)
	receipt: snapshot.Receipt
	err: snapshot.Image_Error
	if os.exists(manifest) {
		receipt, err = snapshot.recover_retained(image, manifest, candidate.key, h.node.id, members)
	} else {
		receipt, err = snapshot.retain(image, manifest, candidate, candidate.key, h.node.id, members)
	}
	return err == .None && receipt.image == candidate.image && receipt.bytes == candidate.bytes
}
