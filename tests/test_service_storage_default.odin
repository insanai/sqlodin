package tests

import "core:fmt"
import "core:os"
import "core:testing"
import service "../service"

@(test)
test_service_defaults_to_managed_storage_and_preserves_explicit_legacy_format :: proc(t: ^testing.T) {
	root := snapshot_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/node.json", root)
	defer delete(path)
	for format in ([3]int{0, 4, 5}) {
		field := "" if format == 0 else fmt.tprintf("\"storage_format\":%d,", format)
		text := fmt.aprintf(`{{%s"cluster":"test","node":1,"listen":"127.0.0.1:41001",`+
			`"data":"%s","certificate":"cert","key":"key","ca":"ca",`+
			`"members":[{{"id":1,"address":"127.0.0.1:41001","identity":"node1"}}],`+
			`"clients":["app"]}}`, field, root)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)
		delete(text)
		cfg, ok := service.load_config(path, context.temp_allocator)
		testing.expect(t, ok && cfg.storage_format == (5 if format == 0 else format))
	}
}
