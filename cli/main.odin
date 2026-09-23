package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import sqlodin "../src"
import service "../service"

VERSION :: "0.1.0"

RECORDS_DIR   :: "docs/sod/records"
REGISTRY_PATH :: "docs/sod/registry.typ"
BUNDLE_PATH   :: "docs/sod/bundle.typ"
TEMPLATE_PATH :: "docs/sod/template/rfc-template.typ"
BUILD_DIR     :: "docs/build"
BOOK_PATH     :: "docs/book.typ"
INDEX_PATH    :: "docs/sod/index.typ"

run_system_cmd :: proc(cmd: string) -> int {
	c_cmd := strings.clone_to_cstring(cmd)
	defer delete(c_cmd)
	status := int(libc.system(c_cmd))
	if status != 0 {
		cli_diagnostic("COMMAND FAILED", "The requested command did not complete successfully.",
			fmt.tprintf("Fix the diagnostic above, then rerun: %s", cmd))
		os.exit(1)
	}
	return 0
}

print_usage :: proc() {
	fmt.println("sqlodin - Multi-Master Replicated SQLite Toolchain CLI")
	fmt.println("Usage: sqlodin <command> [arguments]")
	fmt.println("")
	fmt.println("Commands:")
	fmt.println("  connect <client.json> [options]    Interactive mTLS cluster SQL client")
	fmt.println("  local [database] [SQL] [options]   Full bundled SQLite shell for local files")
	fmt.println("  serve <config.json> [--create]      Run the native mTLS SQL service")
	fmt.println("  request <client.json> <request.json> Send an authenticated protocol request")
	fmt.println("  build [all|test|sim|bench|cli]      Build binaries or test runner")
	fmt.println("  test                                Run test suite with odin test")
	fmt.println("  vet                                 Run Zen constraints and strict style")
	fmt.println("  check                               Run full verification suite")
	fmt.println("  sim [--seed=N] [--steps=N]          Run chaos simulator")
	fmt.println("  bench                               Run multi-master benchmark")
	fmt.println("  docs [all|book|index|sod]      Compile Typst documentation")
	fmt.println("  sod list                            List registered SOD records and drafts")
	fmt.println("  sod new <slug>                      Create docs/sod/records/XXXXX-<slug>.typ")
	fmt.println("  sod promote <slug>                  Assign next number and register the SOD")
	fmt.println("  sql <path> <query>                  Alias for the local SQLite shell")
	fmt.println("  version                             Print CLI and core version")
	fmt.println("  help                                Display this help text")
}

cmd_build :: proc(args: []string) {
	target := "all"
	if len(args) > 0 do target = args[0]
	_ = os.make_directory("bin")

	switch target {
	case "test":
		run_system_cmd("odin build tests -build-mode:test -out:bin/sqlodin-test")
	case "sim":
		run_system_cmd("odin build sim -out:bin/sqlodin-sim")
	case "bench":
		run_system_cmd("odin build bench -out:bin/sqlodin-bench -o:speed")
	case "cli":
		run_system_cmd("python3 tools/build_cli.py")
	case "all":
		run_system_cmd("odin build sim -out:bin/sqlodin-sim")
		run_system_cmd("odin build bench -out:bin/sqlodin-bench -o:speed")
		run_system_cmd("python3 tools/build_cli.py")
		fmt.println("All targets built successfully in bin/")
	case:
		cli_diagnostic("UNKNOWN BUILD TARGET", fmt.tprintf("Unknown build target: %s", target),
			"Use sqlodin build all, test, sim, bench or cli.")
		os.exit(2)
	}
}

cmd_test :: proc() {
	fmt.println("Running SQLodin test suite...")
	run_system_cmd("odin test tests")
}

cmd_vet :: proc() {
	fmt.println("Checking Zen constraints and strict style...")
	run_system_cmd("python3 tools/check_style.py")
	run_system_cmd("odin check tests -vet -strict-style -no-entry-point")
	run_system_cmd("odin check sim -vet -strict-style")
	run_system_cmd("odin check bench -vet -strict-style")
	run_system_cmd("odin check cli -vet -strict-style")
}

cmd_sim :: proc(args: []string) {
	cmd_buf := strings.builder_make()
	defer strings.builder_destroy(&cmd_buf)
	strings.write_string(&cmd_buf, "odin run sim --")
	for arg in args {
		strings.write_byte(&cmd_buf, ' ')
		strings.write_string(&cmd_buf, arg)
	}
	run_system_cmd(strings.to_string(cmd_buf))
}

cmd_bench :: proc(args: []string) {
	cmd_buf := strings.builder_make()
	defer strings.builder_destroy(&cmd_buf)
	strings.write_string(&cmd_buf, "odin run bench -o:speed --")
	for arg in args {
		strings.write_byte(&cmd_buf, ' ')
		strings.write_string(&cmd_buf, arg)
	}
	run_system_cmd(strings.to_string(cmd_buf))
}

