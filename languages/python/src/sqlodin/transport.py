"""TLS 1.3 framed transport with a single absolute deadline per operation."""
import json
import socket
import ssl
import struct
import time
from dataclasses import dataclass
from pathlib import Path

from .errors import ConnectionError


@dataclass(frozen=True)
class Endpoint:
    address: str
    server_name: str

    def socket_address(self) -> tuple[str, int]:
        host, port = self.address.rsplit(':', 1)
        return host, int(port)


@dataclass(frozen=True)
class TLS:
    ca: str | Path
    cert: str | Path
    key: str | Path

    def context(self) -> ssl.SSLContext:
        ctx = ssl.create_default_context(cafile=str(self.ca))
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.hostname_checks_common_name = False
        ctx.load_cert_chain(str(self.cert), str(self.key))
        return ctx


def remaining(deadline: float) -> float:
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError("SQLodin operation deadline expired")
    return seconds


class Transport:
    def __init__(self, tls: TLS):
        self.context = tls.context()
        self.socket = None
        self.endpoint = None

    def close(self):
        if self.socket is not None:
            self.socket.close()
        self.socket = self.endpoint = None

    def exchange(self, endpoint: Endpoint, request: dict, deadline: float) -> dict:
        body = json.dumps(request, separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(body) > 65536:
            raise ValueError("Encoded request exceeds 64 KiB")
        try:
            if self.endpoint != endpoint or self.socket is None:
                self.close()
                raw = socket.create_connection(endpoint.socket_address(), timeout=remaining(deadline))
                try:
                    raw.settimeout(remaining(deadline))
                    raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    self.socket = self.context.wrap_socket(raw, server_hostname=endpoint.server_name)
                    sans = self.socket.getpeercert().get('subjectAltName', ())
                    if ('DNS', endpoint.server_name) not in sans:
                        raise ssl.CertificateError("Server certificate requires an exact DNS SAN")
                    self.endpoint = endpoint
                except BaseException:
                    raw.close()
                    self.close()
                    raise
            self.socket.settimeout(remaining(deadline))
            self.socket.sendall(struct.pack('<I', len(body)) + body)
            size = struct.unpack('<I', self._receive(4, deadline))[0]
            if not 0 < size <= 1024 * 1024:
                raise ConnectionError("Invalid response frame length")
            result = json.loads(self._receive(size, deadline))
            if not isinstance(result, dict):
                raise ConnectionError("Invalid response object")
            return result
        except (OSError, ValueError, ConnectionError) as exc:
            self.close()
            raise ConnectionError(str(exc)) from exc

    def _receive(self, size, deadline):
        data = bytearray()
        while len(data) < size:
            self.socket.settimeout(remaining(deadline))
            chunk = self.socket.recv(size - len(data))
            if not chunk:
                raise ConnectionError("Server closed the connection")
            data.extend(chunk)
        return data
