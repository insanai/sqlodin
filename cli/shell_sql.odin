package main

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import service "../service"

foreign import local_shell "../build/native/libsqlodin_shell.a"
@(default_calling_convention="c")
foreign local_shell {
	sqlite3_complete :: proc(sql: cstring) -> c.int ---
}

// Scan tokens without interpreting quoted strings, identifiers or comments.
shell_token :: proc(text: string, at: ^int) -> string {
	for at^ < len(text) {
		start := at^
		ch := text[at^]
		at^ += 1
		if ch <= ' ' do continue
		if ch == '-' && at^ < len(text) && text[at^] == '-' {
			for at^ < len(text) && text[at^] != '\n' do at^ += 1
			continue
		}
		if ch == '/' && at^ < len(text) && text[at^] == '*' {
			at^ += 1
			for at^ + 1 < len(text) && text[at^:at^ + 2] != "*/" do at^ += 1
			at^ = min(len(text), at^ + 2)
			continue
		}
		if ch == '\'' || ch == '"' || ch == '`' || ch == '[' {
			end := u8(']') if ch == '[' else ch
			for at^ < len(text) {
				c := text[at^]; at^ += 1
				if c == end {
					if ch != '[' && at^ < len(text) && text[at^] == end { at^ += 1; continue }
					break
				}
			}
			return text[start:at^]
		}
		if ch == '?' || ch == ':' || ch == '@' || ch == '$' ||
		   ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch == '_' {
			for at^ < len(text) {
				c := text[at^]
				if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
				     c >= '0' && c <= '9' || c == '_' || c >= 128) { break }
				at^ += 1
			}
		}
		return text[start:at^]
	}
	return ""
}

shell_bound_sql :: proc(s: ^Shell, text: string) -> (string, bool) {
	// Bind by rendering typed SQL literals, never accepting unparsed SQL expressions.
	// This lets staged statements retain each command's parameter values unchanged.
	b := strings.builder_make(allocator = context.temp_allocator)
	at, copied, next := 0, 0, 1
	for {
		token := shell_token(text, &at)
		if token == "" do break
		if token[0] != '?' && token[0] != ':' && token[0] != '@' && token[0] != '$' do continue
		if token[0] != '?' { shell_error(s, "Use positional ? or ?1..?16 parameters"); return "", false }
		index := next
		if len(token) > 1 {
			n, ok := strconv.parse_int(token[1:])
			if !ok { shell_error(s, "Invalid parameter"); return "", false }
			index = n
		}
		next = max(next, index + 1)
		if index < 1 || index > 16 || !s.parameter_set[index - 1] {
			shell_error(s, "Unset parameter (use .parameter set ?N JSON_VALUE)"); return "", false
		}
		strings.write_string(&b, text[copied:at - len(token)])
		p := s.parameters[index - 1]
		value := "NULL"
		switch p.kind {
		case "integer": value = fmt.tprintf("%d", p.integer)
		case "real": value = shell_real_literal(p.real)
		case "text": value = shell_quote(p.text)
		}
		strings.write_string(&b, value)
		copied = at
	}
	strings.write_string(&b, text[copied:])
	result := strings.to_string(b)
	if len(result) > 4096 { shell_error(s, "SQL exceeds the 4096-byte service limit"); return "", false }
	return result, true
}

shell_transaction_reset :: proc(s: ^Shell) {
	s.version, s.transaction_failed = 0, false
	delete(s.staged); s.staged = ""
	for p in s.savepoints { delete(p.name); delete(p.sql) }
	clear(&s.savepoints)
}

shell_transaction :: proc(s: ^Shell, word, text: string) -> bool {
	if word == "ROLLBACK" && (text == "ROLLBACK;" || text == "ROLLBACK" ||
	                          text == "ROLLBACK TRANSACTION;" || text == "ROLLBACK TRANSACTION") {
		if s.version == 0 do return shell_error(s, "No active transaction")
		shell_transaction_reset(s)
		return true
	}
	if word == "BEGIN" {
		if s.version != 0 do return shell_error(s, "Transaction already active")
		if s.state.pending.op != "" do return shell_error(s, "Resolve the pending write first")
		if text != "BEGIN" && text != "BEGIN;" && text != "BEGIN TRANSACTION;" &&
		   text != "BEGIN DEFERRED;" { return shell_error(s, "Use BEGIN; (optimistic serializable)") }
		r, ok := shell_call(s, service.Request{op = "begin"})
		if !ok || r.status != "ok" || r.read_version == 0 {
			return shell_error(s, "Cannot begin transaction")
		}
		s.version = r.read_version
		return true
	}
	if word == "COMMIT" || word == "END" {
		if text != word && text != fmt.tprintf("%s;", word) &&
		   text != fmt.tprintf("%s TRANSACTION;", word) {
			return shell_error(s, "Use COMMIT; or END;")
		}
		if s.version == 0 do return shell_error(s, "No active transaction")
		if s.transaction_failed do return shell_error(s, "Transaction failed; ROLLBACK is required")
		ok := false
		if s.staged != "" do ok = shell_write(s, s.staged)
		else {
			r, received := shell_call(s, service.Request{op = "preview", read_version = s.version})
			ok = received && r.status == "ok"
			if !ok do shell_error(s, "Read-only transaction could not validate its revision")
		}
		shell_transaction_reset(s)
		return ok
	}
	return shell_savepoint(s, text)
}

