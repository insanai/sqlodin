package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:terminal"
import "core:terminal/ansi"
import "core:time"
import sqlite "../src/sqlite"
import tls "../transport/mtls"

SHELL_USAGE :: `Usage: sqlodin connect CLIENT.json [options]
  -c, --command SQL    Execute SQL or one dot-command; may be repeated
  -f, --file PATH      Execute a script; may be repeated, in argument order
  --state PATH        Durable private client state (default CLIENT.json.shell.db)
  --mode MODE         column, list, csv, tabs, line or json
  --headers           Include column names in list/CSV output
  --bail              Stop a script after its first error
  --help              Show this help
With no commands/files, reads SQL from stdin or opens an interactive session.
Use sqlodin local [DATABASE] [SQL] for the bundled local SQLite shell.
`
shell_statement :: proc(s: ^Shell, text: string) -> bool {
	scratch := virtual.arena_temp_begin(&s.scratch)
	defer virtual.arena_temp_end(scratch)
	start := time.tick_now()
	if s.echo do fmt.eprintln(shell_visible(text))
	ok := shell_sql(s, text)
	if s.timer do fmt.eprintf("Run time: %.3f ms\n", f64(time.tick_since(start))/f64(time.Millisecond))
	return ok
}

shell_feed :: proc(s: ^Shell, line: string, pending: ^strings.Builder) -> bool {
	scratch := virtual.arena_temp_begin(&s.scratch)
	defer virtual.arena_temp_end(scratch)
	prefix := strings.to_string(pending^)
	at := 0
	only_comments := shell_token(prefix, &at) == ""
	complete := fmt.tprintf("%s\nSELECT 1;", prefix)
	if only_comments && sqlite3_complete(strings.clone_to_cstring(complete, context.temp_allocator)) != 0 {
		strings.builder_reset(pending)
		if strings.has_prefix(strings.trim_space(line), ".") do return shell_command(s, line)
	}
	good := true
	for ch in transmute([]u8)line {
		if len(strings.to_string(pending^)) >= 4096 {
			strings.builder_reset(pending)
			s.quit = true // Never interpret the tail of an oversized statement as fresh SQL.
			return shell_error(s, "SQL input exceeds 4096 bytes")
		}
		strings.write_byte(pending, ch)
		if ch != ';' do continue
		text := strings.to_string(pending^)
		if sqlite3_complete(strings.clone_to_cstring(text, context.temp_allocator)) == 0 do continue
		if !shell_statement(s, text) do good = false
		strings.builder_reset(pending)
		if s.quit || !good && s.bail do return good
	}
	return good
}

shell_prompt :: proc(s: ^Shell, continuation: bool) {
	label := "   ...> " if continuation else "sqlodin*> " if s.version != 0 else "sqlodin> "
	fmt.fprint(os.stderr, cli_style(os.stderr, ansi.BOLD + ";" + ansi.FG_CYAN),
		label, cli_style(os.stderr, ansi.RESET))
}

shell_stream :: proc(s: ^Shell, file: ^os.File, interactive: bool) -> bool {
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(file))
	defer bufio.reader_destroy(&reader)
	pending := strings.builder_make()
	defer strings.builder_destroy(&pending)
	good := true
	for !s.quit {
		if interactive do shell_prompt(s, len(strings.trim_space(strings.to_string(pending))) != 0)
		line, err := bufio.reader_read_slice(&reader, '\n')
		if err == .Buffer_Full { shell_error(s, "Input line exceeds 4096 bytes"); return false }
		if err != nil && err != .EOF { shell_error(s, "Cannot read input file"); return false }
		if len(line) == 0 && err == .EOF do break
		s.line += 1
		if !shell_feed(s, string(line), &pending) do good = false
		if !good && s.bail do return false
		if err == .EOF do break
	}
	if !s.quit &&
			   strings.trim_space(strings.to_string(pending)) != "" {
		if !shell_statement(s, strings.to_string(pending)) do good = false
	}
	return good
}

