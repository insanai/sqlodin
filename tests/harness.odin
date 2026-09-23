package tests

import host "../internal/inmemory"

TEST_MAX_MEMBERS :: 3
TEST_WINDOW :: 64
TEST_CHUNK :: 16
Cluster :: host.Cluster

cluster_create :: proc() -> ^Cluster {
	return host.create()
}

cluster_destroy :: host.destroy
cluster_drain_messages :: host.flush
cluster_route :: host.drain

// Kept for older tests: flush applies and consumes every committed batch exactly once.
cluster_apply_all :: proc(c: ^Cluster) {}