@(private="file")
_vet_keep_instantiations :: proc() {
	m: sqlodin.Membership(1)
	ids := [1]sqlodin.Node_Id{1}
	_ = sqlodin.membership_init(&m, ids[:])
	eff: sqlodin.Effects(u64, 1, 4, 1, .Host_Managed)
	_ = sqlodin.effects_messages_slice(&eff)
	node: sqlodin.MultiMaster_Node(u64, 1, 4, 1, .Host_Managed)
	noop := u64(0)
	_ = sqlodin.node_init(&node, 1, m, noop)
	_ = sqlodin.node_tick(&node, &eff)
	_ = sqlodin.node_step(&node, sqlodin.Envelope(u64){}, &eff)
}

// -------------------------------------------------------------
// Docs and SOD Lifecycle Helpers
// -------------------------------------------------------------

get_repo_root :: proc() -> string {
	cwd, _ := os.get_working_directory(context.allocator)
	return cwd
}

validate_slug :: proc(slug: string) -> bool {
	if len(slug) == 0 do return false
	if slug[0] == '-' || slug[len(slug) - 1] == '-' do return false
	for ch in slug {
		is_lower := ch >= 'a' && ch <= 'z'
		is_digit := ch >= '0' && ch <= '9'
		is_hyphen := ch == '-'
		if !is_lower && !is_digit && !is_hyphen do return false
	}
	return true
}

extract_meta :: proc(src: string, key: string, fallback: string) -> string {
	pattern := fmt.tprintf("#let sod-%s = \"", key)
	idx := strings.index(src, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	rest := src[start:]
	end := strings.index(rest, "\"")
	if end < 0 do return fallback
	return rest[:end]
}

replace_meta_val :: proc(src: string, key: string, val: string) -> string {
	pattern := fmt.tprintf("#let sod-%s = \"", key)
	idx := strings.index(src, pattern)
	if idx < 0 do return src
	start := idx + len(pattern)
	rest := src[start:]
	end := strings.index(rest, "\"")
	if end < 0 do return src

	buf := strings.builder_make()
	strings.write_string(&buf, src[:start])
	strings.write_string(&buf, val)
	strings.write_string(&buf, rest[end:])
	return strings.to_string(buf)
}

cmd_docs :: proc(args: []string) {
	target := "all"
	if len(args) > 0 do target = args[0]
	if target != "all" && target != "book" && target != "index" && target != "sod" {
		cli_diagnostic("INVALID DOCS ARGUMENT", "The documentation target is not recognized.",
			"Use sqlodin docs all, book, index or sod.")
		os.exit(2)
	}
	code := run_system_cmd(fmt.tprintf("python3 tools/build_docs.py %s", target))
	if code != 0 do os.exit(1)
}

sod_list :: proc() {
	fmt.println("Registered SQLodin Discussions (SODs):")
	fmt.println("--------------------------------------------------------------------------------")
	fmt.printf("%-6s | %-12s | %-32s | %s\n", "SOD", "State", "Title", "Category")
	fmt.println("--------------------------------------------------------------------------------")

	fd, err := os.open(RECORDS_DIR)
	if err != nil do return
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)

	for entry in entries {
		if strings.has_suffix(entry.name, ".typ") {
			file_path := fmt.tprintf("%s/%s", RECORDS_DIR, entry.name)
			content, read_f_err := os.read_entire_file(file_path, context.allocator)
			if read_f_err == nil {
				defer delete(content, context.allocator)
				s := string(content)
				num := extract_meta(s, "number", entry.name[:4])
				state := extract_meta(s, "state", "draft")
				title := extract_meta(s, "title", "Untitled")
				cat := extract_meta(s, "category", "Engineering")
				fmt.printf("%-6s | %-12s | %-32s | %s\n", num, state, title, cat)
			}
		}
	}
}

sod_new :: proc(slug: string) {
	if !validate_slug(slug) {
		fmt.println("Error: Invalid slug. Use lowercase letters, numbers, and hyphens.")
		return
	}
	_ = os.make_directory(RECORDS_DIR)
	dest := fmt.tprintf("%s/XXXXX-%s.typ", RECORDS_DIR, slug)

	template, err := os.read_entire_file(TEMPLATE_PATH, context.allocator)
	if err != nil {
		fmt.eprintln("Error: could not read template at", TEMPLATE_PATH)
		return
	}
	defer delete(template, context.allocator)

	now := time.now()
	y, m, d := time.date(now)
	date_str := fmt.tprintf("%04d-%02d-%02d", y, m, d)

	content, _ := strings.replace_all(string(template), "YYYY-MM-DD", date_str)
	defer delete(content)

	write_err := os.write_entire_file(dest, transmute([]u8)content)
	if write_err != nil {
		fmt.eprintln("Error: could not write draft to", dest)
		return
	}
	fmt.printf("Created draft: %s\n", dest)
	fmt.printf("When ready for discussion, promote it with: sqlodin sod promote %s\n", slug)
}

