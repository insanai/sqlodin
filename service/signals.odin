package service

import "core:c/libc"
import "core:sync"

@(private)
stop_requested: libc.sig_atomic_t

@(private)
request_stop :: proc "c" (_: libc.int) {
	sync.atomic_store(&stop_requested, 1)
}

install_signals :: proc() -> bool {
	sync.atomic_store(&stop_requested, 0)
	first := libc.signal(libc.SIGINT, request_stop)
	second := libc.signal(libc.SIGTERM, request_stop)
	return rawptr(first) != libc.SIG_ERR && rawptr(second) != libc.SIG_ERR
}

stopping :: proc() -> bool { return sync.atomic_load(&stop_requested) != 0 }
