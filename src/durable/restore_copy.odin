package durable

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Backups are verified closed single-file images. Preserve their exact bytes in
// private staging before checking the manifest again; SQLite's backup API may
// legitimately change destination header counters and hence its physical hash.
@(private)
restore_copy_image :: proc(source, destination: string, checkpoint: proc(Restore_Phase)) -> bool {
	src, dst := strings.clone_to_cstring(source), strings.clone_to_cstring(destination)
	defer delete(src)
	defer delete(dst)
	input := posix.open(src, {.NOFOLLOW, .NONBLOCK})
	if input < 0 do return false
	defer posix.close(input)
	output := posix.open(dst, {.WRONLY, .NOFOLLOW, .NONBLOCK})
	if output < 0 do return false
	defer posix.close(output)
	in_info, out_info: posix.stat_t
	if posix.fstat(input, &in_info) != nil || !posix.S_ISREG(in_info.st_mode) ||
		in_info.st_size < 4096 || u64(in_info.st_size) > 128*1024*1024*1024 ||
		posix.fstat(output, &out_info) != nil || !posix.S_ISREG(out_info.st_mode) ||
		out_info.st_size != 0 { return false }
	started := time.tick_now()
	buffer: [64*1024]u8
	for offset: u64 = 0; offset < u64(in_info.st_size); {
		if time.tick_since(started) >= DEFAULT_MAINTENANCE_DURATION do return false
		if checkpoint != nil do checkpoint(.Before_Image_Step)
		want := min(u64(in_info.st_size)-offset, u64(len(buffer)))
		count := posix.read(input, raw_data(buffer[:]), c.size_t(want))
		if count <= 0 do return false
		for written := 0; written < int(count); {
			n := posix.write(output, raw_data(buffer[written:]), c.size_t(int(count)-written))
			if n <= 0 do return false
			written += int(n)
		}
		offset += u64(count)
		if checkpoint != nil do checkpoint(.After_Image_Step)
	}
	return backup_sync(output) && sync_directory(destination)
}
