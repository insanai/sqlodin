package service

import "core:fmt"
import "core:mem"
import "core:sync"
import db "../src/sqlite"

RESOURCE_PROFILE :: #config(SQLODIN_RESOURCE_PROFILE, false)

@(private)
profile_frame_copy_bytes: u64

// Qualification-only instrumentation. The default build has no tracking maps
// or counters on its request path. Tracker overhead is not a throughput result.
Resource_Profile :: struct { heap, temporary: mem.Tracking_Allocator }

resource_profile_begin :: proc(p: ^Resource_Profile) -> (mem.Allocator, mem.Allocator) {
	mem.tracking_allocator_init(&p.heap, context.allocator, context.allocator)
	mem.tracking_allocator_init(&p.temporary, context.temp_allocator, context.allocator)
	sync.atomic_store(&profile_frame_copy_bytes, 0)
	return mem.tracking_allocator(&p.heap), mem.tracking_allocator(&p.temporary)
}

resource_profile_end :: proc(p: ^Resource_Profile) {
	// All service/background workers have joined before this deferred call.
	defer mem.tracking_allocator_destroy(&p.heap)
	defer mem.tracking_allocator_destroy(&p.temporary)
	current, peak_bytes, peak_allocations: i64
	if db.sqlite3_status64(0, &current, &peak_bytes, 0) != db.OK do return
	if db.sqlite3_status64(9, &current, &peak_allocations, 0) != db.OK do return
	fmt.eprintf("SQLODIN_RESOURCE_PROFILE {{\"heap_calls\":%d,\"heap_bytes\":%d," +
		"\"heap_peak_bytes\":%d,\"temporary_calls\":%d,\"temporary_bytes\":%d," +
		"\"temporary_peak_bytes\":%d,\"frame_copy_bytes\":%d," +
		"\"sqlite_peak_bytes\":%d,\"sqlite_peak_allocations\":%d}}\n",
		p.heap.total_allocation_count, p.heap.total_memory_allocated, p.heap.peak_memory_allocated,
		p.temporary.total_allocation_count, p.temporary.total_memory_allocated,
		p.temporary.peak_memory_allocated, sync.atomic_load(&profile_frame_copy_bytes),
		peak_bytes, peak_allocations)
}

profile_frame_copy :: proc(bytes: int) {
	when RESOURCE_PROFILE do sync.atomic_add(&profile_frame_copy_bytes, u64(bytes))
}
