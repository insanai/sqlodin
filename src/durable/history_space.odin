package durable

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import db "../sqlite"

HISTORY_LIMIT :: u64(8)*1024*1024*1024
// Cover two bounded writers, SQLite page/index overhead and dirty-cache flushes.
// Scale with the compiled codec instead of assuming the default vector payload.
HISTORY_TRANSITION_RESERVE :: max(u64(64)*1024*1024,
	u64(PACKED_CAPACITY)*(2*CHUNK+1)*MAX_STEP_BATCH*4+u64(32)*1024*1024)
HISTORY_ADMISSION_RESERVE :: max(u64(512)*1024*1024, 4*HISTORY_TRANSITION_RESERVE)
#assert(HISTORY_ADMISSION_RESERVE < HISTORY_LIMIT)
MAX_HISTORY_DIRECTORIES :: 64

// Count all owned consensus databases and their WAL/rollback/shared-memory
// files, including retained predecessors and abandoned private builds. User data
// and application images have separate free-space admission; they are not logs.
history_usage :: proc(h: ^Host) -> (bytes: u64, valid: bool) {
	root := history_root(h)
	if root == "" do return 0, true
	bytes, valid = history_directory_bytes(root, required = true)
	if !valid do return
	path := strings.clone_to_cstring(fmt.tprintf("%s/consensus.db", root))
	defer delete(path)
	catalog: db.Sqlite3
	if db.sqlite3_open_v2(path, &catalog, db.OPEN_READONLY | db.OPEN_NOFOLLOW, nil) != db.OK {
		if catalog != nil do db.close(catalog)
		return 0, false
	}
	defer db.close(catalog)
	required := history_required(h)
	seen := [2]bool{required[0] == "", required[1] == ""}
	count, ok := migration_integer(catalog,
		"SELECT count(*) FROM sqlite_schema WHERE name='_sqlodin_generation_inventory'")
	if !ok do return 0, false
	if count == 0 do return bytes, seen[0] && seen[1]
	stmt: db.Sqlite3_Stmt
	query := "SELECT name,digest FROM _sqlodin_generation_inventory LIMIT 65"
	if db.sqlite3_prepare_v2(catalog, cstring(raw_data(query)), c.int(len(query)), &stmt, nil) != db.OK {
		return 0, false
	}
	defer db.sqlite3_finalize(stmt)
	for index := 0; ; index += 1 {
		rc := db.sqlite3_step(stmt)
		if rc == db.DONE do return bytes, seen[0] && seen[1]
		if rc != db.ROW || index >= MAX_HISTORY_DIRECTORIES do return 0, false
		name := string(db.sqlite3_column_text(stmt, 0))
		if !valid_generation_name(name) do return 0, false
		for expected, i in required do if name == expected { seen[i] = true }
		hash, actual := digest(transmute([]u8)name), column_blob(stmt, 1)
		if len(actual) != len(hash) do return 0, false
		for byte, i in actual do if byte != hash[i] { return 0, false }
		size, measured := history_directory_bytes(fmt.tprintf("%s/%s", root, name),
			required = name == required[0] || name == required[1])
		if !measured || size > max(u64)-bytes do return 0, false
		bytes += size
	}
}

@(private)
history_root :: proc(h: ^Host) -> string {
	return h.store_root if h.store_root != "" else h.history_root
}

@(private)
history_directory_bytes :: proc(directory: string, required: bool = false) -> (u64, bool) {
	total: u64
	for suffix in ([4]string{"", "-wal", "-shm", "-journal"}) {
		name := strings.clone_to_cstring(fmt.tprintf("%s/consensus.db%s", directory, suffix))
		info: posix.stat_t
		err := posix.lstat(name, &info)
		missing := err != nil && posix.errno() == .ENOENT
		delete(name)
		if missing && (!required || suffix != "") do continue
		if err != nil || !posix.S_ISREG(info.st_mode) || info.st_size < 0 ||
			u64(info.st_size) > max(u64)-total { return 0, false }
		total += u64(info.st_size)
	}
	return total, true
}

history_admission :: proc(h: ^Host) -> Error {
	if h.poisoned do return .Poisoned
	root := history_root(h)
	if root == "" do return .None
	bytes, ok := history_usage(h)
	if !ok do return poison(h)
	if bytes > HISTORY_LIMIT-HISTORY_ADMISSION_RESERVE ||
		!space_available(root, MINIMUM_FREE_RESERVE+HISTORY_ADMISSION_RESERVE) {
		return .Backpressure
	}
	return .None
}

@(private)
history_record_room :: proc(h: ^Host) -> bool {
	root := history_root(h)
	if root == "" do return true
	bytes, ok := history_usage(h)
	return ok && bytes <= HISTORY_LIMIT-HISTORY_TRANSITION_RESERVE &&
		space_available(root, MINIMUM_FREE_RESERVE+HISTORY_TRANSITION_RESERVE)
}

@(private)
history_required :: proc(h: ^Host) -> [2]string {
	return {h.store_current if h.store_current != "" else h.history_current,
		h.generation_previous if h.generation_previous != "" else h.history_previous}
}

@(private)
history_attach :: proc(h, source: ^Host) {
	h.history_root = strings.clone(history_root(source))
	required := history_required(source)
	h.history_current, h.history_previous = strings.clone(required[0]), strings.clone(required[1])
}
