package service

import sql "../src"

respond_status :: proc(s: ^Server, c: ^Connection) -> bool {
	return enqueue(c, Response{status = "ok", cluster = s.config.cluster, node = s.config.node,
		protocol = PROTOCOL, applied = s.host.engine.applied_through, members = s.config.members,
		policy = sql.REPLICATION_POLICY,
		decided = s.host.node.delivered_through, highest_seen = s.host.node.highest_seen,
		journal_records = s.host.sequence, recovery = s.host.recovery,
		snapshot_prefix = snapshot_prefix(s), snapshot_sealed = s.host.snapshot_sealed.key.prefix,
		snapshot_error = snapshot_error(s), generation_prefix = s.host.generation_base.key.prefix})
}
