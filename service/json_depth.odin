package service

MAX_JSON_DEPTH :: 64

// The frame byte limit alone does not bound a recursive decoder's stack use.
// Scan iteratively before unmarshalling, ignoring braces and escaped quotes in
// strings. This is a resource guard; the JSON decoder still validates syntax.
json_depth_valid :: proc(data: []u8) -> bool {
	stack: [MAX_JSON_DEPTH]u8
	depth := 0
	quoted, escaped := false, false
	for ch in data {
		if quoted {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do quoted = false
			continue
		}
		switch ch {
		case '"': quoted = true
		case '{', '[':
			if depth == len(stack) do return false
			stack[depth] = ch
			depth += 1
		case '}', ']':
			if depth == 0 do return false
			depth -= 1
			if ch == '}' && stack[depth] != '{' || ch == ']' && stack[depth] != '[' do return false
		}
	}
	return depth == 0 && !quoted
}
