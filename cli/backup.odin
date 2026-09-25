package main

import "core:fmt"
import sql "../src"
import durable "../src/durable"
import service "../service"

cmd_backup :: proc(args: []string) -> int {
	if len(args) != 2 {
		cli_diagnostic("INVALID BACKUP ARGUMENTS",
			"Expected a node configuration and a new backup directory.",
			"Use sqlodin backup NODE.json NEW-BACKUP-DIRECTORY with this voter stopped.")
		return 2
	}
	cfg, valid := service.load_config(args[0], context.temp_allocator)
	if !valid || cfg.storage_format != 5 {
		cli_diagnostic("BACKUP SOURCE REJECTED", "A valid managed format-5 node configuration is required.",
			"Use the existing node configuration. Migrate a format-4 source before backing it up.")
		return 2
	}
	ids: [durable.MAX_MEMBERS]sql.Node_Id
	for member, i in cfg.members do ids[i] = member.id
	h, err := durable.open_store(cfg.data, cfg.cluster, cfg.node, ids[:len(cfg.members)])
	if err != .None {
		cli_diagnostic("CANNOT OPEN BACKUP SOURCE", fmt.tprintf("Opening this voter returned %v.", err),
			"Stop this voter and preserve its data/configuration. Other healthy voters may serve.")
		return 1
	}
	defer durable.close(h)
	manifest, backup_err := durable.backup_store(h, cfg.cluster, args[1])
	if backup_err != .None {
		cli_diagnostic("BACKUP INCOMPLETE", fmt.tprintf("Backup returned %v.", backup_err),
			"Preserve the source. Check free space and permissions; retry into a new directory. " +
			"An incomplete destination is not a usable backup.")
		return 1
	}
	fmt.printf("Verified application backup: prefix=%d bytes=%d directory=%s\n",
		manifest.prefix, manifest.bytes, args[1])
	fmt.println("This is a point-in-time application backup. It contains no voter promises or votes.")
	return 0
}

cmd_verify_backup :: proc(args: []string) -> int {
	if len(args) != 1 {
		cli_diagnostic("INVALID VERIFICATION ARGUMENTS", "Expected one backup directory.",
			"Use sqlodin verify-backup BACKUP-DIRECTORY.")
		return 2
	}
	manifest, err := durable.verify_backup(args[0])
	if err != .None {
		cli_diagnostic("BACKUP VERIFICATION FAILED",
			"The manifest or application image is incomplete or invalid.",
			"Preserve the backup for diagnosis. Check the engine version and use a verified copy. " +
			"Do not import files from an incomplete destination.")
		return 1
	}
	fmt.printf("Backup verified: prefix=%d bytes=%d source-cluster=%s\n",
		manifest.prefix, manifest.bytes, string(manifest.cluster[:manifest.cluster_len]))
	return 0
}
