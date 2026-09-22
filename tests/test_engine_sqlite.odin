package tests

import "core:testing"
import sqlodin "../src"

@(test)
test_engine_sqlite_multimaster_inserts :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)

	// Create table across all 3 nodes
	ddl := "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score INTEGER);"
	for i in 0..<TEST_MAX_MEMBERS {
		err := sqlodin.engine_exec(&c.engines[i], ddl)
		testing.expect(t, err == .None)
	}

	// Multi-master concurrent inserts from 3 different nodes
	pk1 := sqlodin.engine_next_id(&c.engines[0], 1000)
	m1, _ := sqlodin.mutation_make_insert(1, 1000, pk1, "users")
	sqlodin.mutation_add_text(&m1, "name", "Alice")
	sqlodin.mutation_add_int(&m1, "score", 100)

	pk2 := sqlodin.engine_next_id(&c.engines[1], 1001)
	m2, _ := sqlodin.mutation_make_insert(2, 1001, pk2, "users")
	sqlodin.mutation_add_text(&m2, "name", "Bob")
	sqlodin.mutation_add_int(&m2, "score", 200)

	pk3 := sqlodin.engine_next_id(&c.engines[2], 1002)
	m3, _ := sqlodin.mutation_make_insert(3, 1002, pk3, "users")
	sqlodin.mutation_add_text(&m3, "name", "Charlie")
	sqlodin.mutation_add_int(&m3, "score", 300)

	// Each node proposes into its own slot
	sqlodin.node_propose(&c.nodes[0], m1, &c.effects[0])
	sqlodin.node_propose(&c.nodes[1], m2, &c.effects[1])
	sqlodin.node_propose(&c.nodes[2], m3, &c.effects[2])

	cluster_drain_messages(c, 0)
	cluster_drain_messages(c, 1)
	cluster_drain_messages(c, 2)

	cluster_route(c)
	cluster_apply_all(c)

	// Verify all 3 replicas applied slots 1, 2, 3 and have 3 rows
	for i in 0..<TEST_MAX_MEMBERS {
		testing.expect_value(t, sqlodin.engine_applied_through(&c.engines[i]), sqlodin.Slot(3))
		rows, err := sqlodin.engine_read_snapshot(&c.engines[i], "SELECT * FROM users;")
		testing.expect(t, err == .None)
		testing.expect_value(t, rows, 3)
	}
}

@(test)
test_engine_sqlite_idempotent_deletes :: proc(t: ^testing.T) {
	c := cluster_create()
	defer cluster_destroy(c)

	ddl := "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT);"
	for i in 0..<TEST_MAX_MEMBERS {
		sqlodin.engine_exec(&c.engines[i], ddl)
	}

	// Insert item with ID 42
	m1, _ := sqlodin.mutation_make_insert(1, 100, 42, "items")
	sqlodin.mutation_add_text(&m1, "title", "Gadget")
	sqlodin.node_propose(&c.nodes[0], m1, &c.effects[0])
	cluster_drain_messages(c, 0)
	cluster_route(c)
	cluster_apply_all(c)

	// Both Node 2 and Node 3 propose deleting item 42
	del2, _ := sqlodin.mutation_make_delete(2, 200, 42, "items")
	del3, _ := sqlodin.mutation_make_delete(3, 201, 42, "items")

	sqlodin.node_propose(&c.nodes[1], del2, &c.effects[1])
	sqlodin.node_propose(&c.nodes[2], del3, &c.effects[2])

	cluster_drain_messages(c, 1)
	cluster_drain_messages(c, 2)
	cluster_route(c)
	cluster_apply_all(c)

	// Both deletes apply smoothly without error
	for i in 0..<TEST_MAX_MEMBERS {
		rows, err := sqlodin.engine_read_snapshot(
			&c.engines[i], "SELECT * FROM items WHERE id = 42;",
		)
		testing.expect(t, err == .None)
		testing.expect_value(t, rows, 0)
	}
}
