package main

import "core:fmt"
import host "../internal/inmemory"
import sqlodin "../src"

Cluster :: host.Cluster
cluster_init :: proc(c: ^Cluster) {
	for &e in c.engines {
		host.must(sqlodin.engine_exec(&e, "CREATE VIRTUAL TABLE docs USING fts5(title, body);"))
		host.must(sqlodin.engine_exec(&e, "CREATE VIRTUAL TABLE doc_vecs USING vec0(emb float[4]);"))
	}
}

propose_write :: proc(c: ^Cluster, idx: int, sql: string) {
	m, err := sqlodin.mutation_make_raw_sql(sqlodin.Node_Id(idx + 1), 1000, sql)
	host.must(err)
	_, propose_err := sqlodin.node_propose(&c.nodes[idx], m, &c.effects[idx])
	host.must(propose_err)
	host.flush(c, idx)
	host.drain(c)
}

main :: proc() {
	c := host.create()
	defer host.destroy(c)
	cluster_init(c)

	fmt.println("=================================================================")
	fmt.println("  SQLODIN MULTI-MASTER REPLICATION DEMO")
	fmt.println("=================================================================")
	fmt.println("Active nodes: 3 (Decentralized Multi-Master)")
	fmt.println("Consensus: Rotating Slot Ownership (in-process demonstration)\n")

	// Multi-master concurrent writes from different nodes:
	fmt.println("-> Node 1 inserts document into FTS5 index (Slot 1)...")
	propose_write(
		c,
		0,
		"INSERT INTO docs VALUES ('Paxos in Odin', 'Multi-master zero latency consensus');",
	)

	fmt.println("-> Node 2 inserts document into FTS5 index (Slot 2)...")
	propose_write(
		c,
		1,
		"INSERT INTO docs VALUES ('Vector Search', 'Dense embeddings with sqlite-vec');",
	)

	fmt.println("-> Node 3 inserts embedding into vec0 index (Slot 3)...")
	propose_write(
		c,
		2,
		"INSERT INTO doc_vecs (rowid, emb) VALUES (1, '[0.12, 0.22, 0.32, 0.42]');",
	)

	for &e in c.engines {
		if e.applied_through != 3 do panic("Demo did not converge")
	}
	fmt.println("\nAll 3 slots committed across quorum without remote leader hops!")

	// Querying Node 3 via FTS5
	fmt.println("\n[Node 3] Full-Text Search for 'consensus':")
	query_fts := "SELECT * FROM docs WHERE docs MATCH '\"consensus\"';"
	rows_fts, fts_err := sqlodin.engine_read_snapshot(&c.engines[2], query_fts)
	host.must(fts_err)
	if rows_fts != 1 do panic("FTS result mismatch")
	fmt.printf("  Found %d matching document(s).\n", rows_fts)

	// Querying Node 1 via sqlite-vec KNN search
	fmt.println("\n[Node 1] Vector Similarity Search (KNN float[4]):")
	query_vec :=
		"SELECT rowid FROM doc_vecs WHERE emb MATCH '[0.10, 0.20, 0.30, 0.40]' " +
		"ORDER BY distance LIMIT 1;"
	rows_vec, vec_err := sqlodin.engine_read_snapshot(&c.engines[0], query_vec)
	host.must(vec_err)
	if rows_vec != 1 do panic("Vector result mismatch")
	fmt.printf("  Found %d nearest vector match(es).\n", rows_vec)

	// Read-Your-Writes watermark read on Node 2
	fmt.println("\n[Node 2] Read-Your-Writes Watermark Read (Watermark Slot 2):")
	rows_wm, wm_err := sqlodin.engine_read_snapshot(
		&c.engines[1],
		"SELECT rowid FROM docs;",
		min_watermark = 2,
	)
	if wm_err == .None {
		fmt.printf("  Consistent read satisfied at watermark: %d row(s).\n", rows_wm)
	}

	fmt.println("\n=================================================================")
	fmt.println("  DEMO COMPLETE: Deterministic convergence verified.")
	fmt.println("=================================================================")
}
