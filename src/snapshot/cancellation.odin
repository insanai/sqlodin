package snapshot

import "core:sync"
import "core:time"

// Callers set this atomically and retain its storage until the worker joins.
// Cancellation is cooperative between bounded chunks and SQLite VM callbacks;
// it cannot interrupt an operating-system call blocked on a failing device.
cancelled :: proc(flag: ^u32) -> bool {
	return flag != nil && sync.atomic_load(flag) != 0
}

@(private)
verify_budget_active :: proc(budget: ^Verify_Budget) -> bool {
	if cancelled(budget.cancel) { budget.error = .Cancelled; return false }
	if time.tick_since(budget.started) >= budget.deadline { budget.error = .Timeout; return false }
	return true
}
