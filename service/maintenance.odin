package service

import "core:fmt"
import "core:os"
import "core:time"
import durable "../src/durable"

SNAPSHOT_TAIL_BYTES :: #config(SQLODIN_SNAPSHOT_TAIL_BYTES, 256*1024*1024)
SNAPSHOT_DIRTY_SECONDS :: #config(SQLODIN_SNAPSHOT_DIRTY_SECONDS, 15*60)
#assert(SNAPSHOT_TAIL_BYTES >= 4096 && SNAPSHOT_DIRTY_SECONDS >= 1)

drive_maintenance :: proc(s: ^Server) -> bool {
	h := s.host
	if h.compaction != nil {
		next, err := durable.poll_compaction(h)
		if err != .None {
			s.maintenance_error = "Compaction_Failed"
			// A failed verified journal copy may indicate source corruption.
			// Do not keep acknowledging or creating staging directories when the
			// failure cannot be confined to a recoverable capacity rejection.
			h.poisoned, s.fatal = true, true
			return false
		} else if next != nil {
			s.host = next
			durable.close(h)
			s.maintenance_error, s.maintenance_dirty = "", {}
			s.work_ready = true
		}
		return true
	}
	if s.config.maintenance == "manual" || h.snapshot == nil || h.snapshot_busy do return true
	if time.tick_since(s.maintenance_checked) < time.Second do return true
	s.maintenance_checked = time.tick_now()
	retired, retire_err := durable.retire_generation(h, s.config.cluster)
	if retire_err == .None && !retired {
		retired, retire_err = durable.retire_snapshot_image(h, s.config.cluster)
	}
	if retire_err == .None && !retired {
		retired, retire_err = durable.retire_root_application(h, s.config.cluster)
	}
	if retire_err != .None && retire_err != .Backpressure {
		s.maintenance_error = "Retention_Failed"
		h.poisoned, s.fatal = true, true
		return false
	}
	if retired do return true
	if h.engine.applied_through <= h.generation_base.key.prefix {
		s.maintenance_dirty = {}
		return true
	}
	if s.maintenance_dirty == (time.Tick{}) do s.maintenance_dirty = time.tick_now()
	if durable.snapshot_worker_running(h.snapshot) do return true
	if h.snapshot_sealed.key.prefix > h.generation_base.key.prefix {
		manifest := fmt.tprintf("%s/image-%d.manifest", h.snapshot.directory, h.snapshot_sealed.key.prefix)
		if os.exists(manifest) {
			err := durable.begin_compaction(h, s.config.cluster)
			if err != .None && err != .Backpressure {
				s.maintenance_error = "Compaction_Failed"
				h.poisoned, s.fatal = true, true
				return false
			}
			return true
		}
	}
	// One reachable voter initiates an ordered barrier; every voter captures it.
	// This is only maintenance scheduling, never a leader or a quorum assertion.
	for &c in s.connections {
		if c.state == .Ready && c.hello && c.peer != 0 && c.peer < s.config.node do return true
	}
	bytes, valid := durable.consensus_bytes(h)
	if !valid { s.maintenance_error = "Compaction_Storage"; return true }
	if bytes < SNAPSHOT_TAIL_BYTES &&
		time.tick_since(s.maintenance_dirty) < time.Duration(SNAPSHOT_DIRTY_SECONDS)*time.Second {
		return true
	}
	_, err := durable.begin_snapshot(h, 0)
	if err != .None && err != .Backpressure do s.maintenance_error = "Snapshot_Admission_Failed"
	return true
}
