package main

import "core:c"
import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import service "../service"
import tls "../transport/mtls"
import sqlite "../src/sqlite"

foreign import local_shell "../build/native/libsqlodin_shell.a"
@(default_calling_convention="c")
foreign local_shell {
	sqlodin_cli_lock :: proc(path: cstring) -> c.int ---
}

Shell_State :: struct {
	cluster, certificate, certificate_fingerprint, session: string,
	sequence: u64,
	pending: service.Request,
}

Shell_Savepoint :: struct { name: string, sql: string }
Shell :: struct {
	config: service.Client_Config,
	tls: tls.Context, certificate_fingerprint: string,
	config_path, state_path: string,
	scratch: virtual.Arena,
	render: strings.Builder,
	state: Shell_State, journal: sqlite.Sqlite3,
	mode, separator, nullvalue, consistency: string,
	output: ^os.File, once, headers, timer, echo, changes, bail, interactive, quit: bool,
	errors, depth, timeout: int,
	source: string, line: int,
	version: u64, staged: string, savepoints: [dynamic]Shell_Savepoint,
	transaction_failed: bool,
	parameters: [16]service.Parameter, parameter_set: [16]bool,
}

shell_quote :: proc(text: string) -> string {
	escaped, _ := strings.replace_all(text, "'", "''", context.temp_allocator)
	return fmt.tprintf("'%s'", escaped)
}

shell_state_save :: proc(s: ^Shell) -> bool {
	bytes, err := json.marshal(s.state, allocator = context.temp_allocator)
	if err != nil do return shell_error(s, "Cannot encode client recovery state")
	text := fmt.tprintf("INSERT OR REPLACE INTO state VALUES(1,%s);", shell_quote(string(bytes)))
	if sqlite.sqlite3_exec(s.journal, strings.clone_to_cstring(text, context.temp_allocator),
	                      nil, nil, nil) != sqlite.OK {
		return shell_error(s, "Cannot persist client recovery state; no new request will be sent")
	}
	return true
}

shell_state_open :: proc(s: ^Shell) -> bool {
	path := strings.clone_to_cstring(s.state_path, context.temp_allocator)
	if sqlite.sqlite3_open_v2(path, &s.journal,
	                          sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE, nil) != sqlite.OK {
		return shell_error(s, "Cannot open client recovery database")
	}
	setup := "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; " +
	         "CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);"
	if sqlite.sqlite3_exec(s.journal, strings.clone_to_cstring(setup, context.temp_allocator),
	                      nil, nil, nil) != sqlite.OK { return shell_error(s, "Client state setup failed") }
	stmt: sqlite.Sqlite3_Stmt
	if sqlite.sqlite3_prepare_v2(s.journal, "SELECT body FROM state WHERE id=1",
	                             -1, &stmt, nil) != sqlite.OK {
		return shell_error(s, "Cannot read client state")
	}
	defer sqlite.sqlite3_finalize(stmt)
	rc := sqlite.sqlite3_step(stmt)
	if rc == sqlite.ROW {
		body := string(sqlite.sqlite3_column_text(stmt, 0))
		if json.unmarshal(transmute([]u8)body, &s.state, spec = .JSON) != nil ||
		   s.state.cluster != s.config.cluster || s.state.certificate != s.config.certificate ||
		   s.state.certificate_fingerprint != s.certificate_fingerprint ||
		   !shell_state_valid(s.state) {
			return shell_error(s, "Invalid state or different cluster/client certificate; use another " +
				"--state file")
		}
		return true
	}
	if rc != sqlite.DONE do return shell_error(s, "Cannot read client state")
	random: [16]u8
	crypto.rand_bytes(random[:])
	s.state = Shell_State{cluster = strings.clone(s.config.cluster),
		certificate = strings.clone(s.config.certificate),
		certificate_fingerprint = s.certificate_fingerprint,
		session = string(hex.encode(random[:])), sequence = 1}
	return shell_state_save(s)
}

shell_call :: proc(s: ^Shell, r: service.Request) -> (response: service.Response, ok: bool) {
	r := r
	r.cluster, r.protocol, r.timeout_ms = s.config.cluster, service.PROTOCOL, s.timeout
	deadline := time.Duration(s.timeout + 250) * time.Millisecond
	bytes, received := service.client_exchange(s.config, r, deadline, &s.tls)
	if !received do return {}, false
	if json.unmarshal(bytes, &response, spec = .JSON, allocator = context.temp_allocator) != nil {
		return {}, false
	}
	ok = response.cluster == s.config.cluster && response.protocol == service.PROTOCOL &&
	     (response.status == "ok" || response.status == "error") &&
	     (response.status == "ok") == (response.error == "") &&
	     (r.op != "execute" || response.sequence == r.sequence)
	return
}

shell_resolve :: proc(s: ^Shell) -> bool {
	if s.state.pending.op == "" do return shell_error(s, "No pending write")
	r, ok := shell_call(s, s.state.pending)
	if !ok {
		return shell_error(s, "Write outcome unknown; use .pending and .retry (same durable identity)")
	}
	switch r.error {
	case "", "Constraint", "Policy", "Sequence_Gap", "Invalid_SQL", "Conflict":
		s.state.sequence += 1
	case "Invalid_Request", "Unsupported":
	case:
		return shell_error(s, fmt.tprintf("Unresolved write: %s; retain state and use .retry", r.error))
	}
	old := s.state.pending
	s.state.pending = {}
	if !shell_state_save(s) {
		s.state.pending = old
		s.quit = true
		return false
	}
	delete(old.sql)
	if r.status != "ok" do return shell_error(s, r.error)
	if s.changes do fmt.eprintf("changes: %d; node: %d; applied: %d\n", r.changes, r.node, r.applied)
	return true
}

shell_write :: proc(s: ^Shell, text: string, parameters: []service.Parameter = nil) -> bool {
	if s.state.pending.op != "" do return shell_error(s, "Resolve the pending write with .retry first")
	if len(text) > 4096 do return shell_error(s, "Transaction exceeds the 4096-byte service limit")
	s.state.pending = service.Request{op = "execute", sql = strings.clone(text),
		parameters = parameters, session = s.state.session, sequence = s.state.sequence,
		read_version = s.version}
	if !shell_state_save(s) { s.quit = true; return false }
	return shell_resolve(s)
}

shell_tls_open :: proc(s: ^Shell, cfg: service.Client_Config) -> bool {
	ctx, status := tls.context_open(cfg.certificate, cfg.key, cfg.ca)
	if status != .Ready do return shell_error(s, "Cannot load TLS client configuration")
	digest, ok := tls.context_certificate_hash(&ctx)
	fingerprint := string(hex.encode(digest[:], context.temp_allocator))
	if !ok || s.certificate_fingerprint != "" && fingerprint != s.certificate_fingerprint {
		tls.context_close(&ctx)
		return shell_error(s, "Client certificate differs from the recovery state's certificate")
	}
	tls.context_close(&s.tls)
	s.tls = ctx
	if s.certificate_fingerprint == "" do s.certificate_fingerprint = strings.clone(fingerprint)
	return true
}


shell_state_valid :: proc(state: Shell_State) -> bool {
	if len(state.session) != 32 || state.sequence == 0 || state.sequence >= 1 << 63 do return false
	nonzero := false
	for ch in state.session {
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') do return false
		if ch != '0' do nonzero = true
	}
	if !nonzero do return false
	if state.pending.op == "" do return true
	p := state.pending
	return p.op == "execute" && p.session == state.session && p.sequence == state.sequence &&
	       len(p.sql) > 0 && len(p.sql) <= 4096 && !strings.contains(p.sql, "\x00")
}
