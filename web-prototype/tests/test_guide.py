"""Tests for the Göster bana guide backend. Meta is never called: a fake opener answers each request by what it
asks for, because SAM calls run in parallel and arrive in any order."""

import base64
import io
import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import guide  # noqa: E402
import server  # noqa: E402

FAKE_KEY = "test-key-123"


def tiny_jpeg(width=1000, height=500, with_exif=True) -> bytes:
    """Markers only (no real pixels): SOI, optional APP1/EXIF, APP0, SOF0 with the size, SOS, EOI."""
    def segment(marker, payload):
        return bytes([0xFF, marker]) + (len(payload) + 2).to_bytes(2, "big") + payload
    parts = [b"\xff\xd8", segment(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")]
    if with_exif:
        parts.append(segment(0xE1, b"Exif\x00\x00GPS-SECRET"))
    parts.append(segment(0xC0, b"\x08" + height.to_bytes(2, "big") + width.to_bytes(2, "big") + b"\x01\x01\x11\x00"))
    parts.append(segment(0xDA, b"\x01\x01\x00\x00\x3f\x00") + b"\x12\x34\xff\xd9")
    return b"".join(parts)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


PLAN = {
    "device_type": "washing machine", "brand_or_model_seen": "Maytag", "safe_to_guide": True, "safety_note": "",
    "uncertainty": "",
    "steps": [
        {"instruction": "Sıcaklık düğmesini sıcağa çevir.", "target_phrase": "temperature knob", "x": 200, "y": 400,
         "set_to_label": "hot", "set_to_meaning": "sıcak", "success_condition": "the pointer is at 'hot'",
         "visible_result": True},
        {"instruction": "Başlat düğmesine bas.", "target_phrase": "start button", "x": 800, "y": 400,
         "set_to_label": "", "set_to_meaning": "", "success_condition": "no visible change",
         "visible_result": False},
    ],
}
GROUND = [{"object_name": "temperature knob", "x": 210, "y": 410}, {"object_name": "hot", "x": 260, "y": 300},
          {"object_name": "start button", "x": 800, "y": 400}]


class RoutingOpener:
    """Answers Spark plan, Spark ground, and SAM calls; records every request body."""

    def __init__(self, plan=PLAN, served="muse-spark-1.3", sam_point=None, sam_text=None, check=None,
                 reply=None, transcript="Extra rinse ne demek?"):
        self.plan, self.served = plan, served
        self.reply = reply or {"kind": "answer", "answer": "Fazladan bir durulama yapar."}
        self.transcript = transcript
        self.audio = []
        self.check = check or {"status": "not_done", "observed": "pointer at 'warm'", "correction": "Biraz daha sağa çevirin."}
        self.sam_point = sam_point or "1<|box;x1=180;y1=180;x2=240;y2=230;c=0.91|>"
        self.sam_text = sam_text or "1<|box;x1=780;y1=180;x2=820;y2=220;c=0.8|>"
        self.bodies = []
        self.lock = threading.Lock()

    def __call__(self, request, timeout=None):
        if request.full_url.endswith("/asr/transcribe"):
            with self.lock:
                self.audio.append(request.data)
            return FakeResponse(json.dumps({"transcript": self.transcript}).encode())
        body = json.loads(request.data)
        with self.lock:
            self.bodies.append(body)
        if body["model"] == guide.SAM_MODEL:
            prompt = body["input"][0]["content"][0]["text"]
            text = self.sam_point if prompt.startswith("<0f>") else self.sam_text
            reply = {"model": guide.SAM_MODEL, "output_text": text}
        elif body.get("response_format", {}).get("json_schema", {}).get("name") == "guide_reply":
            reply = {"model": self.served, "choices": [{"message": {"content": json.dumps(self.reply)}}]}
        elif body.get("response_format", {}).get("json_schema", {}).get("name") == "step_check":
            reply = {"model": self.served, "choices": [{"message": {"content": json.dumps(self.check)}}]}
        elif "response_format" in body:
            reply = {"model": self.served, "choices": [{"message": {"content": json.dumps(self.plan)}}]}
        else:
            reply = {"model": self.served, "choices": [{"message": {"content": json.dumps(GROUND)}}]}
        return FakeResponse(json.dumps(reply).encode())


class FrameTests(unittest.TestCase):
    def test_jpeg_size_reads_start_of_frame(self):
        self.assertEqual(guide.jpeg_size(tiny_jpeg(1600, 1200)), (1600, 1200))

    def test_jpeg_size_rejects_other_data(self):
        with self.assertRaises(server.BadRequest):
            guide.jpeg_size(b"\x89PNG....")

    def test_strip_metadata_drops_exif_and_keeps_the_image(self):
        stripped = guide.strip_metadata(tiny_jpeg())
        self.assertNotIn(b"GPS-SECRET", stripped)
        self.assertIn(b"JFIF", stripped)
        self.assertEqual(stripped, tiny_jpeg(with_exif=False))

    def test_decode_frame_accepts_a_data_url(self):
        data = tiny_jpeg()
        self.assertEqual(guide.decode_frame("data:image/jpeg;base64," + base64.b64encode(data).decode()), data)
        with self.assertRaises(server.BadRequest):
            guide.decode_frame("not base64!")


class LocateTests(unittest.TestCase):
    def test_weak_reasons(self):
        good = {"x1": 100, "y1": 100, "x2": 140, "y2": 140, "c": 0.9}
        self.assertEqual(guide.weak_reason(good, 120, 120, 1000, 500), "")
        self.assertEqual(guide.weak_reason({**good, "c": 0.2}, 120, 120, 1000, 500), "confidence 0.20")
        self.assertEqual(guide.weak_reason({**good, "x2": 900, "y2": 400}, 120, 120, 1000, 500), "box too large")
        self.assertEqual(guide.weak_reason({**good, "x2": 105}, 102, 120, 1000, 500), "box too small")
        self.assertEqual(guide.weak_reason(good, 400, 400, 1000, 500), "point outside box")

    def test_a_weak_point_box_falls_back_to_the_nearest_generic_match(self):
        opener = RoutingOpener(sam_point="1<|box;x1=0;y1=0;x2=1000;y2=500;c=0.3|>",
                               sam_text="1<|box;x1=190;y1=190;x2=240;y2=240;c=0.7|>2<|box;x1=700;y1=190;x2=750;y2=240;c=0.9|>")
        served = []
        box, method = guide.locate("temperature knob", 200, 200, 1000, 500, "data:", FAKE_KEY, opener, served)
        self.assertEqual(method, "fallback")
        self.assertEqual(box["x1"], 190)
        prompts = [body["input"][0]["content"][0]["text"] for body in opener.bodies]
        self.assertEqual(prompts[1:], ["knob", "temperature knob"])


class PlanTests(unittest.TestCase):
    def test_plan_returns_normalized_points_boxes_and_dial_targets(self):
        opener = RoutingOpener()
        result = guide.plan(tiny_jpeg(1000, 500), "Beyazları yıkamak istiyorum", "Turkish", FAKE_KEY, opener)
        self.assertTrue(result["safe"])
        self.assertEqual(result["frame"], {"width": 1000, "height": 500})
        first, second = result["steps"]
        self.assertEqual(first["point"], {"x": 0.21, "y": 0.41})
        self.assertEqual(first["boxMethod"], "point")
        self.assertEqual(first["box"]["x1"], 0.18)
        self.assertEqual(first["setTo"], {"label": "hot", "meaning": "sıcak", "point": {"x": 0.26, "y": 0.3}})
        self.assertEqual(first["success"], "the pointer is at 'hot'")
        self.assertIsNone(second["setTo"])
        self.assertTrue(first["verifiable"])
        self.assertFalse(second["verifiable"])
        self.assertEqual(result["served"], ["muse-spark-1.3", "sam-3.1"])

    def test_only_pinned_standard_models_are_requested(self):
        opener = RoutingOpener()
        guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, opener)
        self.assertEqual({body["model"] for body in opener.bodies}, {"muse-spark-1.3", "sam-3.1"})

    def test_a_contributor_model_discards_the_result(self):
        with self.assertRaisesRegex(server.UpstreamError, "Contributor"):
            guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, RoutingOpener(served="muse-spark-1.3-contributor"))

    def test_an_unsafe_device_gets_no_steps_and_no_further_calls(self):
        opener = RoutingOpener(plan={**PLAN, "safe_to_guide": False, "safety_note": "Gaz vanası."})
        result = guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, opener)
        self.assertFalse(result["safe"])
        self.assertEqual(result["steps"], [])
        self.assertEqual(len(opener.bodies), 1)


