package service

import "core:time"
import "core:sys/posix"
import sql "../src"
import durable "../src/durable"
import mtls "../transport/mtls"

PROTOCOL :: 1
MAX_CONNECTIONS :: 32
MAX_INPUT :: 65536
MAX_OUTPUT :: 1024 * 1024
MAX_QUEUED :: 2 * 1024 * 1024
Member :: struct { id: sql.Node_Id, address, identity: string }
Config :: struct {
	cluster: string, node: sql.Node_Id, listen, data, certificate, key, ca: string,
	members: []Member, clients: []string,
}
Parameter :: struct { kind: string, integer: i64, real: f64, text: string, vector: []f32 }
Request :: struct {
	op, cluster, fingerprint, sql, session, consistency, read_sql: string,
	read_version: u64, read_parameters: []Parameter,
	protocol: int, node: u16, sequence: u64, timeout_ms: int,
	parameters: []Parameter, packet: Wire,
}
Response :: struct {
	status, error, message, cluster: string,
	protocol: int, node: sql.Node_Id, sequence: u64,
	applied: sql.Slot, changes: i64, read_version: u64, lastrowid: i64,
	columns: [dynamic]string, rows: [dynamic][]sql.Query_Value,
	members: []Member,
}
State :: enum { Unused, Connecting, Handshake, Ready }
Pending :: enum { None, Write, Read }
Connection :: struct {
	state: State, fd: posix.FD, tls: mtls.Stream, peer: sql.Node_Id, hello: bool,
	read_wait, write_wait, handshake_wait: mtls.Status,
	born, activity, pending_since: time.Tick, timeout: time.Duration,
	header: [4]u8, header_used, input_used: int, input: []u8,
	out: [64][]u8, out_head, out_count, out_offset, queued: int,
	pending: Pending, value: sql.Mutation, slot: sql.Slot, ticket: durable.Read_Ticket,
	local_read: bool, transaction_begin, preview: bool, query_value: sql.Mutation,
}
Server :: struct {
	config: Config, host: ^durable.Host, tls: mtls.Context, listener: posix.FD,
	connections: [MAX_CONNECTIONS]Connection,
	allowed: [32]string, allowed_count: int,
	fingerprint: string, last_tick, last_dial: time.Tick, fatal: bool,
}
