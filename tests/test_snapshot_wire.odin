package tests

import "core:encoding/json"
import "core:testing"
import vmem "core:mem/virtual"
import service "../service"
import snapshot "../src/snapshot"

@(test)
test_snapshot_request_wire_preserves_hello_and_receipt :: proc(t: ^testing.T) {
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	for has_receipt in ([2]bool{false, true}) {
		receipt := snapshot.Receipt{voter = 1, bytes = 4096}
		receipt.key.configuration[0], receipt.key.engine[0], receipt.key.logical_state[0] = 1, 2, 3
		receipt.key.generation, receipt.key.prefix, receipt.image[0] = 5, 5, 4
		request := service.Request{op = "hello", cluster = "test", protocol = 1, node = 1,
			fingerprint = "format5;snapshot=1"}
		if has_receipt {
			request.op = "snapshot_receipt"
			request.receipt = service.snapshot_encode_receipt(receipt)
		}
		bytes, encode_err := json.marshal(request, {use_enum_names = true})
		defer delete(bytes)
		testing.expect(t, encode_err == nil)
		decoded: service.Request
		decode_err := json.unmarshal(bytes, &decoded, spec = .JSON,
			allocator = vmem.arena_allocator(&arena))
		testing.expect_value(t, decode_err, json.Unmarshal_Error(nil))
		testing.expect(t, decoded.op == request.op && decoded.fingerprint == request.fingerprint)
		if has_receipt do testing.expect(t, decoded.receipt == request.receipt && decoded.receipt != "")
	}
}
