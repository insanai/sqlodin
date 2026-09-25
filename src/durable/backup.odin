package durable

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import sql ".."
import db "../sqlite"

Backup_Phase :: enum {
	Before_Image_Step, After_Image_Step, Image_Copied, Image_Synced,
	Image_Verified, Before_Manifest, Before_Manifest_Sync, After_Manifest_Sync, Manifest_Durable,
}

// The caller serializes this host; the CLI opens a stopped voter under its stable
// root lock. No acceptor state is exported and the source is never rewritten.
backup_store :: proc(h: ^Host, cluster, destination: string,
	checkpoint: proc(Backup_Phase) = nil) -> (Backup_Manifest, Error) {
	if h == nil || h.poisoned || !h.store_guard_owned || h.consensus == nil ||
		h.sequence != h.durable_sequence || len(cluster) == 0 || len(cluster) > 128 { return {}, .Invalid }
	if h.compaction != nil || h.snapshot_busy do return {}, .Backpressure
	members := sql.membership_slice(&h.node.membership)
	if !application_identity(h, cluster, members, false) do return {}, .Storage
	bytes, measured := database_size(h.engine.db)
	if !measured || bytes > 128*1024*1024*1024 ||
		!space_available(filepath.dir(destination), bytes+MINIMUM_FREE_RESERVE) { return {}, .Backpressure }
	name := strings.clone_to_cstring(destination)
	defer delete(name)
	if posix.mkdir(name, {.IRUSR, .IWUSR, .IXUSR}) != nil do return {}, .Storage
	if !sync_directory(destination) do return {}, .Storage
	path := fmt.aprintf("%s/application.db", destination)
	defer delete(path)
	path_text := strings.clone_to_cstring(path)
	defer delete(path_text)
	file := posix.open(path_text, {.RDWR, .CREAT, .EXCL, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if file < 0 do return {}, .Storage
	posix.close(file)
	if !migration_copy_application(h.engine.db, path, 128*1024*1024*1024,
		time.tick_now(), DEFAULT_MAINTENANCE_SECONDS, backup_checkpoint = checkpoint) {
		return {}, .Storage
	}
	if checkpoint != nil do checkpoint(.Image_Copied)
	if !backup_seal_image(path) do return {}, .Storage
	if checkpoint != nil do checkpoint(.Image_Synced)
	m := Backup_Manifest{engine = sql.engine_build_fingerprint(), configuration = h.configuration,
		prefix = h.engine.applied_through, cluster_len = u16(len(cluster)), member_count = u8(len(members))}
	copy(m.cluster[:], cluster)
	copy(m.members[:], members)
	valid: bool
	m.image, m.bytes, valid = backup_file_hash(path, time.tick_now())
	if !valid || !backup_check_image(path, m) do return {}, .Storage
	if checkpoint != nil { checkpoint(.Image_Verified); checkpoint(.Before_Manifest) }
	if !backup_write_manifest(fmt.tprintf("%s/backup.manifest", destination), m, checkpoint) {
		return {}, .Storage
	}
	if checkpoint != nil do checkpoint(.Manifest_Durable)
	return m, .None
}

@(private)
backup_seal_image :: proc(path: string) -> bool {
	image, opened := db.open(path)
	if !opened do return false
	ok := db.exec(image, "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA journal_mode=DELETE;")
	closed := db.close(image)
	if !ok || !closed do return false
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.RDWR, .NOFOLLOW})
	if file < 0 do return false
	defer posix.close(file)
	return backup_sync(file) && sync_directory(path)
}
