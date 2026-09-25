package durable

import "core:c"
import "core:crypto/sha2"
import "core:strings"
import "core:sys/posix"
import "core:time"

@(private)
backup_sync :: proc(file: posix.FD) -> bool {
	if posix.fsync(file) != nil do return false
	when ODIN_OS == .Darwin {
		return posix.fcntl(file, posix.FCNTL_Cmd(51)) == 0
	} else { return true }
}

@(private)
backup_write_manifest :: proc(path: string, m: Backup_Manifest,
	checkpoint: proc(Backup_Phase)) -> bool {
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if file < 0 do return false
	defer posix.close(file)
	bytes := backup_manifest_encode(m)
	for position := 0; position < len(bytes); {
		count := posix.write(file, raw_data(bytes[position:]), c.size_t(len(bytes)-position))
		if count <= 0 do return false
		position += int(count)
	}
	if checkpoint != nil do checkpoint(.Before_Manifest_Sync)
	if !backup_sync(file) do return false
	if checkpoint != nil do checkpoint(.After_Manifest_Sync)
	return sync_directory(path)
}

@(private)
backup_read_manifest :: proc(path: string) -> (Backup_Manifest, bool) {
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.NOFOLLOW, .NONBLOCK})
	if file < 0 do return {}, false
	defer posix.close(file)
	info: posix.stat_t
	if posix.fstat(file, &info) != nil || !posix.S_ISREG(info.st_mode) ||
		info.st_size != BACKUP_MANIFEST_SIZE { return {}, false }
	bytes: [BACKUP_MANIFEST_SIZE]u8
	for position := 0; position < len(bytes); {
		count := posix.read(file, raw_data(bytes[position:]), c.size_t(len(bytes)-position))
		if count <= 0 do return {}, false
		position += int(count)
	}
	return backup_manifest_decode(bytes[:])
}

@(private)
backup_file_hash :: proc(path: string, started: time.Tick) -> (hash: [32]u8, size: u64, ok: bool) {
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.NOFOLLOW, .NONBLOCK})
	if file < 0 do return
	defer posix.close(file)
	info: posix.stat_t
	if posix.fstat(file, &info) != nil || !posix.S_ISREG(info.st_mode) || info.st_size < 4096 ||
		u64(info.st_size) > 128*1024*1024*1024 { return }
	size = u64(info.st_size)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buffer: [64*1024]u8
	for offset: u64 = 0; offset < size; {
		if time.tick_since(started) >= DEFAULT_MAINTENANCE_DURATION do return
		want := min(size-offset, u64(len(buffer)))
		count := posix.read(file, raw_data(buffer[:]), c.size_t(want))
		if count <= 0 do return
		sha2.update(&ctx, buffer[:int(count)])
		offset += u64(count)
	}
	if posix.fstat(file, &info) != nil || u64(info.st_size) != size do return
	sha2.final(&ctx, hash[:])
	return hash, size, true
}