shell_savepoint :: proc(s: ^Shell, text: string) -> bool {
	if s.version == 0 do return shell_error(s, "Use BEGIN before SAVEPOINT")
	at := 0
	command := shell_token(text, &at)
	name := shell_token(text, &at)
	if command == "ROLLBACK" {
		if name == "TRANSACTION" do name = shell_token(text, &at)
		if name != "TO" do return shell_error(s, "Use ROLLBACK; or ROLLBACK TO name;")
		name = shell_token(text, &at)
	}
	if name == "SAVEPOINT" && command != "SAVEPOINT" do name = shell_token(text, &at)
	if name == "" || name == ";" || len(name) > 64 do return shell_error(s, "Missing savepoint name")
	tail := shell_token(text, &at)
	if tail != "" && tail != ";" || shell_token(text, &at) != "" {
		return shell_error(s, "Invalid savepoint")
	}
	if s.transaction_failed do return shell_error(s, "Transaction failed; full ROLLBACK is required")
	if command == "SAVEPOINT" {
		if len(s.savepoints) == 16 do return shell_error(s, "At most 16 savepoints")
		append(&s.savepoints, Shell_Savepoint{strings.clone(name), strings.clone(s.staged)})
		return true
	}
	for i := len(s.savepoints) - 1; i >= 0; i -= 1 {
		if s.savepoints[i].name != name do continue
		if command == "ROLLBACK" { delete(s.staged); s.staged = strings.clone(s.savepoints[i].sql) }
		keep := i + 1 if command == "ROLLBACK" else i
		for p in s.savepoints[keep:] { delete(p.name); delete(p.sql) }
		resize(&s.savepoints, keep)
		return true
	}
	return shell_error(s, "No such savepoint")
}

shell_sql :: proc(s: ^Shell, text: string) -> bool {
	if strings.contains(text, "\x00") do return shell_error(s, "NUL bytes are not valid SQL input")
	at := 0
	first := strings.to_upper(shell_token(text, &at), context.temp_allocator)
	if first == "" || first == ";" do return true
	if first == "BEGIN" || first == "COMMIT" || first == "END" || first == "ROLLBACK" ||
	   first == "SAVEPOINT" || first == "RELEASE" {
		control := shell_control_text(text)
		if control == "" do return shell_error(s, "Invalid_SQL")
		return shell_transaction(s, first, control)
	}
	if s.transaction_failed do return shell_error(s, "Transaction failed; ROLLBACK is required")
	bound, valid := shell_bound_sql(s, text)
	if !valid do return false
	r := service.Request{op = "query", sql = bound, consistency = s.consistency}
	if s.version != 0 {
		r = service.Request{op = "preview", sql = s.staged, read_version = s.version, read_sql = bound}
	}
	response, received := shell_call(s, r)
	if received && response.status == "ok" { shell_print(s, response); return true }
	if !received do return shell_error(s, "No verified query response")
	if response.error != "Invalid_SQL" {
		if s.version != 0 do s.transaction_failed = true
		return shell_error(s, response.error)
	}
	if s.version == 0 do return shell_write(s, bound)
	body := fmt.tprintf("%s\n%s", s.staged, bound)
	if !strings.has_suffix(strings.trim_space(body), ";") do body = fmt.tprintf("%s;", body)
	if len(body) > 4096 do return shell_error(s, "Transaction exceeds 4096 bytes")
	response, received = shell_call(s, service.Request{
		op = "preview", sql = body, read_version = s.version})
	if !received || response.status != "ok" {
		s.transaction_failed = true
		return shell_error(s, response.error if received else "No verified preview response")
	}
	delete(s.staged); s.staged = strings.clone(body)
	if s.changes do fmt.eprintf("staged changes: %d (not committed)\n", response.changes)
	return true
}

shell_control_text :: proc(text: string) -> string {
	complete := fmt.tprintf("%s;", text)
	if sqlite3_complete(strings.clone_to_cstring(complete, context.temp_allocator)) == 0 do return ""
	b := strings.builder_make(allocator = context.temp_allocator)
	at := 0
	for {
		token := shell_token(text, &at)
		if token == "" do break
		if token != ";" && strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, strings.to_upper(token, context.temp_allocator))
	}
	if !strings.has_suffix(strings.to_string(b), ";") do strings.write_byte(&b, ';')
	return strings.to_string(b)
}


shell_real_literal :: proc(value: f64) -> string {
	text := fmt.tprintf("%.17g", value)
	if !strings.contains_any(text, ".eE") do text = fmt.tprintf("%s.0", text)
	return text
}
