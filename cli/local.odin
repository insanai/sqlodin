package main

import "core:c"
import "core:c/libc"
import "core:strings"

foreign import local_shell "../build/native/libsqlodin_shell.a"
@(default_calling_convention="c")
foreign local_shell {
	sqlodin_sqlite_shell :: proc(argc: c.int, argv: [^]cstring) -> c.int ---
}

// The full upstream shell operates on standalone SQLite files, never through Paxos.
cmd_local :: proc(args: []string) -> int {
	argv := make([]cstring, len(args) + 2)
	defer delete(argv)
	argv[0] = "sqlodin local"
	for arg, i in args do argv[i + 1] = strings.clone_to_cstring(arg)
	defer for i in 1..<len(argv) - 1 do delete(argv[i])
	code := int(sqlodin_sqlite_shell(c.int(len(argv) - 1), raw_data(argv)))
	// Odin exits through the OS; the embedded C main does not get libc exit flushing.
	if libc.fflush(nil) != 0 {
		cli_diagnostic("LOCAL OUTPUT FAILED", "SQLite output could not be flushed.",
			"Check the destination file, free disk space and the receiving end of the output pipe.")
		return 1
	}
	if code != 0 do cli_diagnostic("LOCAL SQLITE COMMAND FAILED",
		"The SQLite shell reported the diagnostic above.",
		"Use .help for command syntax, .schema to inspect tables, and check file paths and permissions.")
	return code
}
