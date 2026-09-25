package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import sql "../src"
import durable "../src/durable"
import service "../service"

cmd_migrate :: proc(args: []string) -> int {
	if len(args) != 2 {
		cli_diagnostic("INVALID MIGRATION ARGUMENTS", "Expected a source node config and a new directory.",
			"Stop all voters, then use sqlodin migrate OLD-NODE.json NEW-DIRECTORY for each voter.")
		return 2
	}
	cfg, valid := service.load_config(args[0], context.temp_allocator)
	if !valid || cfg.storage_format != 4 {
		cli_diagnostic("MIGRATION SOURCE REJECTED",
			"The source must be a valid format-4 node configuration.",
			"Use its original cluster, voter, membership and TLS configuration. Preserve the source files.")
		return 2
	}
	name := strings.clone_to_cstring(args[1])
	defer delete(name)
	if posix.mkdir(name, {.IRUSR, .IWUSR, .IXUSR}) != nil {
		cli_diagnostic("MIGRATION DIRECTORY REJECTED",
			"Cannot create the new private destination directory.",
			"Choose a new path under a writable parent. Existing destinations are never reused.")
		return 1
	}
	destination, path_err := os.get_absolute_path(args[1], context.temp_allocator)
	if path_err != nil do return 1
	source := fmt.tprintf("%s/node.db", cfg.data)
	application := fmt.tprintf("%s/node.db", destination)
	consensus := fmt.tprintf("%s/consensus.db", destination)
	ids: [durable.MAX_MEMBERS]sql.Node_Id
	for member, i in cfg.members do ids[i] = member.id
	phase: durable.Migration_Phase
	err := durable.migrate_format4(source, application, consensus, cfg.cluster, cfg.node,
		ids[:len(cfg.members)], phase = &phase)
	if err != .None {
		cli_diagnostic("MIGRATION INCOMPLETE", fmt.tprintf("Stopped in %v: %v.", phase, err),
			"Keep the source untouched and offline. Check locks, free space and file permissions. " +
			"Inspect the failed destination; retry into a new directory after fixing the cause.")
		return 1
	}
	cfg.data, cfg.storage_format = destination, 5
	bytes, encode_err := json.marshal(cfg, allocator = context.temp_allocator)
	config_path := fmt.tprintf("%s/node.json", destination)
	if encode_err != nil || os.write_entire_file(config_path, bytes) != nil ||
		!migration_sync_config(config_path) {
		cli_diagnostic("MIGRATION CONFIGURATION FAILED",
			"The new stores exist but config publication failed.",
			"Preserve both stores. Recreate the node config with storage_format=5 and the new data path.")
		return 1
	}
	fmt.printf("Migration complete. Source preserved. New configuration: %s\n", config_path)
	fmt.println("Migrate every voter before restarting. " +
		"Keep original voters stopped; never run both copies.")
	fmt.printf("Start this voter with: sqlodin serve %s\n", config_path)
	return 0
}

migration_sync_config :: proc(path: string) -> bool {
	name := strings.clone_to_cstring(path)
	defer delete(name)
	file := posix.open(name, {.RDWR, .NOFOLLOW})
	if file < 0 do return false
	defer posix.close(file)
	if posix.fsync(file) != nil do return false
	when ODIN_OS == .Darwin {
		if posix.fcntl(file, posix.FCNTL_Cmd(51)) != 0 do return false
	}
	return durable.sync_directory(path)
}
