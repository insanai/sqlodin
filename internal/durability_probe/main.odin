package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import sql "../../src"
import durable "../../src/durable"

stop_at: durable.Fault
checkpoint :: proc(point: durable.Fault) {
	if point == stop_at {
		// The Linux controller observes SIGSTOP, then sends SIGKILL (no close/checkpoint).
		posix.kill(posix.getpid(), .SIGSTOP)
	}
}

must :: proc(ok: bool, location := #caller_location) {
	if !ok { fmt.eprintln(location, "probe invariant failed"); os.exit(1) }
}

run_single :: proc(path, mode, boundary: string) {
	ids := [1]sql.Node_Id{1}
	h, err := probe_open(path, "crash-test", 1, ids[:], create = mode == "init")
	must(err == .None)
	defer durable.close(h)
	if mode == "verify" {
		want, ok := strconv.parse_int(boundary)
		must(ok)
		rows, read_err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t")
		must(read_err == .None && rows == want)
		values, value_err := sql.engine_read_snapshot(&h.engine,
			"SELECT * FROM t WHERE id=1 AND v='survives'")
		must(value_err == .None && values == want)
		fmt.printf("verified rows=%d applied=%d\n", rows, h.engine.applied_through)
		return
	}
	text := "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);"
	if mode != "init" {
		text = "INSERT INTO t VALUES(1, 'survives');"
		switch boundary {
		case "before": stop_at = .Before_Journal_Commit
		case "journal": stop_at = .After_Journal_Commit
		case "application": stop_at = .After_Application_Commit
		case "ack":
		case: os.exit(2)
		}
		h.checkpoint = checkpoint
	}
	m, _ := sql.mutation_make_raw_sql(1, 0, text)
	slot, e := durable.propose(h, m)
	must(e == .None && durable.acknowledged(h, slot, &m))
	if mode != "init" && boundary == "ack" do posix.kill(posix.getpid(), .SIGSTOP)
}

main :: proc() {
	if len(os.args) != 4 do os.exit(2)
	if strings.has_prefix(os.args[2], "session-") {
		run_session(os.args[1], os.args[2], os.args[3])
	} else if strings.has_prefix(os.args[2], "restore-") {
		run_restore(os.args[1], os.args[2], os.args[3])
	} else if strings.has_prefix(os.args[2], "backup-") {
		run_backup(os.args[1], os.args[2], os.args[3])
	} else if strings.has_prefix(os.args[2], "retire-") {
		run_retirement(os.args[1], os.args[2], os.args[3])
	} else if strings.has_prefix(os.args[2], "gen-") {
		run_generation(os.args[1], os.args[2], os.args[3])
	} else if strings.has_prefix(os.args[2], "journal-") {
		run_journal_group(os.args[1], os.args[2], os.args[3])
	} else if strings.has_prefix(os.args[2], "group-") {
		run_group(os.args[1], os.args[2], os.args[3])
	} else if strings.has_prefix(os.args[2], "tx-") {
		run_transaction(os.args[1], os.args[2], os.args[3])
	} else if os.args[2] == "cluster" || os.args[2] == "cluster-verify" {
		run_cluster(os.args[1], os.args[2] == "cluster")
	} else {
		run_single(os.args[1], os.args[2], os.args[3])
	}
}

cluster_drain :: proc(hosts: [3]^durable.Host, target: int = -1,
	slot: sql.Slot = 0, expected: ^sql.Mutation = nil) {
	for _ in 0..<1000 {
		count := 0
		for h in hosts {
			p: durable.Packet
			for durable.pop(h, &p) {
				must(durable.step(hosts[int(p.env.to) - 1], durable.envelope(&p)) == .None)
				if target >= 0 && durable.acknowledged(hosts[target], slot, expected) {
					posix.kill(posix.getpid(), .SIGSTOP)
				}
				count += 1
			}
		}
		if count == 0 do return
	}
	os.exit(1)
}

run_cluster :: proc(dir: string, create: bool) {
	ids := [3]sql.Node_Id{1, 2, 3}
	hosts: [3]^durable.Host
	defer for h in hosts do durable.close(h)
	for id, i in ids {
		path := fmt.aprintf("%s/node-%d.db", dir, i)
		h, err := probe_open(path, "cluster-crash", id, ids[:], create = create)
		delete(path)
		must(err == .None)
		hosts[i] = h
	}
	if !create {
		for _ in 0..<200 {
			for h in hosts do must(durable.tick(h) == .None)
			cluster_drain(hosts)
		}
		for h in hosts {
			rows, err := sql.engine_read_snapshot(&h.engine, "SELECT * FROM t;")
			must(err == .None && rows == 80)
			values, e := sql.engine_read_snapshot(&h.engine,
				"SELECT * FROM t WHERE id BETWEEN 1 AND 80 AND v='durable'")
			must(e == .None && values == 80)
		}
		fmt.println("verified three voters: all 80 acknowledged writes survived")
		return
	}
	for i in 0..=80 {
		text := "CREATE TABLE t(id PRIMARY KEY, v);"
		if i > 0 do text = fmt.aprintf("INSERT INTO t VALUES(%d, 'durable');", i)
		m, _ := sql.mutation_make_raw_sql(sql.Node_Id(i % 3 + 1), 0, text)
		if i > 0 do delete(text)
		slot, err := durable.propose(hosts[i % 3], m)
		must(err == .None)
		target := -1
		if i == 80 do target = i % 3
		cluster_drain(hosts, target, slot, &m)
		for _ in 0..<5 {
			for h in hosts do must(durable.tick(h) == .None)
			cluster_drain(hosts, target, slot, &m)
		}
		must(durable.acknowledged(hosts[i % 3], slot, &m))
	}
	must(false) // The final acknowledgement must have stopped the process.
}

probe_open :: proc(
	path, cluster: string, id: sql.Node_Id, members: []sql.Node_Id, create: bool = false,
) -> (^durable.Host, durable.Error) {
	consensus := ""
	when #config(SQLODIN_TEST_SEPARATED, false) do consensus = fmt.aprintf("%s.consensus", path)
	defer delete(consensus)
	return durable.open(path, cluster, id, members, create, consensus_path = consensus)
}
