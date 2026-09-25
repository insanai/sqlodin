package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import service "../service"

shell_prepare_epoch :: proc(s: ^Shell) -> bool {
	if s.state.epoch_known do return true
	// Legacy recovery files belong to epoch zero. Never relabel a used identity.
	if s.state.sequence == 1 && s.state.pending.op == "" {
		r, ok := shell_call(s, service.Request{op = "session_epoch"})
		if !ok || r.status != "ok" || r.session_epoch > u64(max(i64)) {
			return shell_error(s, "Cannot discover session epoch; restore quorum and retry")
		}
		s.state.epoch = r.session_epoch
	}
	s.state.epoch_known = true
	return shell_state_save(s)
}

shell_session :: proc(s: ^Shell, command, arg: string) -> bool {
	r := service.Request{op = "session_epoch"}
	if command == ".retire-sessions" {
		if s.version != 0 || s.state.pending.op != "" {
			return shell_error(s, "Resolve pending writes and finish the transaction before retirement")
		}
		parts := strings.fields(arg, context.temp_allocator)
		if len(parts) != 2 || parts[1] != "--quiesced" {
			return shell_error(s, "Quiesce clients and resolve their pending writes, then use " +
				".retire-sessions EXPECTED_EPOCH --quiesced")
		}
		epoch, ok := strconv.parse_u64(parts[0])
		if !ok || epoch >= u64(max(i64)) do return shell_error(s, "Invalid expected session epoch")
		r.op, r.session_epoch = "retire_sessions", epoch
	} else if arg != "" { return shell_error(s, "Usage: .session") }
	response, ok := shell_call(s, r)
	if !ok do return shell_error(s, "No verified epoch response; retry the same expected epoch")
	if response.status != "ok" do return shell_error(s, response.error)
	fmt.fprintf(s.output, "session epoch: %d\n", response.session_epoch)
	if command == ".retire-sessions" {
		fmt.fprintln(s.output, "Old sessions are fenced. Open a new --state file for new writes; " +
			"retain old pending state for diagnosis.")
	}
	return true
}
