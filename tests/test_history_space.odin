package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import sql "../src"
import durable "../src/durable"
import db "../src/sqlite"

@(test)
test_history_quota_counts_owned_staging_and_recovers_after_retirement :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	testing.expect(t, durable.begin_compaction(h, "test") == .None)
	if h.compaction == nil do return
	path := fmt.aprintf("%s/consensus.db", h.compaction.directory)
	defer delete(path)
	durable.generation_release_worker(h)
	// A sparse owned abandoned file exercises an actual 8 GiB pathname extent
	// without allocating 8 GiB locally. This is admission, not capacity evidence.
	name := strings.clone_to_cstring(path)
	defer delete(name)
	fd := posix.open(name, {.RDWR, .CREAT}, {.IRUSR, .IWUSR})
	testing.expect(t, fd >= 0)
	if fd < 0 do return
	testing.expect(t, posix.ftruncate(fd, posix.off_t(durable.HISTORY_LIMIT)) == nil)
	posix.close(fd)
	bytes, valid := durable.history_usage(h)
	testing.expect(t, valid && bytes >= durable.HISTORY_LIMIT)
	sequence, delivered := h.sequence, h.node.delivered_through
	_, err := durable.propose(h, sql.mutation_make_skip(1, 0))
	testing.expect(t, err == .Backpressure && !h.poisoned)
	_, read_err := durable.begin_read(h, 0)
	testing.expect(t, read_err == .Backpressure && !h.poisoned)
	testing.expect(t, h.sequence == sequence && h.node.delivered_through == delivered)
	retired, retire_err := durable.retire_generation(h, "test")
	testing.expect(t, retired && retire_err == .None && !os.exists(path))
	bytes, valid = durable.history_usage(h)
	testing.expect(t, valid && bytes < durable.HISTORY_ADMISSION_RESERVE)
	testing.expect(t, durable.history_admission(h) == .None)
	_, err = durable.propose(h, sql.mutation_make_skip(1, 0))
	testing.expect(t, err == .None)
}

@(test)
test_history_measurement_failure_poisoned_before_proposal :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	h := c.hosts[0]
	// An unexpected symlink cannot hide a retained journal from accounting.
	path := strings.clone_to_cstring(fmt.tprintf("%s/consensus.db-journal", h.store_root))
	defer delete(path)
	testing.expect(t, posix.symlink("missing", path) == nil)
	_, valid := durable.history_usage(h)
	testing.expect(t, !valid)
	sequence := h.sequence
	_, err := durable.propose(h, sql.mutation_make_skip(1, 0))
	testing.expect(t, err == .Storage && h.poisoned && h.sequence == sequence)
}

@(test)
test_history_accounting_rejects_a_missing_active_inventory_entry :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	next, err := durable.compact_store(c.hosts[0], "test")
	testing.expect(t, err == .None)
	if next == nil do return
	durable.close(c.hosts[0])
	c.hosts[0] = next
	path := fmt.aprintf("%s/consensus.db", next.store_root)
	defer delete(path)
	catalog, opened := db.open(path)
	testing.expect(t, opened)
	if !opened do return
	defer db.close(catalog)
	testing.expect(t, db.exec(catalog, "DELETE FROM _sqlodin_generation_inventory"))
	_, valid := durable.history_usage(next)
	testing.expect(t, !valid)
	testing.expect(t, durable.history_admission(next) == .Storage && next.poisoned)
}

@(test)
test_history_hard_reserve_fails_closed_without_publishing_a_promise :: proc(t: ^testing.T) {
	c := install_test_open(t)
	defer install_test_close(c)
	_ = install_test_seal(t, c)
	h := c.hosts[0]
	testing.expect(t, durable.begin_compaction(h, "test") == .None)
	if h.compaction == nil do return
	path := strings.clone_to_cstring(fmt.tprintf("%s/consensus.db", h.compaction.directory))
	defer delete(path)
	durable.generation_release_worker(h)
	fd := posix.open(path, {.RDWR, .CREAT}, {.IRUSR, .IWUSR})
	testing.expect(t, fd >= 0)
	if fd < 0 do return
	testing.expect(t, posix.ftruncate(fd, posix.off_t(durable.HISTORY_LIMIT-32*1024*1024)) == nil)
	posix.close(fd)
	promised, sequence := h.node.ledger.promised, h.sequence
	env := sql.Envelope(sql.Mutation){from = 1, to = 1,
		message = sql.Prepare_Message{sql.ballot_make(99, 0, 1), 6, 6, .Global}}
	testing.expect(t, durable.step(h, env) == .Storage && h.poisoned)
	testing.expect(t, h.sequence == sequence)
	durable.close(h)
	ids := [3]sql.Node_Id{1, 2, 3}
	err: durable.Error
	c.hosts[0], err = durable.open_store(c.directories[0], "test", 1, ids[:])
	h = c.hosts[0]
	testing.expect(t, err == .None)
	if h == nil do return
	testing.expect(t, h.node.ledger.promised == promised && h.sequence == sequence)
	expect_rows(t, &h.engine, "SELECT * FROM t", 1)
	retired, retire_err := durable.retire_generation(h, "test")
	testing.expect(t, retired && retire_err == .None)
	testing.expect(t, durable.step(h, env) == .None && !h.poisoned)
}
