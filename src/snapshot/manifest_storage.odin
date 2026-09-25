package snapshot

import "core:c"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

Manifest_Fault :: enum { None, Before_File_Sync, After_File_Sync, After_Directory_Sync }

// The owner stores this immutable description in its private candidate directory.
// Success means both file contents and name passed their durability barriers.
// This does not attest to logical-image verification or issue a voter receipt.
candidate_store :: proc(
	path: string, candidate: Candidate, expected: Key, fault: Manifest_Fault = .None,
) -> Image_Error {
	encoded, err := candidate_encode(candidate, expected)
	if err != .None || !candidate_path_valid(path) do return .Invalid
	name := strings.clone_to_cstring(path)
	defer delete(name)
	parent := strings.clone_to_cstring(filepath.dir(path))
	defer delete(parent)
	dir := posix.open(parent, {.DIRECTORY, .NOFOLLOW})
	if dir < 0 do return .Storage
	defer posix.close(dir)
	file := posix.open(name, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if file < 0 do return .Storage
	defer posix.close(file)
	position := 0
	for position < encoded.count {
		written := posix.write(file, raw_data(encoded.bytes[position:]), c.size_t(encoded.count-position))
		if written <= 0 do return .Storage
		position += int(written)
	}
	if fault == .Before_File_Sync do return .Storage
	if !manifest_sync_file(file) do return .Storage
	if fault == .After_File_Sync do return .Storage
	if posix.fsync(dir) != nil do return .Storage
	if fault == .After_Directory_Sync do return .Storage
	return .None
}

// Read-only recovery rejects every incomplete, oversized or corrupt description.
// Callers must still open/verify its image, retained identity and chosen seal.
candidate_load :: proc(path: string, expected: Key) -> (Candidate, Image_Error) {
	if !candidate_path_valid(path) do return {}, .Invalid
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.NOFOLLOW, .NONBLOCK})
	if file < 0 do return {}, .Storage
	defer posix.close(file)
	stat: posix.stat_t
	if posix.fstat(file, &stat) != nil || !posix.S_ISREG(stat.st_mode) ||
	   stat.st_size != CANDIDATE_SIZE { return {}, .Invalid_Source }
	bytes: [CANDIDATE_SIZE]u8
	position := 0
	for position < len(bytes) {
		count := posix.read(file, raw_data(bytes[position:]), c.size_t(len(bytes)-position))
		if count <= 0 do return {}, .Storage
		position += int(count)
	}
	result, err := candidate_decode(bytes[:], expected)
	if err != .None do return {}, .Invalid_Source
	return result, .None
}

@(private)
candidate_path_valid :: proc(path: string) -> bool {
	return path != "" && path != ":memory:" && !strings.has_prefix(path, "file:") &&
		!strings.contains(path, "\x00")
}

@(private)
manifest_sync_file :: proc(file: posix.FD) -> bool {
	if posix.fsync(file) != nil do return false
	when ODIN_OS == .Darwin {
		// Darwin sys/fcntl.h: F_FULLFSYNC=51 asks the device to flush to media.
		return posix.fcntl(file, posix.FCNTL_Cmd(51)) == 0
	} else {
		return true
	}
}
