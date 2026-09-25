package durable

import "base:runtime"
import "core:c"
import "core:time"
import db "../sqlite"
import snapshot "../snapshot"

// Capacity work uses one finite policy across copy, hashing and verification.
// These ceilings are not service request deadlines or recovery latency targets.
DEFAULT_MAINTENANCE_SECONDS :: snapshot.DEFAULT_LOGICAL_LIMITS.seconds
DEFAULT_MAINTENANCE_DURATION :: time.Duration(DEFAULT_MAINTENANCE_SECONDS)*time.Second
DEFAULT_MAINTENANCE_INSTRUCTIONS :: snapshot.DEFAULT_LOGICAL_LIMITS.instructions

// Only private maintenance/startup connections use this callback. Cancellation
// never becomes a replicated SQL rejection and never interrupts the live host.
// Remove handlers before releasing the flag or handing a built host to its owner.
@(private)
maintenance_handlers :: proc(h: ^Host, cancel: ^u32) {
	for database in ([2]db.Sqlite3{h.engine.db, h.consensus}) {
		if database == nil do continue
		if cancel == nil {
			db.sqlite3_progress_handler(database, 0, nil, nil)
		} else {
			db.sqlite3_progress_handler(database, 1000, maintenance_progress, cancel)
		}
	}
}

@(private)
maintenance_progress :: proc "c" (user: rawptr) -> c.int {
	context = runtime.default_context()
	return 1 if snapshot.cancelled(cast(^u32)user) else 0
}