get_next_sod_number :: proc() -> int {
	fd, err := os.open(RECORDS_DIR)
	if err != nil do return 1
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return 1
	defer os.file_info_slice_delete(entries, context.allocator)

	max_num := 0
	for entry in entries {
		if strings.has_suffix(entry.name, ".typ") && len(entry.name) >= 4 {
			num_part := entry.name[:4]
			if val, ok := strconv.parse_int(num_part); ok {
				if val > max_num do max_num = val
			}
		}
	}
	return max_num + 1
}

sod_promote :: proc(slug: string) {
	draft_name := fmt.tprintf("XXXXX-%s.typ", slug)
	draft_path := fmt.tprintf("%s/%s", RECORDS_DIR, draft_name)
	draft_bytes, err := os.read_entire_file(draft_path, context.allocator)
	if err != nil {
		fmt.eprintln("Error: placeholder draft does not exist at", draft_path)
		return
	}
	defer delete(draft_bytes, context.allocator)

	next_num := get_next_sod_number()
	num_str := fmt.tprintf("%04d", next_num)
	new_filename := fmt.tprintf("%s-%s.typ", num_str, slug)
	new_path := fmt.tprintf("%s/%s", RECORDS_DIR, new_filename)

	now := time.now()
	y, m, d := time.date(now)
	today_str := fmt.tprintf("%04d-%02d-%02d", y, m, d)

	content := string(draft_bytes)
	content = replace_meta_val(content, "number", num_str)
	content = replace_meta_val(content, "state", "committed")
	content = replace_meta_val(content, "status", "Committed")
	content = replace_meta_val(content, "last-updated", today_str)

	if write_err := os.write_entire_file(new_path, transmute([]u8)content); write_err != nil {
		fmt.eprintln("Error writing promoted record to", new_path)
		return
	}
	_ = os.remove(draft_path)
	fmt.printf("Promoted draft to: %s\n", new_path)
}

cmd_sod :: proc(args: []string) {
	if len(args) == 0 {
		sod_list()
		return
	}
	switch args[0] {
	case "list":
		sod_list()
	case "new":
		if len(args) < 2 {
			fmt.println("Error: slug required (e.g. sqlodin sod new vector-indexes)")
			return
		}
		sod_new(args[1])
	case "promote":
		if len(args) < 2 {
			fmt.println("Error: slug required (e.g. sqlodin sod promote vector-indexes)")
			return
		}
		sod_promote(args[1])
	case:
		fmt.println("Usage: sqlodin sod [list|new <slug>|promote <slug>]")
	}
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		os.exit(cmd_local(nil))
	}
	cmd := args[0]
	rest := args[1:]

	switch cmd {
	case "local": os.exit(cmd_local(rest))
	case "connect": os.exit(cmd_connect(rest))
	case "serve":   cmd_serve(rest)
	case "request":
		if len(rest) != 2 {
			cli_diagnostic("REQUEST FILES REQUIRED",
				"Both a client config and a request file are required.",
				"Use sqlodin request CLIENT.json REQUEST.json, or sqlodin connect " +
					"CLIENT.json for the SQL shell.")
			os.exit(2)
		}
		code := service.request_file(rest[0], rest[1])
		if code != 0 do cli_diagnostic("REQUEST DID NOT SUCCEED",
			"The protocol request did not return a verified successful result.",
			"Check the response and client config. If a write outcome is " +
				"uncertain, retry the same request file.")
		os.exit(code)
	case "build":   cmd_build(rest)
	case "test":    cmd_test()
	case "vet":     cmd_vet()
	case "check":   run_system_cmd("python3 tools/check.py")
	case "sim":     cmd_sim(rest)
	case "bench":   cmd_bench(rest)
	case "docs":    cmd_docs(rest)
	case "sod":     cmd_sod(rest)
	case "sql":     os.exit(cmd_local(rest))
	case "version": fmt.printf("sqlodin %s\n", VERSION)
	case "help", "--help", "-h": print_usage()
	case:
		cli_diagnostic("UNKNOWN COMMAND", fmt.tprintf("Unknown command: %s", cmd),
			"Run sqlodin help. Use sqlodin connect CLIENT.json or sqlodin local DATABASE.")
		os.exit(2)
	}
}

cmd_serve :: proc(args: []string) {
	if len(args) < 1 || len(args) > 2 || len(args) == 2 && args[1] != "--create" {
		cli_diagnostic("INVALID SERVICE ARGUMENTS", "Expected a node configuration and optional --create.",
			"Use sqlodin serve NODE.json; add --create only for a new data directory.")
		os.exit(2)
	}
	if !service.run(args[0], len(args) == 2) {
		cli_diagnostic("SERVICE STOPPED", "The SQL service could not continue; see the diagnostic above.",
			"Check config, TLS identities, bind address and data permissions. " +
				"Preserve existing data before repair.")
		os.exit(1)
	}
}
