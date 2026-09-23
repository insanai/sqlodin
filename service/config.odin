package service

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import sql "../src"
import durable "../src/durable"
import tls "../transport/mtls"

valid_identity :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 253 do return false
	for ch in name {
		if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '.') {
			return false
		}
	}
	return true
}

load_config :: proc(path: string, allocator := context.allocator) -> (cfg: Config, ok: bool) {
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(bytes) > 65536 do return
	if json.unmarshal(bytes, &cfg, spec = .JSON, allocator = allocator) != nil do return
	if len(cfg.members) == 0 || len(cfg.members) > durable.MAX_MEMBERS ||
	   len(cfg.clients) > 24 || cfg.cluster == "" || len(cfg.cluster) > 128 ||
	   strings.contains(cfg.cluster, "\x00") || strings.contains(cfg.cluster, ";") ||
	   cfg.data == "" || cfg.certificate == "" || cfg.key == "" || cfg.ca == "" {
		return cfg, false
	}
	_, valid := address(cfg.listen)
	if !valid do return cfg, false
	found := false
	last: sql.Node_Id
	for m, i in cfg.members {
		_, endpoint_ok := address(m.address)
		if m.id <= last || m.id > 1023 || !valid_identity(m.identity) || !endpoint_ok do return cfg, false
		last = m.id
		if m.id == cfg.node { found = true; if m.address != cfg.listen do return cfg, false }
		for prev in cfg.members[:i] {
			if prev.identity == m.identity || prev.address == m.address do return cfg, false
		}
	}
	for name, i in cfg.clients {
		if !valid_identity(name) do return cfg, false
		for prev in cfg.clients[:i] do if prev == name { return cfg, false }
		for m in cfg.members do if m.identity == name { return cfg, false }
	}
	return cfg, found
}

server_open :: proc(cfg: Config, create: bool) -> (^Server, bool) {
	s := new(Server)
	s.listener = -1
	s.config = cfg
	good := false
	defer if !good do server_close(s)
	ids: [durable.MAX_MEMBERS]sql.Node_Id
	for m, i in cfg.members {
		ids[i] = m.id
		if m.id != cfg.node { s.allowed[s.allowed_count] = m.identity; s.allowed_count += 1 }
	}
	for name in cfg.clients { s.allowed[s.allowed_count] = name; s.allowed_count += 1 }
	if s.allowed_count == 0 do return nil, false
	status: tls.Status
	s.tls, status = tls.context_open(cfg.certificate, cfg.key, cfg.ca)
	if status != .Ready do return nil, false
	path := fmt.aprintf("%s/node.db", cfg.data)
	defer delete(path)
	err: durable.Error
	s.host, err = durable.open(path, cfg.cluster, cfg.node, ids[:len(cfg.members)], create)
	if err != .None { fmt.eprintln("durable open:", err); return nil, false }
	s.fingerprint = fmt.aprintf("sqlodin-net1;format4;policy6;paxos=a3e1fd78;sqlite=%x;members=%v",
		sql.engine_build_fingerprint(), ids[:len(cfg.members)])
	s.listener = socket_open(cfg.listen, true)
	if s.listener < 0 do return nil, false
	good = true
	return s, true
}

server_close :: proc(s: ^Server) {
	if s == nil do return
	for &c in s.connections do connection_close(s, &c)
	if s.listener >= 0 do posix.close(s.listener)
	tls.context_close(&s.tls)
	if s.host != nil do durable.close(s.host)
	delete(s.fingerprint)
	free(s)
}
