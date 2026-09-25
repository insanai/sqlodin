package durable

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import sql ".."

Restore_Phase :: enum {
	Initialized, Before_Image_Step, After_Image_Step, Image_Verified,
	Application_Rebased, Files_Synced, Before_Ready_Commit, Ready,
}

// The caller must choose a globally unused namespace and fence the old group.
// Bootstrap that new fixed configuration into an exclusive
// directory. All its voters must use the identical backup. No acceptor state is
// imported; existing deployments/destinations are never modified.
restore_backup :: proc(backup, destination, cluster: string, id: sql.Node_Id,
	members: []sql.Node_Id, checkpoint: proc(Restore_Phase) = nil) -> Error {
	membership: sql.Membership(MAX_MEMBERS)
	if len(cluster) == 0 || len(cluster) > 128 || strings.contains(cluster, ";") ||
		strings.contains(cluster, "\x00") || id == 0 || id > 1023 ||
		sql.membership_init(&membership, members) != .None ||
		!sql.membership_contains(&membership, id) { return .Invalid }
	for member in members do if member > 1023 { return .Invalid }
	manifest, verify_err := verify_backup(backup)
	if verify_err != .None do return verify_err
	if string(manifest.cluster[:manifest.cluster_len]) == cluster do return .Invalid
	if !space_available(filepath.dir(destination), manifest.bytes+MINIMUM_FREE_RESERVE) {
		return .Backpressure
	}
	name := strings.clone_to_cstring(destination)
	defer delete(name)
	if posix.mkdir(name, {.IRUSR, .IWUSR, .IXUSR}) != nil do return .Storage
	if !sync_directory(destination) do return .Storage
	h := new(Host)
	h.lock, h.consensus_lock = -1, -1
	defer close(h)
	h.genesis, h.genesis_hash = manifest, genesis_digest(manifest)
	h.node.id, h.node.membership = id, membership
	application := fmt.aprintf("%s/node.db", destination)
	consensus := fmt.aprintf("%s/consensus.db", destination)
	defer delete(application)
	defer delete(consensus)
	locked: bool
	h.lock, locked = lock_database(application, true)
	if !locked || !open_consensus(h, consensus, true) ||
		!initialize(h, "sqlodin-restore-incomplete") || !sync_directory(consensus) { return .Storage }
	if checkpoint != nil do checkpoint(.Initialized)
	if !restore_copy_image(fmt.tprintf("%s/application.db", backup), application, checkpoint) ||
		!backup_check_image(application, manifest) { return .Storage }
	if checkpoint != nil do checkpoint(.Image_Verified)
	engine, engine_err := sql.engine_open(application, id)
	if engine_err != .None do return .Storage
	h.engine = engine
	if !check_storage(h) || !restore_application_identity(h, cluster, members) { return .Storage }
	if checkpoint != nil do checkpoint(.Application_Rebased)
	if sql.engine_install_limits(&h.engine) != .None ||
		sql.engine_install_function_policy(&h.engine) != .None || !recover_measured(h) ||
		!sync_directory(application) || !sync_directory(consensus) { return .Storage }
	if checkpoint != nil do checkpoint(.Files_Synced)
	if !restore_publish(h, cluster, id, members, checkpoint) do return .Storage
	if checkpoint != nil do checkpoint(.Ready)
	return .None
}

