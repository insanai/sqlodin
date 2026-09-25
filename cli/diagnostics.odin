package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:terminal/ansi"

cli_color :: proc(file: ^os.File) -> bool {
	_, disabled := os.lookup_env("NO_COLOR", context.temp_allocator)
	term := os.get_env("TERM", context.temp_allocator)
	return !disabled && term != "dumb" && terminal.is_terminal(file)
}

cli_style :: proc(file: ^os.File, style: string) -> string {
	return fmt.tprintf("%s%s%s", ansi.CSI, style, ansi.SGR) if cli_color(file) else ""
}

cli_diagnostic :: proc(title, detail, hint: string, source: string = "", line: int = 0) {
	cyan := cli_style(os.stderr, ansi.BOLD + ";" + ansi.FG_CYAN)
	reset := cli_style(os.stderr, ansi.RESET)
	fmt.eprintf("\n%s-- %s ------------------------------------------------%s\n", cyan, title, reset)
	if source != "" do fmt.eprintf("\nAt %s:%d\n", shell_visible(source), line)
	fmt.eprintf("\n%s\n\n", shell_visible(detail))
	fmt.eprintf("%sHint:%s %s\n\n", cli_style(os.stderr, ansi.BOLD), reset, hint)
}

shell_error :: proc(s: ^Shell, message: string) -> bool {
	title, hint := shell_error_help(message)
	cli_diagnostic(title, message, hint, s.source, s.line)
	s.errors += 1
	return false
}

shell_error_help :: proc(message: string) -> (title, hint: string) {
	switch message {
	case "Conflict": return "TRANSACTION CONFLICT",
		"Repeat the entire BEGIN ... COMMIT transaction against the new " +
			"revision; roll back first if still active."
	case "Expired": return "SESSION RETIRED",
		"Keep the saved request for diagnosis. Do not relabel or replay it in a new epoch. " +
			"Use a new --state file only for new work after checking its business outcome."
	case "Session_Limit": return "SESSION CAPACITY REACHED",
		"Quiesce clients, resolve pending writes, inspect .session, then explicitly retire " +
			"that epoch with .retire-sessions E --quiesced."
	case "Constraint": return "CONSTRAINT REJECTED",
		"Inspect .schema for UNIQUE, CHECK and foreign-key rules. Correct the values before retrying."
	case "Invalid_SQL": return "SQL COULD NOT RUN",
		"Use .tables and .schema to check names and syntax. Remote writes " +
			"cannot contain RETURNING or PRAGMA."
	case "Policy": return "SQL OUTSIDE THE REPLICATION POLICY",
		"Use deterministic SQL on user tables. Run local-file administration with sqlodin local instead."
	case "Query_Limit": return "QUERY LIMIT REACHED",
		"Add an indexed predicate or LIMIT, select fewer columns, or page through results. See .limits."
	case "Read_Timeout", "Busy", "Preview_Error": return "CLUSTER REQUEST NOT READY",
		"Check .status and .health, restore quorum connectivity, then retry. A preview has not committed."
	}
	if message == "No pending write" {
		return "NOTHING TO RETRY", "Enter a new SQL statement. .retry is only for an unresolved " +
			"saved write."
	}
	lower := strings.to_lower(message, context.temp_allocator)
	if strings.contains(lower, "config") {
		return "CLIENT CONFIGURATION INVALID",
			"Check cluster, address, identity, certificate, key and ca in " +
				"CLIENT.json; see docs/cli.md for an example."
	}
	if strings.contains(lower, "pending") || strings.contains(lower, "outcome") ||
	   strings.contains(lower, "unresolved") {
		return "WRITE NEEDS RESOLUTION",
			"Keep the client state file. Restore connectivity and run .retry " +
				"with the same client certificate."
	}
	if strings.contains(lower, "state") || strings.contains(lower, "recovery") {
		return "CLIENT STATE UNAVAILABLE",
			"Check the --state path and permissions. Close any other shell using " +
				"it; never delete unresolved state."
	}
	if strings.contains(lower, "response") || strings.contains(lower, "begin transaction") {
		return "NO VERIFIED CLUSTER RESPONSE",
			"Check the client JSON address, CA, certificate, key and server " +
				"identity; then check voter connectivity."
	}
	if strings.contains(lower, "transaction") || strings.contains(lower, "savepoint") {
		return "TRANSACTION CANNOT CONTINUE",
			"Use .limits to inspect bounds. ROLLBACK; discards staged work; start a fresh BEGIN; to retry."
	}
	if strings.contains(lower, "parameter") || strings.contains(lower, "json") {
		return "PARAMETER COULD NOT BE BOUND",
			"For example: .parameter set ?1 \"Ada\" followed by SELECT ?1; Use " +
				".parameter list to inspect bindings."
	}
	if strings.contains(lower, "script") || strings.contains(lower, "output") ||
	   strings.contains(lower, "file") {
		return "FILE OPERATION FAILED",
			"Check the path and permissions. Quote paths with spaces; .read never executes shell commands."
	}
	if strings.contains(lower, "4096") || strings.contains(lower, "limit") {
		return "INPUT LIMIT REACHED", "Reduce the statement or transaction size. Run .limits for the " +
			"supported bounds."
	}
	return "COMMAND COULD NOT RUN", "Run .help for exact syntax and supported commands; correct the " +
		"input and try again."
}
