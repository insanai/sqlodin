"""Bounded transparent TCP throttling for the snapshot catch-up test only."""
import socket
import socketserver
import threading
import time


class SnapshotProxy:
    def __init__(self, target, kib_per_second, drop_after=0):
        self.target = (target.rsplit(':', 1)[0], int(target.rsplit(':', 1)[1]))
        self.rate = kib_per_second * 1024
        self.drop_after = drop_after
        self.downstream_bytes = 0
        self.drops = 0
        self.lock = threading.Lock()
        self.active = set()
        self.slots = threading.BoundedSemaphore(4)
        owner = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                if not owner.slots.acquire(blocking=False):
                    return
                client = self.request
                target = None
                try:
                    target = socket.create_connection(owner.target, timeout=5)
                    client.settimeout(10)
                    target.settimeout(10)
                    with owner.lock:
                        owner.active.update((client, target))
                    reverse = threading.Thread(target=owner._relay, args=(target, client, False), daemon=True)
                    reverse.start()
                    owner._relay(client, target, True)
                    reverse.join(timeout=1)
                except OSError:
                    pass
                finally:
                    owner._close(client)
                    if target is not None:
                        owner._close(target)
                    with owner.lock:
                        owner.active.discard(client)
                        owner.active.discard(target)
                    owner.slots.release()

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(('127.0.0.1', 0), Handler)
        self.address = f'127.0.0.1:{self.server.server_address[1]}'
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': .1}, daemon=True)
        self.thread.start()

    @staticmethod
    def _close(sock):
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()

    def _relay(self, source, destination, throttle):
        try:
            while data := source.recv(8192):
                if throttle:
                    time.sleep(len(data) / self.rate)
                    with self.lock:
                        self.downstream_bytes += len(data)
                        if self.drop_after and self.downstream_bytes >= self.drop_after:
                            self.drop_after = 0
                            self.drops += 1
                            return
                destination.sendall(data)
        except OSError:
            pass
        finally:
            self._close(source)
            self._close(destination)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        with self.lock:
            active = list(self.active)
        for sock in active:
            self._close(sock)
        self.thread.join(timeout=1)
