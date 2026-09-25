package tests

import "core:testing"
import service "../service"

@(test)
test_network_json_depth_bounds_decode_and_preserves_sql_strings :: proc(t: ^testing.T) {
	for text in ([?]string{
		`{"op":"query","sql":"SELECT '[{]}', '\"', '\\\\'","p":[{"kind":"vector","vector":[1,2]}]}`,
		`{"op":"status","cluster":"a{b[c]d}e"}`,
		`{"text":"\\\"[[]]"}`,
	}) {
		testing.expect(t, service.json_depth_valid(transmute([]u8)text))
	}
	for text in ([?]string{`[{]}`, `{"x":"unterminated}`, `]`, `[[`, `{"x":[]`}) {
		testing.expect(t, !service.json_depth_valid(transmute([]u8)text))
	}
	data := make([]u8, 2*(service.MAX_JSON_DEPTH+1))
	defer delete(data)
	for i in 0..<service.MAX_JSON_DEPTH+1 {
		data[i] = '['
		data[len(data)-1-i] = ']'
	}
	testing.expect(t, !service.json_depth_valid(data))
	testing.expect(t, service.json_depth_valid(data[1:len(data)-1]))
}
