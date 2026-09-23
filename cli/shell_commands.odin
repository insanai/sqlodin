package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import service "../service"

SHELL_HELP :: `SQLodin cluster shell
SQL ends with ';'; multi-line statements and CREATE TRIGGER bodies are supported.
BEGIN; COMMIT; ROLLBACK; SAVEPOINT name; RELEASE name; ROLLBACK TO name;
Transactions use bounded optimistic serializable previews, then durable Paxos commit.
.help                         This help
.quit / .exit                 Quit; uncommitted previews are discarded
.tables [LIKE-pattern]        List user tables and views
.schema [LIKE-pattern]        Show SQL schema (excludes internal tables)
.indexes [LIKE-table]          List indexes
.databases / .connection      Show cluster and authenticated endpoint
.status / .cluster            Local node ID and applied slot (not quorum health)
.nodes                        Configured voters (not live health)
.reconnect CLIENT.json        Switch endpoint within the same cluster/client identity
.health                       Fresh quorum-fenced read
.consistency linearizable|local   Set standalone read consistency (local may be stale)
.timeout MILLISECONDS         Service request deadline, 1..60000
.pending                      Show unresolved write, including SQL; keep it private
.retry                        Resolve the exact durable request, never a new identity
.read FILE                    Execute a UTF-8 SQL/dot-command script (no shell expansion)
.output [FILE]                Write results to FILE, or restore stdout
.once FILE                    Redirect the next query result
.mode column|list|csv|tabs|line|json
.headers on|off  .nullvalue TEXT  .separator TEXT
.timer on|off   .changes on|off  .echo on|off  .bail on|off
.parameter set ?N JSON_VALUE  Bind ?1..?16 (string, integer, real or null)
.parameter list|clear         Inspect/reset bindings; no SQL expressions are evaluated
.print TEXT                   Print text
.show                         Show settings
.limits                       Display service and transaction limits
Local-file commands (.backup, .restore, .dump, .import, .open, PRAGMA administration)
are available in 'sqlodin local'. They are not remote cluster management operations.
Membership is fixed; certificate enrollment cannot add or remove a voter.
`
shell_parameter :: proc(s: ^Shell, arg: string) -> bool {
	if arg == "clear" {
		for &p in s.parameters { delete(p.text); p = {} }
		s.parameter_set = {}
		return true
	}
	if arg == "list" {
		for p, i in s.parameters do if s.parameter_set[i] {
			fmt.fprintf(s.output, "?%d %s\n", i + 1, shell_json(p))
		}
		return true
	}
	parts := strings.split_n(arg, " ", 3, context.temp_allocator)
	if len(parts) != 3 || parts[0] != "set" || !strings.has_prefix(parts[1], "?") {
		return shell_error(s, "Usage: .parameter set ?N JSON_VALUE | list | clear")
	}
	n, ok := strconv.parse_int(parts[1][1:])
	if !ok || n < 1 || n > 16 do return shell_error(s, "Parameter index must be 1..16")
	value: json.Value
	if json.unmarshal(transmute([]u8)parts[2], &value, spec = .JSON,
	                  allocator = context.temp_allocator) != nil {
	                  	return shell_error(s, "Invalid JSON value")
	                  }
	p: service.Parameter
	#partial switch v in value {
	case json.Null: p.kind = "null"
	case json.Integer: p.kind, p.integer = "integer", v
	case json.Float:
		if math.is_nan(v) || math.is_inf(v) do return shell_error(s, "Expected finite number")
		p.kind, p.real = "real", v
	case json.String:
		if strings.contains(v, "\x00") {
			return shell_error(s, "NUL text parameters require the Python API")
		}
		p.kind, p.text = "text", strings.clone(v)
	case: return shell_error(s, "Expected JSON string, integer, real or null")
	}
	delete(s.parameters[n - 1].text)
	s.parameters[n - 1], s.parameter_set[n - 1] = p, true
	return true
}

