package service

import "core:time"
import "core:sys/posix"
import sql "../src"
import durable "../src/durable"
import mtls "../transport/mtls"

PROTOCOL :: 1
MAX_CONNECTIONS :: 32
MAX_CLIENT_CONNECTIONS :: 24
MAX_INCOMING_HANDSHAKES :: 4
MAX_INPUT :: 65536
MAX_OUTPUT :: 1024 * 1024
MAX_QUEUED :: 2 * 1024 * 1024
// Frames per connection; MAX_QUEUED remains the byte bound.
MAX_QUEUED_FRAMES :: 256
// Peer packets buffered for one service turn, stepped in MAX_STEP_BATCH groups.
MAX_INCOMING :: 128
Member :: struct { id: sql.Node_Id, address, identity: string }
Config :: struct {
	storage_format: int, // omitted/5 = managed separated store; explicit 4 = legacy migration source
	maintenance: string, // empty/auto schedules maintenance; manual requires explicit operator control
	cluster: string, node: sql.Node_Id, listen, data, certificate, key, ca: string,
	members: []Member, clients: []string,
}
Parameter :: struct { kind: string, integer: i64, real: f64, text: string, vector: []f32 }
Request :: struct {
	receipt: string,
	session_epoch: u64,
	snapshot_prefix: sql.Slot, snapshot_offset: u64,
	op, cluster, fingerprint, sql, session, consistency, read_sql: string,
	read_version: u64, read_parameters: []Parameter,
	protocol: int, node: u16, sequence: u64, timeout_ms: int,
	parameters: []Parameter, packet: Wire,
	frontier: u64, // peer-only quorum-read frontier reply (SOD 0005 M6)
}
Response :: struct {
	snapshot_requested, snapshot_prefix, snapshot_sealed, generation_prefix: sql.Slot,
	snapshot_error: string,
	session_epoch: u64,
	status, error, message, cluster: string,
	protocol: int, node: sql.Node_Id, sequence: u64,
	policy: int,
	applied: sql.Slot, changes: i64, read_version: u64, lastrowid: i64,
	columns: [dynamic]string, rows: [dynamic][]sql.Query_Value,
	members: []Member,
	decided, highest_seen: sql.Slot, journal_records: u64,
	recovery: durable.Recovery_Stats,
}
State :: enum { Unused, Connecting, Handshake, Ready }
Pending :: enum { None, Write, Read }
Connection :: struct {
	state: State, fd: posix.FD, tls: mtls.Stream, peer: sql.Node_Id, hello, snapshot_sending: bool,
	snapshot_offered_prefix: sql.Slot,
	admission_rejected, close_after_flush: bool,
	read_wait, write_wait, handshake_wait: mtls.Status,
	born, activity, pending_since: time.Tick, timeout: time.Duration,
	header: [4]u8, header_used, input_used: int, input: []u8,
	out: [MAX_QUEUED_FRAMES][]u8, out_head, out_count, out_offset, queued: int,
	pending: Pending, value: sql.Mutation, slot: sql.Slot, ticket: durable.Read_Ticket,
	frontier_replied: u64, // cohort token this peer answered
	local_read: bool, transaction_begin, preview, session_info: bool, query_value: sql.Mutation,
}
Server :: struct {
	transfer: ^Snapshot_Transfer, transfer_error: string, transfer_buffer: []u8,
	maintenance_checked, maintenance_dirty: time.Tick,
	maintenance_error: string,
	config: Config, host: ^durable.Host, tls: mtls.Context, listener: posix.FD,
	connections: [MAX_CONNECTIONS]Connection,
	incoming: [MAX_INCOMING]durable.Packet, incoming_count: int,
	work_ready: bool,
	write_cursor: int,
	read_cohort: durable.Read_Ticket,
	frontier_token: u64, frontier_high: sql.Slot, frontier_replies: int, frontier_ready: bool,
	frontier_voters: [durable.MAX_MEMBERS]bool, // cohort membership survives peer reconnects
	frontier_sent: time.Tick,
	allowed: [32]string, allowed_count: int,
	fingerprint: string, last_tick, last_dial, last_repair, last_snapshot_receipt: time.Tick, fatal: bool,
}
