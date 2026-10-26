"""Tests for the WebSocket helpers and the realtime transcription relay.
Meta is replaced by a fake upstream socket."""

import io
import json
import queue
import tempfile
import threading
import unittest
from pathlib import Path

from test_server import FAKE_KEY

import server
import ws


class FrameTests(unittest.TestCase):
    def roundtrip(self, payload, mask, opcode=ws.OP_BINARY):
        frame = ws.encode_frame(opcode, payload, mask)
        sock = ws.WebSocket(io.BytesIO(frame), None, mask_outgoing=False)
        return sock.recv()

    def test_roundtrip_all_length_encodings(self):
        for size in (0, 5, 125, 126, 65535, 65536, 100_000):
            payload = bytes(range(256)) * (size // 256) + bytes(size % 256)
            for mask in (False, True):
                self.assertEqual(self.roundtrip(payload, mask), (ws.OP_BINARY, payload), (size, mask))

    def test_text_frame(self):
        self.assertEqual(self.roundtrip("Merhaba".encode(), True, ws.OP_TEXT), (ws.OP_TEXT, b"Merhaba"))

    def test_fragmented_message_is_joined_and_pings_answered(self):
        sent = io.BytesIO()

        class Sock:
            def sendall(self, data):
                sent.write(data)

        first = bytearray(ws.encode_frame(ws.OP_TEXT, b"Mer", False))
        first[0] &= 0x7F  # clear FIN
        ping = ws.encode_frame(ws.OP_PING, b"hi", False)
        last = bytearray(ws.encode_frame(ws.OP_CONTINUATION, b"haba", False))
        sock = ws.WebSocket(io.BytesIO(bytes(first) + ping + bytes(last)), Sock(), mask_outgoing=False)
        self.assertEqual(sock.recv(), (ws.OP_TEXT, b"Merhaba"))
        self.assertEqual(sent.getvalue(), ws.encode_frame(ws.OP_PONG, b"hi", False))

    def test_close_frame_raises_with_code(self):
        frame = ws.encode_frame(ws.OP_CLOSE, (1008).to_bytes(2, "big") + b"policy", False)

        class Sock:
            def sendall(self, data):
                pass

        sock = ws.WebSocket(io.BytesIO(frame), Sock(), mask_outgoing=False)
        with self.assertRaises(ws.WebSocketClosed) as caught:
            sock.recv()
        self.assertEqual((caught.exception.code, caught.exception.reason), (1008, "policy"))

    def test_accept_key_matches_rfc_example(self):
        self.assertEqual(ws.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")


class FakeUpstream:
    """Stands in for Meta's realtime socket."""

    def __init__(self, ack=None, events=None):
        self.inbox = queue.Queue()
        self.sent_text = []
        self.sent_binary = []
        self.events = events or []
        self.inbox.put(json.dumps(ack or {"sessionId": "meta-1"}).encode())
        self.closed = False

        class Sock:
            def settimeout(self, value):
                pass

        self.sock = Sock()

    def send_text(self, text):
        self.sent_text.append(json.loads(text))
        if json.loads(text).get("type") == "endStream":
            for event in self.events:
                self.inbox.put(json.dumps(event).encode())
            self.inbox.put(None)

    def send_binary(self, data):
        self.sent_binary.append(data)

    def recv(self):
        item = self.inbox.get(timeout=5)
        if item is None:
            raise ws.WebSocketClosed(1000, "")
        return ws.OP_TEXT, item

    def close(self, code=1000, reason=""):
        self.closed = True

    def shutdown(self):
        self.inbox.put(None)


class RelayTests(unittest.TestCase):
    def start(self, upstream, key=FAKE_KEY):
        self.tmp = tempfile.TemporaryDirectory()
        env = Path(self.tmp.name) / ".env.local"
        env.write_text(f"MODEL_API_KEY={key}\n")
        self.urls = []

        def connect(url):
            self.urls.append(url)
            return upstream

        self.httpd = server.NovaServer(0, env, ws_connect=connect)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def client(self, origin=None):
        origin = origin or f"http://127.0.0.1:{self.port}"
        return ws.connect(f"ws://127.0.0.1:{self.port}/api/realtime", headers={"Origin": origin})

    def recv_json(self, client):
        return json.loads(client.recv()[1])

    def test_relays_audio_and_events(self):
        events = [
            {"type": "speechStart", "turnId": 0, "audioProcessedMs": 60},
            {"type": "transcript", "transcript": "Merhaba", "final": False, "audioProcessedMs": 500},
            {"type": "speechComplete", "turnId": 0, "transcript": "Merhaba Nova.", "audioProcessedMs": 900},
        ]
        upstream = FakeUpstream(events=events)
        self.start(upstream)
        client = self.client()
        client.send_text(json.dumps({"languages": ["Turkish"]}))
        ready = self.recv_json(client)
        self.assertEqual(ready["type"], "ready")
        self.assertNotIn(FAKE_KEY, json.dumps(ready))
        client.send_binary(b"\x01\x00" * 480)
        client.send_text(json.dumps({"type": "endStream"}))
        received = []
        try:
            while True:
                received.append(self.recv_json(client))
        except ws.WebSocketClosed:
            pass
        self.assertEqual([e["type"] for e in received], ["speechStart", "transcript", "speechComplete", "closed"])
        self.assertEqual(received[2]["transcript"], "Merhaba Nova.")

        handshake = upstream.sent_text[0]
        self.assertEqual(handshake["authorization"], {"accessToken": f"Bearer {FAKE_KEY}"})
        self.assertEqual(handshake["model"], "muse-voice-transcribe-1.0")
        self.assertEqual(handshake["audioEncoding"], "PCM_24KHZ")
        self.assertEqual(handshake["mode"], "ENDPOINTING")
        self.assertEqual(handshake["languageBias"], ["Turkish"])
        self.assertEqual(upstream.sent_binary, [b"\x01\x00" * 480])
        self.assertEqual(upstream.sent_text[-1], {"type": "endStream"})
        self.assertTrue(self.urls[0].startswith("wss://api.meta.ai/v1/asr/realtime?sessionId=nova-"))

    def test_upstream_errors_are_redacted(self):
        upstream = FakeUpstream(events=[{"type": "error", "message": f"bad key {FAKE_KEY}"}])
        self.start(upstream)
        client = self.client()
        client.send_text("{}")
        self.assertEqual(self.recv_json(client)["type"], "ready")
        client.send_text(json.dumps({"type": "endStream"}))
        error = self.recv_json(client)
        self.assertEqual(error["type"], "error")
        self.assertNotIn(FAKE_KEY, error["message"])

    def test_rejected_handshake_is_reported(self):
        self.start(FakeUpstream(ack={"type": "error", "message": "invalid model"}))
        client = self.client()
        client.send_text("{}")
        event = self.recv_json(client)
        self.assertEqual((event["type"], event["kind"]), ("error", "upstream"))
        self.assertIn("invalid model", event["message"])

    def test_missing_key_is_a_setup_error(self):
        self.start(FakeUpstream(), key="")
        client = self.client()
        client.send_text("{}")
        event = self.recv_json(client)
        self.assertEqual((event["type"], event["kind"]), ("error", "setup"))
        self.assertEqual(self.urls, [], "Meta must not be contacted without a key")

    def test_bad_language_hint_is_rejected(self):
        self.start(FakeUpstream())
        client = self.client()
        client.send_text(json.dumps({"languages": ["Klingon"]}))
        self.assertEqual(self.recv_json(client)["kind"], "request")

    def test_foreign_origin_cannot_open_the_socket(self):
        self.start(FakeUpstream())
        with self.assertRaises(ws.HandshakeError):
            self.client(origin="https://evil.example")
        self.assertEqual(self.urls, [])


if __name__ == "__main__":
    unittest.main()
