"""Minimal WebSocket support (RFC 6455) using only the standard library.

Just enough for the realtime transcription relay: one connection to the
browser (server side) and one to Meta's realtime endpoint (client side).
"""

from __future__ import annotations

import base64
import hashlib
import os
import socket
import ssl
import threading
from urllib.parse import urlparse

OP_CONTINUATION = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE_BYTES = 4 * 1024 * 1024


class WebSocketClosed(Exception):
    """The peer closed the connection; `code` is its close code, if any."""

    def __init__(self, code: int | None = None, reason: str = ""):
        super().__init__(f"WebSocket closed ({code}): {reason}")
        self.code = code
        self.reason = reason


class HandshakeError(Exception):
    """The server refused the WebSocket upgrade."""


def accept_key(client_key: str) -> str:
    digest = hashlib.sha1((client_key + ACCEPT_GUID).encode()).digest()
    return base64.b64encode(digest).decode()


def apply_mask(data: bytes, key: bytes) -> bytes:
    if not data:
        return data
    repeated = (key * (len(data) // 4 + 1))[: len(data)]
    return (int.from_bytes(data, "big") ^ int.from_bytes(repeated, "big")).to_bytes(len(data), "big")


def encode_frame(opcode: int, payload: bytes, mask: bool) -> bytes:
    header = bytearray([0x80 | opcode])
    length = len(payload)
    mask_bit = 0x80 if mask else 0
    if length < 126:
        header.append(mask_bit | length)
    elif length < 1 << 16:
        header.append(mask_bit | 126)
        header += length.to_bytes(2, "big")
    else:
        header.append(mask_bit | 127)
        header += length.to_bytes(8, "big")
    if mask:
        key = os.urandom(4)
        header += key
        payload = apply_mask(payload, key)
    return bytes(header) + payload


class WebSocket:
    """One open WebSocket. Clients mask outgoing frames; servers don't."""

    def __init__(self, reader, sock: socket.socket, mask_outgoing: bool):
        self.reader = reader
        self.sock = sock
        self.mask_outgoing = mask_outgoing
        self.send_lock = threading.Lock()
        self.closed = False

    def _read_exact(self, count: int) -> bytes:
        data = self.reader.read(count)
        if data is None or len(data) < count:
            raise WebSocketClosed(None, "connection lost")
        return data

    def _read_frame(self) -> tuple[bool, int, bytes]:
        first, second = self._read_exact(2)
        fin = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = int.from_bytes(self._read_exact(2), "big")
        elif length == 127:
            length = int.from_bytes(self._read_exact(8), "big")
        if length > MAX_MESSAGE_BYTES:
            raise WebSocketClosed(1009, "message too big")
        key = self._read_exact(4) if masked else None
        payload = self._read_exact(length) if length else b""
        if key:
            payload = apply_mask(payload, key)
        return fin, opcode, payload

    def recv(self) -> tuple[int, bytes]:
        """Next complete text or binary message as (opcode, payload).

        Answers pings, and raises WebSocketClosed when a close frame arrives.
        """
        message_opcode = None
        parts: list[bytes] = []
        while True:
            fin, opcode, payload = self._read_frame()
            if opcode == OP_PING:
                self._send(OP_PONG, payload)
                continue
            if opcode == OP_PONG:
                continue
            if opcode == OP_CLOSE:
                code = int.from_bytes(payload[:2], "big") if len(payload) >= 2 else None
                reason = payload[2:].decode("utf-8", "replace")
                self.close(code or 1000)
                raise WebSocketClosed(code, reason)
            if opcode == OP_CONTINUATION:
                if message_opcode is None:
                    raise WebSocketClosed(1002, "unexpected continuation frame")
            else:
                message_opcode = opcode
                parts = []
            parts.append(payload)
            if sum(len(part) for part in parts) > MAX_MESSAGE_BYTES:
                raise WebSocketClosed(1009, "message too big")
            if fin:
                return message_opcode, b"".join(parts)

    def _send(self, opcode: int, payload: bytes) -> None:
        frame = encode_frame(opcode, payload, self.mask_outgoing)
        with self.send_lock:
            if self.closed and opcode != OP_CLOSE:
                raise WebSocketClosed(None, "already closed")
            self.sock.sendall(frame)

    def send_text(self, text: str) -> None:
        self._send(OP_TEXT, text.encode())

    def send_binary(self, data: bytes) -> None:
        self._send(OP_BINARY, data)

    def close(self, code: int = 1000, reason: str = "") -> None:
        with self.send_lock:
            if self.closed:
                return
            self.closed = True
            try:
                frame = encode_frame(OP_CLOSE, code.to_bytes(2, "big") + reason.encode()[:120], self.mask_outgoing)
                self.sock.sendall(frame)
            except OSError:
                pass

    def shutdown(self) -> None:
        """Drop the TCP connection, unblocking any thread stuck in recv()."""
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


def connect(url: str, headers: dict[str, str] | None = None, timeout: float = 10.0) -> WebSocket:
    """Open a client WebSocket to a ws:// or wss:// URL."""
    parsed = urlparse(url)
    secure = parsed.scheme == "wss"
    port = parsed.port or (443 if secure else 80)
    raw = socket.create_connection((parsed.hostname, port), timeout=timeout)
    sock = ssl.create_default_context().wrap_socket(raw, server_hostname=parsed.hostname) if secure else raw
    key = base64.b64encode(os.urandom(16)).decode()
    path = (parsed.path or "/") + (f"?{parsed.query}" if parsed.query else "")
    host = parsed.hostname if parsed.port is None else f"{parsed.hostname}:{parsed.port}"
    lines = [
        f"GET {path} HTTP/1.1",
        f"Host: {host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}",
        "Sec-WebSocket-Version: 13",
        *(f"{name}: {value}" for name, value in (headers or {}).items()),
    ]
    sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
    reader = sock.makefile("rb")
    status = reader.readline().decode("latin-1").strip()
    response_headers = {}
    while True:
        line = reader.readline().decode("latin-1").strip()
        if not line:
            break
        name, _, value = line.partition(":")
        response_headers[name.strip().lower()] = value.strip()
    if " 101 " not in f"{status} ":
        sock.close()
        raise HandshakeError(f"Upgrade refused: {status}")
    if response_headers.get("sec-websocket-accept") != accept_key(key):
        sock.close()
        raise HandshakeError("Upgrade response had the wrong accept key")
    sock.settimeout(None)
    return WebSocket(reader, sock, mask_outgoing=True)
