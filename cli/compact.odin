package main

import "core:fmt"
import sql "../src"
import durable "../src/durable"
import service "../service"

cmd_compact :: proc(args: []string) -> int {
	if len(args) != 1 {
		cli_diagnostic("INVALID COMPACTION ARGUMENTS", "Expected one node configuration.",
			"Use sqlodin compact NODE.json after a snapshot is certified and this voter is stopped.")
		return 2
	}
	cfg, valid := service.load_config(args[0], context.temp_allocator)
	if !valid || cfg.storage_format != 5 {
		cli_diagnostic("COMPACTION SOURCE REJECTED", "A valid format-5 node configuration is required.",
			"Use the node's existing configuration. Migrate format-4 stores before compacting.")
		return 2
	}
	ids: [durable.MAX_MEMBERS]sql.Node_Id
	for member, i in cfg.members do ids[i] = member.id
	h, err := durable.open_store(cfg.data, cfg.cluster, cfg.node, ids[:len(cfg.members)])
	if err != .None {
		cli_diagnostic("CANNOT OPEN COMPACTION SOURCE", fmt.tprintf("Opening this voter returned %v.", err),
			"Stop this voter and check its data directory and permissions. " +
			"Keep its original configuration.")
		return 1
	}
	defer durable.close(h)
	if h.snapshot_sealed.key.prefix <= h.generation_base.key.prefix {
		cli_diagnostic("NO NEW CERTIFIED SNAPSHOT", "There is no newer chosen snapshot to compact to.",
			"Start this voter, request a snapshot and wait for certification, then stop it and retry.")
		return 1
	}
	directory := fmt.tprintf("%s/snapshots", cfg.data)
	if durable.snapshot_enable(h, h.application_path, directory) != .None {
		cli_diagnostic("CANNOT OPEN SNAPSHOT DIRECTORY", "The retained snapshot directory is unavailable.",
			"Check the node data path and snapshot directory permissions, then retry with the same config.")
		return 1
	}
	next, compact_err := durable.compact_store(h, cfg.cluster)
	if compact_err != .None {
		cli_diagnostic("COMPACTION INCOMPLETE",
			fmt.tprintf("Generation construction returned %v.", compact_err),
			"Preserve the data directory. Check free space and retained snapshot files. Restart with " +
			"the same node configuration; startup selects the durably published generation.")
		return 1
	}
	defer durable.close(next)
	fmt.printf("Published generation at prefix %d. Previous files retained.\n",
		next.generation_base.key.prefix)
	fmt.printf("Restart this voter with: sqlodin serve %s\n", args[0])
	return 0
}
