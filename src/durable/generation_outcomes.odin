package durable

import db "../sqlite"

// The private application copy represents exactly the certified prefix. Its
// per-slot outcome cache is no longer evidence for future host acknowledgements:
// every slot through that prefix is explicitly retired by the generation base.
// Keep session sequence/hash/result fences and transaction revision unchanged.
// Replay recreates every required outcome strictly above the new base.
@(private)
generation_trim_outcomes :: proc(h: ^Host, checkpoint: proc(Generation_Phase)) -> bool {
	if !db.begin_tx(h.engine.db) do return false
	defer db.rollback_tx(h.engine.db)
	if !db.exec(h.engine.db, "DELETE FROM _sqlodin_outcomes") do return false
	if checkpoint != nil do checkpoint(.Before_Outcome_Trim_Commit)
	if !db.commit_tx(h.engine.db) do return false
	if checkpoint != nil do checkpoint(.After_Outcome_Trim_Commit)
	return true
}