shell_metadata :: proc(s: ^Shell, cmd, arg: string) -> bool {
	pattern := shell_quote(arg if arg != "" else "%")
	filter := " WHERE lower(name) NOT GLOB '_sqlodin_*' AND lower(tbl_name) NOT GLOB '_sqlodin_*' "
	text := ""
	switch cmd {
	case ".tables": text = fmt.tprintf("SELECT name FROM sqlite_schema%s" +
		"AND name NOT GLOB 'sqlite_*' AND type IN ('table','view') AND name " +
			"LIKE %s ORDER BY name;", filter, pattern)
	case ".schema": text = fmt.tprintf("SELECT sql FROM sqlite_schema%s" +
		"AND sql IS NOT NULL AND (name LIKE %s OR tbl_name LIKE %s) ORDER BY " +
			"type,name;", filter, pattern, pattern)
	case ".indexes": text = fmt.tprintf("SELECT name FROM sqlite_schema%s" +
		"AND type='index' AND tbl_name LIKE %s ORDER BY name;", filter, pattern)
	}
	return shell_sql(s, text)
}

shell_inspect :: proc(s: ^Shell, cmd: string) -> bool {
	switch cmd {
	case ".help": fmt.fprint(s.output, SHELL_HELP)
	case ".quit", ".exit": s.quit = true
	case ".databases", ".connection":
		fmt.fprintf(s.output, "cluster: %s\nendpoint: %s\nserver identity: %s\nclient state: %s\n",
			s.config.cluster, s.config.address, s.config.identity, s.state_path)
	case ".status", ".cluster", ".health", ".nodes":
		r := service.Request{op = "status"}
		if cmd == ".health" {
			r = service.Request{op = "query", sql = "SELECT 1", consistency = "linearizable"}
		}
		response, ok := shell_call(s, r)
		if !ok do return shell_error(s, "No verified node response")
		if response.status != "ok" do return shell_error(s, response.error)
		if cmd == ".nodes" {
			if len(response.members) == 0 {
				return shell_error(s, "Server does not expose configured voters")
			}
			for m in response.members do fmt.fprintf(s.output, "%d  %s  %s\n",
				m.id, shell_visible(m.address), shell_visible(m.identity))
			return true
		}
		fmt.fprintf(s.output, "cluster=%s node=%d protocol=%d applied=%d %s\n",
			response.cluster, response.node, response.protocol, response.applied,
			"quorum read passed" if cmd == ".health" else "local status; not quorum health")
	case ".pending":
		message := shell_json(s.state.pending) if s.state.pending.op != "" else "No pending write"
		fmt.fprintln(s.output, message)
	case ".retry": return shell_resolve(s)
	case ".show":
		fmt.fprintf(s.output, "mode=%s headers=%v consistency=%s timeout=%dms transaction=%v pending=%v\n",
			s.mode, s.headers, s.consistency, s.timeout, s.version != 0, s.state.pending.op != "")
	case ".limits":
		fmt.fprintln(s.output, "SQL/transaction: 4096 bytes; 8 writes; 4096 result rows; 256 KiB results.")
		fmt.fprintln(s.output, "Global revision conflicts require a complete transaction retry. No " +
			"voter changes.")
	case: return shell_error(s, "Unknown or unavailable cluster command; use .help or sqlodin local")
	}
	return true
}