class VerifyTests(unittest.TestCase):
    def test_not_done_returns_the_correction_in_the_users_language(self):
        opener = RoutingOpener()
        result = guide.verify(tiny_jpeg(520, 520), "Sıcağa çevir.", "pointer at 'hot'", "Turkish", FAKE_KEY, opener)
        self.assertEqual(result["status"], "not_done")
        self.assertEqual(result["correction"], "Biraz daha sağa çevirin.")
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        self.assertIn("in Turkish", prompt)
        self.assertIn("pointer at 'hot'", prompt)

    def test_a_done_answer_drops_any_correction(self):
        opener = RoutingOpener(check={"status": "done", "observed": "hot", "correction": "x"})
        self.assertEqual(guide.verify(tiny_jpeg(520, 520), "i", "s", "Turkish", FAKE_KEY, opener)["correction"], "")

    def test_a_tiny_crop_is_unsure_without_calling_meta(self):
        opener = RoutingOpener()
        result = guide.verify(tiny_jpeg(100, 100), "i", "s", "Turkish", FAKE_KEY, opener)
        self.assertEqual((result["status"], result["reason"]), ("unsure", "too_small"))
        self.assertEqual(opener.bodies, [])

    def test_an_unknown_status_is_an_upstream_error(self):
        opener = RoutingOpener(check={"status": "maybe", "observed": "", "correction": ""})
        with self.assertRaises(server.UpstreamError):
            guide.verify(tiny_jpeg(520, 520), "i", "s", "Turkish", FAKE_KEY, opener)


