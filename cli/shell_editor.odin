package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:mem/virtual"
import "core:strings"
import "core:terminal/ansi"
import "core:terminal"
import "core:sys/posix"

foreign import local_shell "../build/native/libsqlodin_shell.a"
@(default_calling_convention="c")
foreign local_shell {
	sqlodin_terminal_begin :: proc() -> c.int ---
	sqlodin_terminal_end :: proc() ---
	sqlodin_terminal_columns :: proc() -> c.int ---
	sqlodin_terminal_width :: proc(value: c.int) -> c.int ---
}

Shell_Editor :: struct { history: [dynamic]string }
shell_previous_char :: proc(text: []u8, position: int) -> int {
	at := max(0, position - 1)
	for at > 0 && text[at] & 0xc0 == 0x80 do at -= 1
	return at
}

shell_next_char :: proc(text: []u8, position: int) -> int {
	at := min(len(text), position + 1)
	for at < len(text) && text[at] & 0xc0 == 0x80 do at += 1
	return at
}

shell_display_width :: proc(text: string) -> int {
	width := 0
	for r in text do width += int(sqlodin_terminal_width(c.int(r)))
	return width
}

shell_editor_draw :: proc(s: ^Shell, text: []u8, cursor: int, continuation: bool) {
	scratch := virtual.arena_temp_begin(&s.scratch)
	defer virtual.arena_temp_end(scratch)
	width := max(10, int(sqlodin_terminal_columns()) - 12)
	start := 0
	for start < cursor && shell_display_width(string(text[start:cursor])) >= width {
		start = shell_next_char(text, start)
	}
	end := cursor
	for end < len(text) {
		next := shell_next_char(text, end)
		if shell_display_width(string(text[start:next])) >= width do break
		end = next
	}
	fmt.fprint(os.stderr, "\r" + ansi.CSI + "2" + ansi.EL)
	shell_prompt(s, continuation)
	fmt.fprint(os.stderr, string(text[start:end]))
	back := shell_display_width(string(text[cursor:end]))
	if back > 0 do fmt.fprintf(os.stderr, "%s%d%s", ansi.CSI, back, ansi.CUB)
}

shell_editor_escape :: proc() -> u8 {
	bytes: [3]u8
	for i in 0..<2 {
		p := posix.pollfd{fd = 0, events = {.IN}}
		if posix.poll(&p, 1, 100) <= 0 do return 0
		if posix.read(0, &bytes[i], 1) != 1 do return 0
	}
	if bytes[0] != '[' && bytes[0] != 'O' do return 0
	if bytes[1] >= '1' && bytes[1] <= '9' {
		p := posix.pollfd{fd = 0, events = {.IN}}
		if posix.poll(&p, 1, 100) <= 0 || posix.read(0, &bytes[2], 1) != 1 do return 0
		if bytes[1] == '3' && bytes[2] == '~' do return 127
		return 0
	}
	return bytes[1]
}

shell_editor_complete :: proc(text: ^[dynamic]u8) {
	prefix := string(text^[:])
	matches := 0
	candidate := ""
	for word in ([?]string{".help", ".tables", ".schema", ".indexes", ".status", ".health",
		".connection", ".consistency", ".pending", ".retry", ".mode", ".headers", ".read",
		".output", ".once", ".parameter", ".quit", ".limits", ".show", ".timer", ".timeout",
		"SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "BEGIN", "COMMIT", "ROLLBACK"}) {
		if len(prefix) > 0 && strings.has_prefix(word, prefix) { candidate = word; matches += 1 }
	}
	if matches == 1 { clear(text); append(text, ..transmute([]u8)candidate) }
	else do fmt.fprint(os.stderr, ansi.BEL)
}

shell_editor_key :: proc(text: ^[dynamic]u8, cursor: ^int, key: u8) {
	switch key {
	case 'D': cursor^ = shell_previous_char(text^[:], cursor^)
	case 'C': cursor^ = shell_next_char(text^[:], cursor^)
	case 'H': cursor^ = 0
	case 'F': cursor^ = len(text^)
	case 127:
		if cursor^ < len(text^) {
			next := shell_next_char(text^[:], cursor^)
			copy(text^[cursor^:], text^[next:])
			resize(text, len(text^) - next + cursor^)
		}
	}
}

shell_editor_line :: proc(
	s: ^Shell, e: ^Shell_Editor, continuation: bool,
) -> (line: string, eof, cancelled: bool) {
	text := make([dynamic]u8, 0, 256)
	defer delete(text)
	cursor, history := 0, len(e.history)
	for {
		shell_editor_draw(s, text[:], cursor, continuation)
		ch: u8
		if posix.read(0, &ch, 1) != 1 do return "", true, false
		if ch == 3 { fmt.eprintln("^C"); return "", false, true }
		if ch == 4 && len(text) == 0 { fmt.eprintln(); return "", true, false }
		if ch == '\r' || ch == '\n' { fmt.eprintln(); break }
		if ch == 27 {
			key := shell_editor_escape()
			if key == 'A' || key == 'B' {
				history = clamp(history + (-1 if key == 'A' else 1), 0, len(e.history))
				clear(&text)
				if history < len(e.history) do append(&text, ..transmute([]u8)e.history[history])
				cursor = len(text)
			} else do shell_editor_key(&text, &cursor, key)
			continue
		}
		if ch == 1 { cursor = 0; continue }
		if ch == 5 { cursor = len(text); continue }
		if ch == 21 { clear(&text); cursor = 0; continue }
		if ch == 11 { resize(&text, cursor); continue }
		if ch == 9 { shell_editor_complete(&text); cursor = len(text); continue }
		if ch == 127 || ch == 8 {
			if cursor > 0 {
				previous := shell_previous_char(text[:], cursor)
				copy(text[previous:], text[cursor:]); resize(&text, len(text) - cursor + previous)
				cursor = previous
			}
			continue
		}
		if ch < 32 || len(text) >= 4095 { fmt.fprint(os.stderr, ansi.BEL); continue }
		append(&text, 0)
		for i := len(text) - 1; i > cursor; i -= 1 do text[i] = text[i - 1]
		text[cursor] = ch; cursor += 1
	}
	line = strings.clone(string(text[:]))
	if line != "" && (len(e.history) == 0 || e.history[len(e.history) - 1] != line) {
		if len(e.history) == 100 {
			delete(e.history[0]); copy(e.history[:], e.history[1:]); resize(&e.history, 99)
		}
		append(&e.history, strings.clone(line))
	}
	return
}

shell_interactive :: proc(s: ^Shell) -> bool {
	if !terminal.is_terminal(os.stderr) || os.get_env("TERM", context.temp_allocator) == "dumb" ||
	   sqlodin_terminal_begin() == 0 {
		return shell_stream(s, os.stdin, true)
	}
	defer sqlodin_terminal_end()
	e: Shell_Editor
	defer { for line in e.history do delete(line); delete(e.history) }
	pending := strings.builder_make()
	defer strings.builder_destroy(&pending)
	for !s.quit {
		continuation := strings.trim_space(strings.to_string(pending)) != ""
		line, eof, cancelled := shell_editor_line(s, &e, continuation)
		if eof do break
		if cancelled { strings.builder_reset(&pending); continue }
		s.line += 1
		shell_feed(s, line, &pending)
		strings.write_byte(&pending, '\n')
		delete(line)
	}
	return true
}