shell_command :: proc(s: ^Shell, line: string) -> bool {
	scratch := virtual.arena_temp_begin(&s.scratch)
	defer virtual.arena_temp_end(scratch)
	text := strings.trim_space(line)
	end := 0
	for end < len(text) && text[end] > ' ' do end += 1
	cmd := text[:end]
	arg := strings.trim_space(text[end:])
	if cmd == ".parameter" do return shell_parameter(s, arg)
	if cmd == ".reconnect" do return shell_reconnect(s, arg)
	if cmd == ".tables" || cmd == ".schema" || cmd == ".indexes" do return shell_metadata(s, cmd, arg)
	if cmd == ".print" { fmt.fprintln(s.output, arg); return true }
	if cmd == ".mode" {
		if arg != "column" && arg != "list" && arg != "csv" && arg != "tabs" &&
		   arg != "line" && arg != "json" { return shell_error(s, "Unsupported mode; see .help") }
		delete(s.mode); s.mode = strings.clone(arg)
		delete(s.separator)
		s.separator = strings.clone("," if arg == "csv" else "\t" if arg == "tabs" else "|")
		return true
	}
	if cmd == ".headers" || cmd == ".timer" || cmd == ".changes" || cmd == ".echo" || cmd == ".bail" {
		if arg != "on" && arg != "off" do return shell_error(s, "Expected on or off")
		on := arg == "on"
		switch cmd {
		case ".headers": s.headers = on
		case ".timer": s.timer = on
		case ".changes": s.changes = on
		case ".echo": s.echo = on
		case ".bail": s.bail = on
		}
		return true
	}
	if cmd == ".consistency" {
		if arg != "linearizable" && arg != "local" do return shell_error(s, "Use linearizable or local")
		s.consistency = "local" if arg == "local" else "linearizable"
		return true
	}
	if cmd == ".timeout" {
		n, ok := strconv.parse_int(arg)
		if !ok || n < 1 || n > 60000 do return shell_error(s, "Timeout must be 1..60000 ms")
		s.timeout = n; return true
	}
	if cmd == ".nullvalue" { delete(s.nullvalue); s.nullvalue = strings.clone(arg); return true }
	if cmd == ".separator" { delete(s.separator); s.separator = strings.clone(arg); return true }
	if cmd == ".read" || cmd == ".output" || cmd == ".once" do return shell_file_command(s, cmd, arg)
	if arg != "" do return shell_error(s, "Unexpected command argument")
	return shell_inspect(s, cmd)
}

shell_file_command :: proc(s: ^Shell, cmd, arg: string) -> bool {
	path := arg
	if len(path) >= 2 && (path[0] == '"' && path[len(path) - 1] == '"' ||
	                     path[0] == '\'' && path[len(path) - 1] == '\'') { path = path[1:len(path) - 1] }
	if cmd == ".read" {
		if s.depth >= 16 do return shell_error(s, "Maximum .read nesting is 16")
		f, err := os.open(path)
		if err != nil do return shell_error(s, fmt.tprintf("Cannot open script: %s", path))
		defer os.close(f)
		old_source, old_line := s.source, s.line
		s.source, s.line = path, 0
		defer { s.source, s.line = old_source, old_line }
		s.depth += 1
		defer s.depth -= 1
		return shell_stream(s, f, false)
	}
	if path == "" { shell_output_close(s); s.once = false; return true }
	f, err := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil do return shell_error(s, fmt.tprintf("Cannot open output: %s", path))
	shell_output_close(s)
	s.output, s.once = f, cmd == ".once"
	return true
}

shell_reconnect :: proc(s: ^Shell, path: string) -> bool {
	if s.version != 0 do return shell_error(s, "Finish the current transaction before reconnecting")
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) > 65536 do return shell_error(s, "Cannot read client config file")
	cfg: service.Client_Config
	accepted := false
	defer if !accepted do shell_config_delete(cfg)
	if json.unmarshal(data, &cfg, spec = .JSON) != nil || cfg.address == "" || cfg.identity == "" ||
	   cfg.ca == "" || cfg.key == "" || cfg.cluster != s.state.cluster ||
	   cfg.certificate != s.state.certificate {
		return shell_error(s, "Reconnect must preserve the recovery state's cluster and client certificate")
	}
	if !shell_tls_open(s, cfg) do return false
	shell_config_delete(s.config)
	s.config, accepted = cfg, true
	return shell_inspect(s, ".connection")
}


shell_config_delete :: proc(cfg: service.Client_Config) {
	for field in ([?]string{cfg.cluster, cfg.address, cfg.identity, cfg.certificate, cfg.key, cfg.ca}) {
		delete(field)
	}
}
