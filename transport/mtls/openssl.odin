// Small OpenSSL 3 ABI surface. TLS is optional and outside the embedded SQL engine.
package mtls

import "core:c"

// Every reachable SSL symbol requires both archives, even a small embedded
// caller that only closes a stream and never calls a crypto wrapper itself.
foreign import ssl_lib {"../../build/native/libssl.a", "../../build/native/libcrypto.a"}

@(private="file")
foreign ssl_lib {
	OPENSSL_init_ssl :: proc "c" (options: u64, settings: rawptr) -> c.int ---
	TLS_method :: proc "c" () -> rawptr ---
	SSL_CTX_new :: proc "c" (method: rawptr) -> rawptr ---
	SSL_CTX_free :: proc "c" (ctx: rawptr) ---
	SSL_CTX_get0_certificate :: proc "c" (ctx: rawptr) -> rawptr ---
	EVP_sha256 :: proc "c" () -> rawptr ---
	X509_get0_notBefore :: proc "c" (cert: rawptr) -> rawptr ---
	X509_get0_notAfter :: proc "c" (cert: rawptr) -> rawptr ---
	X509_cmp_current_time :: proc "c" (date: rawptr) -> c.int ---
	X509_digest :: proc "c" (cert, algorithm: rawptr, digest: [^]u8, length: ^c.uint) -> c.int ---
	SSL_CTX_ctrl :: proc "c" (ctx: rawptr, cmd: c.int, arg: c.long, ptr: rawptr) -> c.long ---
	SSL_CTX_use_certificate_chain_file :: proc "c" (ctx: rawptr, file: cstring) -> c.int ---
	SSL_CTX_use_PrivateKey_file :: proc "c" (ctx: rawptr, file: cstring, kind: c.int) -> c.int ---
	SSL_CTX_check_private_key :: proc "c" (ctx: rawptr) -> c.int ---
	SSL_CTX_load_verify_locations :: proc "c" (ctx: rawptr, file, path: cstring) -> c.int ---
	SSL_CTX_set_verify :: proc "c" (ctx: rawptr, flags: c.int, callback: rawptr) ---
	SSL_CTX_set_num_tickets :: proc "c" (ctx: rawptr, count: c.size_t) -> c.int ---
	SSL_CTX_set_max_early_data :: proc "c" (ctx: rawptr, count: u32) -> c.int ---
	SSL_new :: proc "c" (ctx: rawptr) -> rawptr ---
	SSL_free :: proc "c" (ssl: rawptr) ---
	SSL_set_fd :: proc "c" (ssl: rawptr, fd: c.int) -> c.int ---
	SSL_set1_host :: proc "c" (ssl: rawptr, name: cstring) -> c.int ---
	SSL_add1_host :: proc "c" (ssl: rawptr, name: cstring) -> c.int ---
	SSL_get0_peername :: proc "c" (ssl: rawptr) -> cstring ---
	SSL_set_hostflags :: proc "c" (ssl: rawptr, flags: c.uint) ---
	SSL_set_connect_state :: proc "c" (ssl: rawptr) ---
	SSL_set_accept_state :: proc "c" (ssl: rawptr) ---
	SSL_do_handshake :: proc "c" (ssl: rawptr) -> c.int ---
	SSL_get_verify_result :: proc "c" (ssl: rawptr) -> c.long ---
	SSL_get1_peer_certificate :: proc "c" (ssl: rawptr) -> rawptr ---
	SSL_get_error :: proc "c" (ssl: rawptr, result: c.int) -> c.int ---
	SSL_read_ex :: proc "c" (ssl: rawptr, buf: rawptr, size: c.size_t, n: ^c.size_t) -> c.int ---
	SSL_write_ex :: proc "c" (ssl: rawptr, buf: rawptr, size: c.size_t, n: ^c.size_t) -> c.int ---
}

@(private="file")
foreign ssl_lib {
	ERR_clear_error :: proc "c" () ---
	X509_free :: proc "c" (cert: rawptr) ---
}