def wav_bytes(samples=1600):
    return (b"RIFF" + (36 + samples * 2).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little")
            + b"\x01\x00\x01\x00" + (16000).to_bytes(4, "little") + (32000).to_bytes(4, "little") + b"\x02\x00\x10\x00"
            + b"data" + (samples * 2).to_bytes(4, "little") + b"\x00\x00" * samples)


CONTEXT = {"device": "Maytag · washing machine", "current": 2, "steps": [
    {"instruction": "Sıcaklığı sıcağa çevir.", "success": "pointer at hot", "result": "verified"},
    {"instruction": "Extra rinse'i aç.", "success": "pointer at on", "result": "pending"}]}


class AskTests(unittest.TestCase):
    def test_the_prompt_carries_the_steps_progress_and_question(self):
        opener = RoutingOpener()
        result = guide.ask(tiny_jpeg(), "Extra rinse ne demek?", "Turkish", guide.ask_context({"context": CONTEXT}),
                           FAKE_KEY, opener)
        self.assertEqual(result["kind"], "answer")
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        self.assertIn("on step 2 of 2", prompt)
        self.assertIn("so far: verified", prompt)
        self.assertIn('"Extra rinse ne demek?"', prompt)
        self.assertIn("in Turkish", prompt)

    def test_a_new_task_is_flagged(self):
        opener = RoutingOpener(reply={"kind": "new_task", "answer": "Kurutmayı planlıyorum."})
        result = guide.ask(tiny_jpeg(), "Şimdi kurutmak istiyorum", "Turkish", guide.ask_context({"context": CONTEXT}),
                           FAKE_KEY, opener)
        self.assertEqual(result["kind"], "new_task")

    def test_context_is_validated_and_trimmed(self):
        with self.assertRaises(server.BadRequest):
            guide.ask_context({})
        with self.assertRaises(server.BadRequest):
            guide.ask_context({"context": {"steps": [{"instruction": 5}]}})
        trimmed = guide.ask_context({"context": {"device": "x", "current": 99, "steps": [{"instruction": "a"}] * 9}})
        self.assertEqual(len(trimmed["steps"]), guide.MAX_STEPS)
        self.assertEqual(trimmed["current"], guide.MAX_STEPS)