shell_configure :: proc(s: ^Shell, args: []string) -> bool {
	s.config_path, s.state_path = args[0], fmt.aprintf("%s.shell.db", args[0])
	s.output, s.timeout, s.consistency = os.stdout, 10000, "linearizable"
	s.interactive = terminal.is_terminal(os.stdin)
	s.mode, s.separator = strings.clone("column" if s.interactive else "list"), strings.clone("|")
	s.headers = s.interactive
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--headers" { s.headers = true; continue }
		if arg == "--bail" { s.bail = true; continue }
		if arg != "--state" && arg != "--mode" && arg != "-c" && arg != "--command" &&
		   arg != "-f" && arg != "--file" {
		   	return shell_error(s, fmt.tprintf("Unknown connect option: %s", arg))
		   }
		if i + 1 >= len(args) do return shell_error(s, fmt.tprintf("Missing value for %s", arg))
		i += 1
		if arg == "--state" do s.state_path = args[i]
		if arg == "--mode" && !shell_command(s, fmt.tprintf(".mode %s", args[i])) do return false
	}
	data, err := os.read_entire_file(s.config_path, context.temp_allocator)
	if err != nil || len(data) > 65536 do return shell_error(s, "Cannot read client config file")
	if json.unmarshal(data, &s.config, spec = .JSON) != nil || s.config.cluster == "" ||
	   s.config.address == "" || s.config.identity == "" || s.config.certificate == "" ||
	   s.config.key == "" || s.config.ca == "" {
	   	return shell_error(s, "Invalid client configuration JSON")
	   }
	return true
}

shell_run_commands :: proc(s: ^Shell, args: []string) {
	executed := false
	for i := 1; i < len(args) && !s.quit; i += 1 {
		arg := args[i]
		if arg == "--headers" || arg == "--bail" do continue
		i += 1
		if arg == "--state" || arg == "--mode" do continue
		executed = true
		if arg == "-f" || arg == "--file" {
			s.source, s.line = args[i], 0
			shell_file_command(s, ".read", args[i])
		} else {
			s.source, s.line = "<command>", 1
			pending := strings.builder_make()
			shell_feed(s, args[i], &pending)
			if !s.quit && !(s.bail && s.errors != 0) &&
			   strings.trim_space(strings.to_string(pending)) != "" {
				shell_statement(s, strings.to_string(pending))
			}
			strings.builder_destroy(&pending)
		}
		if s.bail && s.errors != 0 do break
	}
	if !executed {
		s.source, s.line = "<stdin>", 0
		if s.interactive {
			fmt.eprintf("%sSQLodin%s  /  authenticated cluster SQL\n",
				cli_style(os.stderr, ansi.BOLD + ";" + ansi.FG_CYAN), cli_style(os.stderr, ansi.RESET))
			fmt.eprintln("SQL ends with ;  |  .help for commands  |  .quit to exit")
		}
		if s.interactive do shell_interactive(s)
		else do shell_stream(s, os.stdin, false)
	}
}

cmd_connect :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] == "--help" { fmt.print(SHELL_USAGE); return 0 if len(args) > 0 else 2 }
	if posix.sigignore(.SIGPIPE) != nil do return 2
	s: Shell
	if virtual.arena_init_growing(&s.scratch) != nil do return 2
	defer virtual.arena_destroy(&s.scratch)
	context.temp_allocator = virtual.arena_allocator(&s.scratch)
	if !shell_configure(&s, args) do return 2
	if !shell_tls_open(&s, s.config) do return 2
	defer tls.context_close(&s.tls)
	defer shell_output_close(&s)
	_ = posix.umask({.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH})
	lock_path := strings.clone_to_cstring(fmt.tprintf("%s.lock", s.state_path), context.temp_allocator)
	fd := sqlodin_cli_lock(lock_path)
	if fd < 0 { shell_error(&s, "Client state is locked or not writable"); return 2 }
	defer posix.close(posix.FD(fd))
	defer sqlite.sqlite3_close_v2(s.journal)
	if !shell_state_open(&s) do return 2
	if s.state.pending.op != "" do fmt.eprintln("A saved write needs resolution. Use .pending and .retry.")
	shell_run_commands(&s, args)
	if s.version != 0 {
		fmt.eprintln("Uncommitted transaction discarded on exit.")
		shell_transaction_reset(&s)
	}
	if s.state.pending.op != "" do return 2
	return 1 if s.errors != 0 else 0
}