// Named wrapper procedures keep the foreign ABI private to this package.
@(private)
new_context :: proc(cert, key, ca: cstring) -> rawptr {
	// Trust/key paths are explicit. Do not inherit system openssl.cnf providers
	// or depend on loadable modules outside this statically linked executable.
	if OPENSSL_init_ssl(0x80, nil) != 1 do return nil // OPENSSL_INIT_NO_LOAD_CONFIG.
	ERR_clear_error()
	ctx := SSL_CTX_new(TLS_method())
	if ctx == nil do return nil
	ok := SSL_CTX_ctrl(ctx, 123, 0x0304, nil) == 1 && // Minimum TLS 1.3.
	      SSL_CTX_ctrl(ctx, 124, 0x0304, nil) == 1 && // Maximum TLS 1.3.
	      SSL_CTX_use_certificate_chain_file(ctx, cert) == 1 &&
	      SSL_CTX_use_PrivateKey_file(ctx, key, 1) == 1 &&
	      SSL_CTX_check_private_key(ctx) == 1 &&
	      SSL_CTX_load_verify_locations(ctx, ca, nil) == 1 &&
	      SSL_CTX_set_num_tickets(ctx, 0) == 1 &&
	      SSL_CTX_set_max_early_data(ctx, 0) == 1
	if !ok || !context_certificate_current(ctx) { SSL_CTX_free(ctx); return nil }
	// Require an authenticated certificate in both directions; no permissive callback.
	SSL_CTX_set_verify(ctx, 1 | 2, nil)
	return ctx
}

@(private)
new_stream :: proc(ctx: rawptr, fd: c.int, peer: cstring, role: Role) -> rawptr {
	ERR_clear_error()
	s := SSL_new(ctx)
	if s == nil do return nil
	// Exact DNS SAN match only: no wildcard and no common-name fallback.
	SSL_set_hostflags(s, 0x2 | 0x20)
	if SSL_set_fd(s, fd) != 1 || SSL_set1_host(s, peer) != 1 {
		SSL_free(s)
		return nil
	}
	if role == .Client do SSL_set_connect_state(s)
	else do SSL_set_accept_state(s)
	return s
}

@(private)
result_status :: proc(s: rawptr, result: c.int) -> Status {
	if result == 1 do return .Ready
	switch SSL_get_error(s, result) {
	case 2: return .Want_Read
	case 3: return .Want_Write
	case 6: return .Closed
	case: return .Failed
	}
}

@(private)
do_handshake :: proc(s: rawptr) -> Status {
	ERR_clear_error()
	status := result_status(s, SSL_do_handshake(s))
	if status != .Ready do return status
	cert := SSL_get1_peer_certificate(s)
	if cert == nil do return .Failed
	defer X509_free(cert)
	if SSL_get_verify_result(s) != 0 do return .Failed
	return .Ready
}

@(private)
do_io :: proc(s: rawptr, bytes: []u8, writing: bool) -> (int, Status) {
	ERR_clear_error()
	n: c.size_t
	rc: c.int
	if writing do rc = SSL_write_ex(s, raw_data(bytes), c.size_t(len(bytes)), &n)
	else do rc = SSL_read_ex(s, raw_data(bytes), c.size_t(len(bytes)), &n)
	return int(n), result_status(s, rc)
}

@(private)
free_context :: proc(ctx: rawptr) { SSL_CTX_free(ctx) }
@(private)
free_stream :: proc(s: rawptr) { SSL_free(s) }

@(private)
add_peer :: proc(s: rawptr, name: cstring) -> bool { return SSL_add1_host(s, name) == 1 }

// Borrowed until stream_close. Only available after successful authentication.
peer_name :: proc(s: ^Stream) -> string {
	if s == nil || !s.authenticated || s.failed do return ""
	return string(SSL_get0_peername(s.handle))
}

// Hash the certificate already loaded into this context, not a mutable file path.
context_certificate_hash :: proc(ctx: ^Context) -> (digest: [32]u8, ok: bool) {
	if ctx == nil || ctx.handle == nil do return
	cert := SSL_CTX_get0_certificate(ctx.handle)
	length: c.uint
	ok = cert != nil && X509_digest(cert, EVP_sha256(), raw_data(digest[:]), &length) == 1 && length == 32
	return
}

// Fail startup with an unusable local credential instead of listening forever
// while every correctly validating peer rejects its validity interval.
@(private)
context_certificate_current :: proc(ctx: rawptr) -> bool {
	cert := SSL_CTX_get0_certificate(ctx)
	if cert == nil do return false
	before, after := X509_get0_notBefore(cert), X509_get0_notAfter(cert)
	return before != nil && after != nil &&
		X509_cmp_current_time(before) < 0 && X509_cmp_current_time(after) > 0
}