class TranscribeTests(unittest.TestCase):
    def test_biases_to_the_users_language_and_english(self):
        opener = RoutingOpener()
        self.assertEqual(guide.transcribe(wav_bytes(), "Turkish", FAKE_KEY, opener), "Extra rinse ne demek?")
        self.assertIn(b'"languageBias": ["Turkish", "English"]', opener.audio[0])

    def test_no_speech_is_an_empty_transcript_not_an_error(self):
        self.assertEqual(guide.transcribe(wav_bytes(), "English", FAKE_KEY, RoutingOpener(transcript="")), "")

    def test_other_audio_is_rejected(self):
        with self.assertRaises(server.BadRequest):
            guide.transcribe(b"ID3....", "Turkish", FAKE_KEY, RoutingOpener())


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = Path(self.tmp.name) / ".env.local"
        self.env.write_text(f"MODEL_API_KEY={FAKE_KEY}\n")
        self.recordings = Path(self.tmp.name) / "recordings"
        self.opener = RoutingOpener()
        self.httpd = guide.GuideServer("127.0.0.1", 0, ["mac.example.ts.net"], self.env, self.recordings, self.opener)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def request(self, path, body=None, headers=None):
        merged = {"Host": f"mac.example.ts.net:{self.port}", guide.CLIENT_HEADER: guide.CLIENT_NAME,
                  "Content-Type": "application/json", **(headers or {})}
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, headers=merged,
                                         method="POST" if data else "GET")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def frame_body(self, **extra):
        return {"frame": base64.b64encode(tiny_jpeg()).decode(), "question": "Nasıl yıkarım?", "language": "Turkish",
                **extra}

    def test_status_reports_models_without_the_key(self):
        status, body = self.request("/api/guide/status")
        self.assertEqual(status, 200)
        self.assertTrue(body["keyLoaded"])
        self.assertNotIn(FAKE_KEY, json.dumps(body))

    def test_requests_without_the_client_header_or_with_another_host_are_refused(self):
        self.assertEqual(self.request("/api/guide/status", headers={guide.CLIENT_HEADER: "browser"})[0], 403)
        self.assertEqual(self.request("/api/guide/status", headers={"Host": "evil.example:80"})[0], 403)

    def test_only_guide_endpoints_exist(self):
        self.assertEqual(self.request("/api/workspace")[0], 404)
        self.assertEqual(self.request("/api/run", {"x": 1})[0], 404)

    def test_plan_end_to_end_strips_metadata_before_meta_sees_the_frame(self):
        status, body = self.request("/api/guide/plan", self.frame_body())
        self.assertEqual(status, 200)
        self.assertEqual(len(body["steps"]), 2)
        sent = self.opener.bodies[0]["messages"][0]["content"][1]["image_url"]["url"]
        self.assertNotIn(b"GPS-SECRET", base64.b64decode(sent.split(",", 1)[1]))
        self.assertFalse(self.recordings.exists())

    def test_recording_mode_saves_frame_request_and_response(self):
        status, body = self.request("/api/guide/plan", self.frame_body(record=True, camera={"intrinsics": [1, 0, 0]}))
        self.assertEqual(status, 200)
        folder = self.recordings / body["recording"]
        self.assertTrue((folder / "frame.jpg").is_file())
        saved = json.loads((folder / "request.json").read_text())
        self.assertNotIn("frame", saved)
        self.assertEqual(saved["camera"], {"intrinsics": [1, 0, 0]})

    def test_verify_end_to_end_with_recording(self):
        body = {"frame": base64.b64encode(tiny_jpeg(520, 520)).decode(), "instruction": "Sıcağa çevir.",
                "success": "pointer at 'hot'", "language": "Turkish", "record": True}
        status, answer = self.request("/api/guide/verify", body)
        self.assertEqual(status, 200)
        self.assertEqual(answer["status"], "not_done")
        self.assertTrue(answer["recording"].endswith("-verify"))
        self.assertEqual(self.request("/api/guide/verify", {**body, "success": ""})[0], 400)

    def test_transcribe_end_to_end_keeps_no_audio(self):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/guide/transcribe?language=Turkish", data=wav_bytes(), method="POST",
            headers={"Host": f"mac.example.ts.net:{self.port}", guide.CLIENT_HEADER: guide.CLIENT_NAME,
                     "Content-Type": "audio/wav"})
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(json.loads(response.read()), {"transcript": "Extra rinse ne demek?"})
        self.assertFalse(self.recordings.exists())

    def test_ask_end_to_end_with_recording(self):
        status, answer = self.request("/api/guide/ask", self.frame_body(context=CONTEXT, record=True))
        self.assertEqual(status, 200)
        self.assertEqual(answer["answer"], "Fazladan bir durulama yapar.")
        self.assertTrue(answer["recording"].endswith("-ask"))

    def test_bad_input_is_rejected(self):
        self.assertEqual(self.request("/api/guide/plan", self.frame_body(question=""))[0], 400)
        self.assertEqual(self.request("/api/guide/plan", self.frame_body(language="Klingon"))[0], 400)
        self.assertEqual(self.request("/api/guide/plan", self.frame_body(frame="AAAA"))[0], 400)


class StartTests(unittest.TestCase):
    def test_guide_is_off_without_a_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / ".env.local"
            env.write_text("MODEL_API_KEY=x\n")
            self.assertIsNone(guide.start(0, env, Path(tmp)))

    def test_a_non_tailscale_address_is_refused(self):
        with self.assertRaises(server.ConfigError):
            guide.tailscale_address("localhost")


if __name__ == "__main__":
    unittest.main()
