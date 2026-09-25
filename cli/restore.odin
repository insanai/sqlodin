package main

import "core:fmt"
import sql "../src"
import durable "../src/durable"
import service "../service"

cmd_restore :: proc(args: []string) -> int {
	if len(args) != 3 || args[2] != "--new-cluster" {
		cli_diagnostic("INVALID RESTORE ARGUMENTS",
			"Restore requires an explicit fresh cluster configuration.",
			"Use sqlodin restore BACKUP-DIRECTORY NEW-NODE.json --new-cluster. " +
			"Use a globally unused cluster name and new data directory; keep the old deployment fenced.")
		return 2
	}
	cfg, valid := service.load_config(args[1], context.temp_allocator)
	if !valid || cfg.storage_format != 5 {
		cli_diagnostic("RESTORE CONFIGURATION REJECTED", "A valid format-5 configuration is required.",
			"Provide the new cluster name, voter, fixed membership, TLS settings and a new data directory.")
		return 2
	}
	ids: [durable.MAX_MEMBERS]sql.Node_Id
	for member, i in cfg.members do ids[i] = member.id
	err := durable.restore_backup(args[0], cfg.data, cfg.cluster, cfg.node, ids[:len(cfg.members)])
	if err != .None {
		cli_diagnostic("RESTORE INCOMPLETE", fmt.tprintf("Restore returned %v.", err),
			"Verify the backup, use a different cluster name and a new directory, and check free space. " +
			"Preserve the backup and failed destination. Never start an incomplete restore or reuse votes.")
		return 1
	}
	fmt.printf("Created fresh voter %d for cluster %s in %s.\n", cfg.node, cfg.cluster, cfg.data)
	fmt.println("Restore every voter from this identical backup and keep the old deployment fenced.")
	fmt.printf("Start with: sqlodin serve %s\n", args[1])
	return 0
}
