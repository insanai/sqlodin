package main

import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal/ansi"
import sql "../src"
import service "../service"

shell_json :: proc(value: $T) -> string {
	bytes, _ := json.marshal(value, allocator = context.temp_allocator)
	return string(bytes)
}

shell_cell :: proc(s: ^Shell, v: sql.Query_Value) -> string {
	switch v.kind {
	case .Null: return s.nullvalue
	case .Integer: return fmt.tprintf("%d", v.integer)
	case .Real: return shell_real_literal(v.real)
	case .Text: return v.text
	case .Blob:
		data, err := base64.decode(v.text, allocator = context.temp_allocator)
		if err != nil do return "<invalid blob>"
		return fmt.tprintf("X'%s'", string(hex.encode(data, allocator = context.temp_allocator)))
	}
	return ""
}

shell_visible :: proc(text: string) -> string {
	b := strings.builder_make(allocator = context.temp_allocator)
	for ch in transmute([]u8)text {
		if ch < 32 || ch == 127 do fmt.sbprintf(&b, "\\x%02x", ch)
		else do strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

shell_csv :: proc(text: string) -> string {
	escaped, _ := strings.replace_all(text, "\"", "\"\"", context.temp_allocator)
	return fmt.tprintf("\"%s\"", escaped)
}

shell_print_json :: proc(s: ^Shell, r: service.Response) {
	fmt.sbprint(&s.render, "[")
	for row, i in r.rows {
		if i > 0 do fmt.sbprint(&s.render, ",")
		fmt.sbprint(&s.render, "{")
		for v, j in row {
			if j > 0 do fmt.sbprint(&s.render, ",")
			fmt.sbprintf(&s.render, "%s:", shell_json(r.columns[j]))
			switch v.kind {
			case .Null: fmt.sbprint(&s.render, "null")
			case .Integer: fmt.sbprintf(&s.render, "%d", v.integer)
			case .Real: fmt.sbprint(&s.render, shell_real_literal(v.real))
			case .Text: fmt.sbprint(&s.render, shell_json(v.text))
			case .Blob: fmt.sbprint(&s.render, "{\"base64\":", shell_json(v.text), "}")
			}
		}
		fmt.sbprint(&s.render, "}")
	}
	fmt.sbprintln(&s.render, "]")
}

shell_print_row :: proc(s: ^Shell, values: []string, widths: []int) {
	for value, i in values {
		if i > 0 do fmt.sbprint(&s.render, "  " if s.mode == "column" else s.separator)
		if s.mode == "csv" do fmt.sbprint(&s.render, shell_csv(value))
		else if s.mode == "column" do fmt.sbprintf(&s.render, "%-*s", widths[i], shell_visible(value))
		else do fmt.sbprint(&s.render, shell_visible(value) if s.interactive else value)
	}
	fmt.sbprintln(&s.render)
}

shell_print :: proc(s: ^Shell, r: service.Response) {
	s.render = strings.builder_make(allocator = context.temp_allocator)
	defer shell_flush_result(s)
	
	for row in r.rows {
		if len(row) != len(r.columns) { shell_error(s, "Malformed result width"); return }
	}
	if s.mode == "json" { shell_print_json(s, r); return }
	if s.mode == "line" {
		for row in r.rows {
			for v, i in row do fmt.sbprintf(&s.render, "%s = %s\n",
				shell_visible(r.columns[i]), shell_visible(shell_cell(s, v)))
			fmt.sbprintln(&s.render)
		}
		return
	}
	widths := make([]int, len(r.columns), context.temp_allocator)
	for col, i in r.columns do widths[i] = len(shell_visible(col))
	for row in r.rows do for v, i in row do widths[i] = max(widths[i], len(shell_visible(shell_cell(s, v))))
	if s.headers {
		if s.mode == "column" {
			strings.write_string(&s.render, cli_style(s.output, ansi.BOLD + ";" + ansi.FG_CYAN))
		}
		shell_print_row(s, r.columns[:], widths)
		if s.mode == "column" {
			strings.write_string(&s.render, cli_style(s.output, ansi.RESET))
			for width, i in widths {
				if i > 0 do strings.write_string(&s.render, "  ")
				for _ in 0..<width do strings.write_byte(&s.render, '-')
			}
			strings.write_byte(&s.render, '\n')
		}
	}
	for row in r.rows {
		values := make([]string, len(row), context.temp_allocator)
		for v, i in row do values[i] = shell_cell(s, v)
		shell_print_row(s, values, widths)
	}
}

shell_output_close :: proc(s: ^Shell) {
	if s.output != os.stdout {
		if os.close(s.output) != nil do shell_error(s, "Output close failed")
		s.output = os.stdout
	}
}

shell_flush_result :: proc(s: ^Shell) {
	defer if s.once { shell_output_close(s); s.once = false }
	data := transmute([]u8)strings.to_string(s.render)
	for len(data) > 0 {
		n, err := os.write(s.output, data)
		if err != nil || n <= 0 {
			shell_error(s, "Cannot write query output")
			s.quit = true
			return
		}
		data = data[n:]
	}
}
