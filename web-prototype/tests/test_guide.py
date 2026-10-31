"""Tests for the Göster bana guide backend. Meta is never called: a fake opener answers each request by what it
asks for, because SAM calls run in parallel and arrive in any order."""

import base64
import io
import http.client
import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import guide  # noqa: E402
import server  # noqa: E402
import ws  # noqa: E402

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
    "uncertainty": "", "question_language": "Turkish", "label_language": "English",
    "steps": [
        {"instruction": "Sıcaklık düğmesini sıcağa çevir.", "detail": "Soldaki düğme.", "target_phrase": "temperature knob", "x": 200, "y": 400,
         "set_to_label": "hot", "set_to_meaning": "sıcak", "success_condition": "the pointer is at 'hot'",
         "check_view": "close_up"},
        {"instruction": "Başlat düğmesine bas.", "target_phrase": "start button", "x": 800, "y": 400,
         "set_to_label": "", "set_to_meaning": "", "success_condition": "no visible change",
         "check_view": "none"},
    ],
}
GROUND = [{"object_name": "temperature knob", "x": 210, "y": 410}, {"object_name": "hot", "x": 260, "y": 300},
          {"object_name": "start button", "x": 800, "y": 400}]


def last_record(httpd):
    """The usage record is written just after the response goes out."""
    for _ in range(100):
        records = httpd.usage.records(1)
        if records:
            return records[-1]
        time.sleep(0.02)
    raise AssertionError("No usage record.")


REVIEW = {"verdict": "step_ok", "explanation": "«warm» yazısını görüyorum.", "x": 210, "y": 410}


class FakeUpstream:
    """Meta's realtime endpoint: acknowledges, answers the audio with words, then closes."""

    def __init__(self):
        self.audio = bytearray()
        self.frames = [json.dumps({"sessionId": "s-1"})]
        self.ready = threading.Event()
        self.sock = type("Sock", (), {"settimeout": lambda self, value: None})()

    def send_text(self, text):
        if json.loads(text).get("type") == "endStream":
            self.ready.set()

    def send_binary(self, data):
        self.audio += data

    def recv(self):
        if self.frames:
            return ws.OP_TEXT, self.frames.pop(0)
        self.ready.wait(5)
        if self.ready.is_set() and self.ready.__dict__.setdefault("sent", False) is False:
            self.ready.sent = True
            return ws.OP_TEXT, json.dumps({"type": "speechComplete", "turnId": 1, "transcript": "Nasıl yıkarım?"})
        raise ws.WebSocketClosed(1000)

    def close(self):
        pass

    def shutdown(self):
        pass


class RoutingOpener:
    """Answers Spark plan, Spark ground, and SAM calls; records every request body."""

    def __init__(self, plan=PLAN, served="muse-spark-1.3", sam_point=None, sam_text=None, check=None,
                 reply=None, transcript="Extra rinse ne demek?"):
        self.plan, self.served = plan, served
        self.reply = reply or {"kind": "answer", "answer": "Fazladan bir durulama yapar.", "language": "Turkish"}
        self.transcript = transcript
        self.audio = []
        self.check = check or {"status": "not_done", "observed": "pointer at 'warm'", "correction": "Biraz daha sağa çevirin."}
        self.sam_point = sam_point or "1<|box;x1=180;y1=180;x2=240;y2=230;c=0.91|>"
        self.sam_text = sam_text or "1<|box;x1=780;y1=180;x2=820;y2=220;c=0.8|>"
        self.bodies = []
        self.review = REVIEW
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
        elif body.get("response_format", {}).get("json_schema", {}).get("name") == "step_review":
            reply = {"model": self.served, "choices": [{"message": {"content": json.dumps(self.review)}}]}
        elif body.get("response_format", {}).get("json_schema", {}).get("name") == "step_check":
            reply = {"model": self.served, "choices": [{"message": {"content": json.dumps(self.check)}}]}
        elif "response_format" in body:
            reply = {"model": self.served, "choices": [{"message": {"content": json.dumps(self.plan)}}],
                     "usage": {"prompt_tokens": 1000, "completion_tokens": 100}}
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
        self.assertEqual(first["detail"], "Soldaki düğme.")
        self.assertEqual((result["language"], result["labelLanguage"]), ("Turkish", "English"))
        self.assertEqual(second["detail"], "")
        self.assertIsNone(second["setTo"])
        self.assertTrue(first["verifiable"])
        self.assertFalse(second["verifiable"])
        self.assertEqual(result["served"], ["muse-spark-1.3", "sam-3.1"])

    def test_plan_parts_send_the_steps_before_the_controls_are_located(self):
        opener = RoutingOpener()
        parts = guide.plan_parts(tiny_jpeg(1000, 500), "Beyazları yıkamak istiyorum", "Turkish", FAKE_KEY, opener)
        steps = next(parts)
        self.assertEqual(len(opener.bodies), 1)  # only Spark's plan so far: no grounding, no SAM
        self.assertFalse(steps["located"])
        self.assertEqual([step["instruction"] for step in steps["steps"]], [s["instruction"] for s in PLAN["steps"]])
        self.assertTrue(all(step["box"] is None and step["boxMethod"] == "pending" for step in steps["steps"]))
        located = next(parts)
        self.assertTrue(located["located"])
        self.assertEqual(located["steps"][0]["boxMethod"], "point")
        self.assertIsNone(next(parts, None))
        self.assertEqual(located, guide.plan(tiny_jpeg(1000, 500), "Beyazları yıkamak istiyorum", "Turkish",
                                             FAKE_KEY, RoutingOpener()) | {"timings": located["timings"]})

    QUESTION = {**PLAN, "steps": [], "clarify": {"kind": "choice", "question": "Hangi program?", "options": [
        {"label": "normal", "meaning": "normal yıkama"}, {"label": "delicate", "meaning": "hassas"}]}}

    def test_a_question_comes_alone_and_costs_one_call(self):
        opener = RoutingOpener(plan=self.QUESTION)
        parts = list(guide.plan_parts(tiny_jpeg(), "Yıkayacağım", "Turkish", FAKE_KEY, opener, allow_questions=True))
        self.assertEqual(len(parts), 1)
        self.assertEqual(len(opener.bodies), 1)  # no grounding, no SAM
        self.assertEqual(parts[0]["question"]["kind"], "choice")
        self.assertEqual(parts[0]["question"]["options"][1], {"label": "delicate", "meaning": "hassas"})
        self.assertIn('kind "choice"', opener.bodies[0]["messages"][0]["content"][0]["text"])

    def test_nova_asks_only_when_allowed_and_at_most_twice(self):
        def prompt_and_question(**options):
            opener = RoutingOpener(plan={**PLAN, "clarify": self.QUESTION["clarify"]})
            result = guide.plan(tiny_jpeg(), "Yıkayacağım", "Turkish", FAKE_KEY, opener, **options)
            return opener.bodies[0]["messages"][0]["content"][0]["text"], result
        prompt, result = prompt_and_question()
        self.assertIn("Do not ask them anything", prompt)
        self.assertIsNone(result["question"])
        self.assertEqual(len(result["steps"]), 2)
        answers = [{"question": "Hangi program?", "answer": "normal"}, {"question": "Sıcaklık?", "answer": "warm"}]
        prompt, result = prompt_and_question(allow_questions=True, answers=answers)
        self.assertIn("Do not ask them anything", prompt)
        self.assertIn('with "warm"', prompt)
        self.assertIsNone(result["question"])

    def test_an_option_keeps_only_a_real_color(self):
        plan = {**PLAN, "steps": [], "clarify": {"kind": "choice", "question": "Hangi?", "options": [
            {"label": "a", "meaning": "b", "color": "#F28C28"}, {"label": "c", "meaning": "d", "color": "orange"}]}}
        options = guide.clarifying_question(plan)["options"]
        self.assertEqual(options[0]["color"], "#F28C28")
        self.assertNotIn("color", options[1])

    def test_a_question_without_options_is_ignored(self):
        plan = {**PLAN, "clarify": {"kind": "choice", "question": "Hangi?", "options": []}}
        result = guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, RoutingOpener(plan=plan), allow_questions=True)
        self.assertIsNone(result["question"])
        self.assertEqual(len(result["steps"]), 2)

    def test_the_plan_prompt_forbids_leaving_a_setting_open(self):
        self.assertIn('never write\n     "to your choice"', guide.PLAN_PROMPT)
        plan = {**PLAN, "steps": [{**PLAN["steps"][0], "own_suggestion": True}, PLAN["steps"][1]]}
        first, second = guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, RoutingOpener(plan=plan))["steps"]
        self.assertEqual(first["success"], guide.ANY_POSITION)
        self.assertEqual(second["success"], "no visible change")

    def test_a_correction_tells_what_went_wrong_and_never_asks(self):
        opener = RoutingOpener(plan={**PLAN, "clarify": self.QUESTION["clarify"]})
        correction = {"kind": "step", "wrongStep": "Saat tuşuna bas.", "said": "Böyle bir tuş yok", "done": ["Kapağı aç."]}
        result = guide.plan(tiny_jpeg(), "Saati ayarla", "Turkish", FAKE_KEY, opener, allow_questions=True, correction=correction)
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        for text in ("Saat tuşuna bas.", "Böyle bir tuş yok", "Kapağı aç.", "only the steps that remain"):
            self.assertIn(text, prompt)
        self.assertIsNone(result["question"])

    def test_motion_comes_through_and_a_strange_one_is_unknown(self):
        plan = {**PLAN, "steps": [{**PLAN["steps"][0], "motion": "turn_clockwise"}, {**PLAN["steps"][1], "motion": "spin"}]}
        first, second = guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, RoutingOpener(plan=plan))["steps"]
        self.assertEqual((first["motion"], second["motion"]), ("turn_clockwise", "unknown"))

    def test_not_solved_tells_what_was_done_and_may_ask(self):
        opener = RoutingOpener(plan=self.QUESTION)
        correction = {"kind": "outcome", "wrongStep": "", "said": "Hâlâ açılmıyor", "done": ["Güç tuşuna bas."]}
        result = guide.plan(tiny_jpeg(), "Açılmıyor", "Turkish", FAKE_KEY, opener, allow_questions=True, correction=correction)
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        for text in ("not solved", "Hâlâ açılmıyor", "Güç tuşuna bas."):
            self.assertIn(text, prompt)
        self.assertEqual(result["question"]["kind"], "choice")

    def test_a_plan_says_when_the_task_goes_on(self):
        plan = {**PLAN, "task_continues": True, "remaining_path": "«General» › «Language»"}
        result = guide.plan(tiny_jpeg(), "Dili değiştir", "Turkish", FAKE_KEY, RoutingOpener(plan=plan))
        self.assertEqual((result["continues"], result["remaining"]), (True, "«General» › «Language»"))
        self.assertEqual(guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, RoutingOpener())["continues"], False)

    def test_the_next_screen_is_planned_from_where_they_are(self):
        opener = RoutingOpener(plan=self.QUESTION)
        correction = {"kind": "continue", "wrongStep": "", "said": "«General» › «Language»", "done": ["«Settings» aç."]}
        result = guide.plan(tiny_jpeg(), "Dili değiştir", "Turkish", FAKE_KEY, opener, allow_questions=True, correction=correction)
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        for text in ("in the middle of this task", "«General» › «Language»", "«Settings» aç."):
            self.assertIn(text, prompt)
        self.assertIsNone(result["question"])

    def test_a_refused_plan_is_one_final_part(self):
        refused = {**PLAN, "safe_to_guide": False, "steps": []}
        parts = list(guide.plan_parts(tiny_jpeg(), "Sigortayı aç", "Turkish", FAKE_KEY, RoutingOpener(plan=refused)))
        self.assertEqual(len(parts), 1)
        self.assertTrue(parts[0]["located"])

    def test_plan_prompt_starts_the_device_only_when_the_task_runs_it(self):
        prompt = guide.PLAN_PROMPT.format(show_rule="",question="q", language_rule="", lang="Turkish", max_steps=6, marking="",
                                          ask_rule="", context="")
        self.assertIn("only when their task is to run it", prompt)
        self.assertIn("detail", guide.PLAN_SCHEMA["json_schema"]["schema"]["properties"]["steps"]["items"]["required"])

    def test_automatic_language_follows_the_question(self):
        opener = RoutingOpener(plan={**PLAN, "question_language": "English"})
        result = guide.plan(tiny_jpeg(), "I want a normal wash", "Turkish", FAKE_KEY, opener, auto_language=True)
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        self.assertIn("instruction: one short sentence in the language of their question", prompt)
        self.assertIn("if you cannot tell, Turkish", prompt)
        self.assertIn("wrap it in « »", prompt)
        self.assertEqual(result["language"], "English")

    def test_a_fixed_language_stays_and_an_unknown_answer_falls_back(self):
        opener = RoutingOpener(plan={**PLAN, "question_language": "Klingon"})
        result = guide.plan(tiny_jpeg(), "q", "Turkish", FAKE_KEY, opener)
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        self.assertIn("They read and speak Turkish.", prompt)
        self.assertIn("instruction: one short sentence in Turkish", prompt)
        self.assertEqual(result["language"], "Turkish")

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


class SpokenLanguageTests(unittest.TestCase):
    def test_spark_calling_it_chinese_is_the_mandarin_the_app_speaks(self) -> None:
        self.assertEqual(guide.spoken_language("Chinese", "English"), "Mandarin Chinese")
        self.assertEqual(guide.spoken_language("Mandarin Chinese", "English"), "Mandarin Chinese")
        self.assertEqual(guide.spoken_language("Spanish", "English"), "Spanish")
        self.assertEqual(guide.spoken_language("Klingon", "English"), "English")
        self.assertEqual(guide.spoken_language(None, "Turkish"), "Turkish")


class TourPromptTests(unittest.TestCase):
    def test_a_general_question_gets_a_tour_of_unchecked_controls(self):
        for words in ('"How do I use this?"', "at most 5", "without asking them to press it", 'check_view is "none"',
                      "task_continues is false", "don't pick a task for them", "could not tell what they do"):
            self.assertIn(words, " ".join(guide.PLAN_PROMPT.split()))

    def test_labels_they_may_not_read_are_explained(self):
        self.assertIn("say in the same sentence what it means", " ".join(guide.PLAN_PROMPT.split()))

    def test_a_step_without_a_visible_result_is_not_checked(self):
        step = {"instruction": "This is «Start».", "check_view": "none"}
        entry = guide.step_entry(step, "start button", "", (500, 250), 1000, 500)
        self.assertEqual(entry["check"], "none")
        self.assertFalse(entry["verifiable"])

    def test_a_result_away_from_the_control_is_checked_on_the_whole_view(self):
        step = {"instruction": "Tap «Continue».", "check_view": "whole_view"}
        entry = guide.step_entry(step, "continue button", "", (500, 250), 1000, 500)
        self.assertEqual(entry["check"], "whole_view")
        self.assertFalse(entry["verifiable"])  # the older app keeps skipping what it can't see on a close-up

    def test_the_whole_view_check_takes_a_new_state_as_proof(self):
        words = " ".join(guide.VERIFY_WHOLE_PROMPT.split())
        for part in ("a dialog that is gone", "a state that can only come after this step", "the same dialog still open"):
            self.assertIn(part, words)


class RestrictedRegionTests(unittest.TestCase):
    def test_every_code_is_two_letters_and_china_is_listed(self):
        self.assertTrue(all(len(code) == 2 and code.isupper() for code in guide.RESTRICTED_COUNTRIES))
        self.assertLessEqual({"CN", "HK", "MO", "RU"}, guide.RESTRICTED_COUNTRIES)
        self.assertNotIn("US", guide.RESTRICTED_COUNTRIES)


class ShowRequestTests(unittest.TestCase):
    SHOW = {**PLAN, "steps": [], "show_request": {"what": "Fareyi göster.", "why": "Işığına bakacağım."}, "finding": "only a monitor",
            "clarify": {"kind": "state", "question": "Kablolu mu?", "options": [{"label": "", "meaning": "Evet"}]}}

    def run_plan(self, plan, **options):
        opener = RoutingOpener(plan=plan)
        return guide.plan(tiny_jpeg(1600, 900), "Fare çalışmıyor", "Turkish", FAKE_KEY, opener, allow_questions=True, **options), opener

    def test_asks_to_see_it_before_asking_a_question(self):
        result, _ = self.run_plan(self.SHOW)
        self.assertEqual(result["showRequest"]["what"], "Fareyi göster.")
        self.assertIsNone(result["question"])
        self.assertEqual(result["finding"], "only a monitor")
        self.assertEqual(result["steps"], [])

    def test_after_the_limit_it_stops_asking_to_see(self):
        result, opener = self.run_plan(self.SHOW, shows=guide.MAX_SHOWS)
        self.assertIsNone(result["showRequest"])
        self.assertIn("you have seen enough", json.dumps(opener.bodies, ensure_ascii=False))

    def test_earlier_findings_reach_the_prompt(self):
        _, opener = self.run_plan(self.SHOW, findings=["wireless mouse, switch off"])
        self.assertIn("wireless mouse, switch off", json.dumps(opener.bodies, ensure_ascii=False))

    def test_steps_win_over_a_show_request(self):
        result, _ = self.run_plan({**PLAN, "show_request": {"what": "Fareyi göster.", "why": ""}})
        self.assertIsNone(result["showRequest"])
        self.assertTrue(result["steps"])

    def test_bad_findings_are_refused(self):
        for body in ({"findings": "x"}, {"findings": ["x"] * 7}, {"shows": -1}, {"shows": True}):
            with self.assertRaises(guide.BadRequest):
                guide.plan_findings(body)


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

    def test_confirmation_only_comes_with_a_done_step(self):
        done = RoutingOpener(check={"status": "done", "observed": "hot", "correction": "", "confirmation": "«hot» seçildi."})
        self.assertEqual(guide.verify(tiny_jpeg(520, 520), "i", "s", "Turkish", FAKE_KEY, done)["confirmation"], "«hot» seçildi.")
        failed = RoutingOpener(check={"status": "not_done", "observed": "warm", "correction": "x", "confirmation": "y"})
        self.assertEqual(guide.verify(tiny_jpeg(520, 520), "i", "s", "Turkish", FAKE_KEY, failed)["confirmation"], "")

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
        self.assertEqual(result["language"], "Turkish")

    def test_an_automatic_answer_reports_its_language(self):
        opener = RoutingOpener(reply={"kind": "answer", "answer": "It adds a rinse.", "language": "English"})
        result = guide.ask(tiny_jpeg(), "What does extra rinse mean?", "Turkish", guide.ask_context({"context": CONTEXT}),
                           FAKE_KEY, opener, auto_language=True)
        prompt = opener.bodies[0]["messages"][0]["content"][0]["text"]
        self.assertIn("answer in the language of their question", prompt)
        self.assertEqual(result["language"], "English")

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

    def stream(self, body):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/guide/plan", data=json.dumps(body).encode(), method="POST",
            headers={"Host": f"mac.example.ts.net:{self.port}", guide.CLIENT_HEADER: guide.CLIENT_NAME,
                     "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.headers["Content-Type"], [json.loads(line) for line in response.read().splitlines()]

    def test_a_streamed_plan_sends_the_steps_then_the_located_plan(self):
        content_type, lines = self.stream(self.frame_body(stream=True, record=True))
        self.assertTrue(content_type.startswith("application/x-ndjson"))
        self.assertEqual([line["located"] for line in lines], [False, True])
        self.assertNotIn("recording", lines[0])
        self.assertTrue((self.recordings / lines[1]["recording"] / "frame.jpg").is_file())
        record = last_record(self.httpd)
        self.assertLessEqual(record["firstSeconds"], record["seconds"])

    def test_an_error_after_the_steps_is_the_last_line(self):
        def failing_ground(request, timeout=None):
            body = json.loads(request.data)
            if "response_format" not in body and body["model"] != guide.SAM_MODEL:
                raise server.UpstreamError(503, "Meta is busy.")
            return RoutingOpener()(request, timeout)
        self.httpd.opener = failing_ground
        _, lines = self.stream(self.frame_body(stream=True))
        self.assertEqual(len(lines), 2)
        self.assertFalse(lines[0]["located"])
        self.assertEqual(lines[1]["error"]["kind"], "upstream")

    def test_a_bad_streamed_request_still_gets_its_status(self):
        status, body = self.request("/api/guide/plan", {"frame": "", "question": "", "stream": True})
        self.assertEqual((status, body["error"]["kind"]), (400, "request"))

    def last_usage(self):
        return last_record(self.httpd)

    def test_a_correction_thinks_longer_and_is_counted(self):
        correction = {"kind": "restart", "wrongStep": "x", "said": "", "done": []}
        self.assertEqual(self.request("/api/guide/plan", self.frame_body(correction=correction))[0], 200)
        self.assertEqual(self.opener.bodies[0]["reasoning_effort"], "low")
        record = self.last_usage()
        self.assertEqual((record["spark"], record["correction"]), ("meta-low", "restart"))

    def test_the_next_screen_is_not_a_second_look(self):
        correction = {"kind": "continue", "wrongStep": "", "said": "", "done": []}
        self.assertEqual(self.request("/api/guide/plan", self.frame_body(correction=correction))[0], 200)
        self.assertEqual(self.opener.bodies[0]["reasoning_effort"], "minimal")
        self.assertEqual(self.last_usage()["correction"], "continue")

    def test_bad_answers_or_corrections_are_refused(self):
        for extra in ({"answers": "x"}, {"answers": [{"question": "q"}]}, {"answers": [{"question": "q", "answer": "a"}] * 3},
                      {"correction": {"kind": "other"}}, {"correction": {"kind": "step", "wrongStep": 1}}):
            self.assertEqual(self.request("/api/guide/plan", self.frame_body(**extra))[0], 400, extra)
        self.assertEqual(self.opener.bodies, [])

    def reassess_body(self, **extra):
        return {"frame": base64.b64encode(tiny_jpeg()).decode(), "language": "Turkish", "target": "temperature knob",
                "context": {"device": "washer", "current": 1, "steps": [
                    {"instruction": "Düğmeyi çevir.", "success": "x", "result": "not done yet"}]}, **extra}

    def test_a_step_that_holds_up_is_located_again(self):
        status, body = self.request("/api/guide/reassess", self.reassess_body())
        self.assertEqual((status, body["verdict"]), (200, "step_ok"))
        self.assertEqual(body["boxMethod"], "point")
        self.assertIsNotNone(body["point"])
        self.assertEqual(self.opener.bodies[0]["reasoning_effort"], "low")
        prompt = self.opener.bodies[0]["messages"][0]["content"][0]["text"]
        self.assertIn("without defending it", prompt)
        self.assertEqual(self.last_usage()["correction"], "reassess")

    def test_a_wrong_step_is_not_located(self):
        self.opener.review = {"verdict": "wrong_step", "explanation": "Böyle bir düğme yok.", "x": 0, "y": 0}
        status, body = self.request("/api/guide/reassess", self.reassess_body())
        self.assertEqual((status, body["verdict"], body["point"]), (200, "wrong_step", None))
        self.assertEqual([b["model"] for b in self.opener.bodies], ["muse-spark-1.3"])

    def test_a_review_needs_the_current_step(self):
        extra = {"context": {"device": "x", "current": 0, "steps": []}}
        self.assertEqual(self.request("/api/guide/reassess", self.reassess_body(**extra))[0], 400)

    def test_live_listening_relays_words_and_stores_no_audio(self):
        upstream = FakeUpstream()
        self.httpd.ws_connect = lambda url: upstream
        self.httpd.allowed_hosts = {*self.httpd.allowed_hosts, f"127.0.0.1:{self.port}"}
        phone = ws.connect(f"ws://127.0.0.1:{self.port}/api/guide/listen", {guide.CLIENT_HEADER: guide.CLIENT_NAME})
        phone.send_text(json.dumps({"languages": ["Turkish", "English"]}))
        self.assertEqual(json.loads(phone.recv()[1])["type"], "ready")
        phone.send_binary(b"\x01\x02" * 24000)
        phone.send_text(json.dumps({"type": "endStream"}))
        self.assertEqual(json.loads(phone.recv()[1])["transcript"], "Nasıl yıkarım?")
        phone.shutdown()
        record = self.last_usage()
        self.assertEqual((record["endpoint"], record["status"]), ("listen", 101))
        self.assertEqual(record["calls"][0]["audio_seconds"], 1.0)
        self.assertFalse(self.recordings.exists())
        self.assertNotIn("api", json.dumps(record["calls"]))

    def test_live_listening_needs_the_app_and_an_upgrade(self):
        self.assertEqual(self.request("/api/guide/listen")[0], 400)  # no upgrade headers
        self.assertEqual(self.request("/api/guide/listen", headers={guide.CLIENT_HEADER: "browser"})[0], 403)

    def test_a_moved_marker_is_only_counted(self):
        self.assertEqual(self.request("/api/guide/correction", {"kind": "moved"}), (200, {"ok": True}))
        self.assertEqual(self.opener.bodies, [])
        self.assertEqual(self.last_usage()["correction"], "moved")
        self.assertEqual(self.request("/api/guide/correction", {"kind": "x"})[0], 400)
        self.assertEqual(self.request("/api/guide/correction", {"kind": "not_solved"})[0], 200)

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


class InviteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.invites = guide.Invites(Path(self.tmp.name), per_code={"plan": 2}, total={"plan": 3})

    def tearDown(self):
        self.tmp.cleanup()

    def test_codes_are_stored_only_as_hashes_and_typing_is_forgiving(self):
        code, created = self.invites.create("Ayşe")
        self.assertRegex(code, r"^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")
        self.assertNotIn(code, (Path(self.tmp.name) / "guide-invites.json").read_text())
        self.assertEqual(self.invites.find(code.lower().replace("-", " "))["id"], created["id"])
        self.assertIsNone(self.invites.find("AAAA-BBBB-CCCC"))
        self.assertIsNone(self.invites.find(""))

    def test_revoked_codes_stop_working(self):
        code, created = self.invites.create("x")
        self.assertTrue(self.invites.revoke(created["id"]))
        self.assertIsNone(self.invites.find(code))

    def test_per_code_and_total_limits(self):
        first, second = (self.invites.find(self.invites.create(name)[0]) for name in ("a", "b"))
        self.invites.consume(first, "plan")
        self.invites.consume(first, "plan")
        with self.assertRaises(guide.LimitReached):
            self.invites.consume(first, "plan")
        self.invites.consume(second, "plan")
        with self.assertRaises(guide.LimitReached):  # total of 3 reached
            self.invites.consume(second, "plan")
        with self.assertRaises(guide.LimitReached):  # a kind without a limit is not allowed
            self.invites.consume(second, "ask")


class InternetListenerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        folder = Path(self.tmp.name)
        self.env = folder / ".env.local"
        self.env.write_text(f"MODEL_API_KEY={FAKE_KEY}\n")
        self.recordings = folder / "recordings"
        self.invites = guide.Invites(folder)
        self.code, _ = self.invites.create("tester")
        self.owner, _ = self.invites.create("maintainer", record=True)
        self.httpd = guide.GuideServer("127.0.0.1", 0, ["guide.example.com"], self.env, self.recordings,
                                       RoutingOpener(), invites=self.invites)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def request(self, path, body=None, code=None, host="guide.example.com"):
        headers = {"Host": host, guide.CLIENT_HEADER: guide.CLIENT_NAME, "Content-Type": "application/json"}
        if code:
            headers["Authorization"] = f"Bearer {code}"
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", headers=headers,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         method="POST" if body is not None else "GET")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def frame_body(self, **extra):
        return {"frame": base64.b64encode(tiny_jpeg()).decode(), "question": "Nasıl?", "language": "Turkish", **extra}

    def test_every_request_needs_a_valid_code(self):
        status, body = self.request("/api/guide/status")
        self.assertEqual((status, body["error"]["kind"]), (401, "invite"))
        self.assertEqual(self.request("/api/guide/status", code="WRONG-CODE-0000")[0], 401)
        status, body = self.request("/api/guide/status", code=self.code)
        self.assertEqual(status, 200)
        self.assertTrue(body["internet"])
        self.assertFalse(body["mayRecord"])

    def test_a_browser_opening_the_address_goes_to_the_home_page(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        connection.request("GET", "/")
        response = connection.getresponse()
        response.read()
        connection.close()
        self.assertEqual((response.status, response.getheader("Location")), (302, guide.HOME_PAGE))
        self.assertEqual(self.request("/api/guide/status")[0], 401)  # the API itself stays closed

    def test_the_public_name_is_accepted_without_a_port_and_others_are_not(self):
        self.assertEqual(self.request("/api/guide/status", code=self.code, host="guide.example.com:443")[0], 200)
        self.assertEqual(self.request("/api/guide/status", code=self.code, host="evil.example")[0], 403)

    def test_testers_cannot_record_but_the_maintainer_can(self):
        status, body = self.request("/api/guide/plan", self.frame_body(record=True), code=self.code)
        self.assertEqual(status, 200)
        self.assertNotIn("recording", body)
        self.assertFalse(self.recordings.exists())
        status, body = self.request("/api/guide/plan", self.frame_body(record=True), code=self.owner)
        self.assertIn("recording", body)

    def test_a_used_up_limit_answers_429(self):
        self.invites.per_code = {"plan": 1}
        self.assertEqual(self.request("/api/guide/plan", self.frame_body(), code=self.code)[0], 200)
        status, body = self.request("/api/guide/plan", self.frame_body(), code=self.code)
        self.assertEqual((status, body["error"]["kind"]), (429, "limit"))


class UsageTests(unittest.TestCase):
    def test_a_plan_request_logs_every_model_call_with_session_and_task(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / ".env.local"
            env.write_text(f"MODEL_API_KEY={FAKE_KEY}\n")
            httpd = guide.GuideServer("127.0.0.1", 0, ["mac.example.ts.net"], env, Path(tmp) / "recordings", RoutingOpener())
            threading.Thread(target=httpd.serve_forever, daemon=True).start()
            port = httpd.server_address[1]
            try:
                body = {"frame": base64.b64encode(tiny_jpeg()).decode(), "question": "Nasıl?", "language": "Turkish"}
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/api/guide/plan", data=json.dumps(body).encode(), method="POST",
                    headers={"Host": f"mac.example.ts.net:{port}", guide.CLIENT_HEADER: guide.CLIENT_NAME,
                             "Content-Type": "application/json", "X-Nova-Session": "s-1", "X-Nova-Task": "t-1"})
                urllib.request.urlopen(request, timeout=10).read()
            finally:
                httpd.shutdown()
                httpd.server_close()
            records = guide.UsageLog(Path(tmp) / "usage").records(1)
            self.assertEqual(len(records), 1)
            record = records[0]
            self.assertEqual((record["endpoint"], record["status"], record["session"], record["task"]), ("plan", 200, "s-1", "t-1"))
            models = [call["model"] for call in record["calls"]]
            self.assertEqual(models.count("muse-spark-1.3"), 2)  # plan and ground
            self.assertGreaterEqual(models.count("sam-3.1"), 2)  # one per step, more on fallback
            self.assertNotIn("frame", json.dumps(record))  # counts only, no content

    def test_durations_give_median_and_slowest_tenth_and_the_time_to_the_first_step(self):
        default = guide.SparkRoute().label
        records = [{"endpoint": "plan", "status": 200, "seconds": seconds, "firstSeconds": seconds - 6, "spark": default}
                   for seconds in range(10, 20)]
        records += [{"endpoint": "verify", "status": 200, "seconds": 4, "spark": default},
                    {"endpoint": "verify", "status": 502, "seconds": 30, "spark": default}]
        spreads = guide.durations(records)
        self.assertEqual(spreads["plan"], {"count": 10, "median": 14.5, "p90": 19})
        self.assertEqual(spreads["plan (first step)"]["median"], 8.5)
        self.assertEqual(spreads["verify"], {"count": 1, "median": 4, "p90": 4})

    def test_summary_averages_per_task_and_prices_calls(self):
        records = [
            {"endpoint": "plan", "task": "a", "session": "s", "calls": [
                {"model": "muse-spark-1.3", "usage": {"prompt_tokens": 2000, "completion_tokens": 200}},
                {"model": "sam-3.1"}]},
            {"endpoint": "transcribe", "task": "a", "session": "s", "calls": [
                {"model": "muse-voice-transcribe-1.0", "audio_seconds": 30}]},
            {"endpoint": "plan", "task": "b", "session": "s", "calls": [
                {"model": "muse-spark-1.3", "usage": {"input_tokens": 1000, "output_tokens": 0}}]},
        ]
        prices = {"muse-spark-1.3": {"input_per_million": 1.0, "output_per_million": 5.0}, "sam-3.1": {"per_call": 0.01},
                  "muse-voice-transcribe-1.0": {"per_minute": 0.02}}
        summary = guide.summarize(records, prices)
        self.assertEqual((summary["tasks"], summary["sessions"], summary["unpriced_calls"]), (2, 1, 0))
        self.assertEqual(summary["average_task"]["calls"]["muse-spark-1.3"], 1)
        # task a: 0.002 + 0.001 + 0.01 + 0.01 = 0.023; task b: 0.001 -> average 0.012
        self.assertAlmostEqual(summary["average_task"]["cost"], 0.012, places=4)
        self.assertEqual(guide.summarize(records)["unpriced_calls"], 4)


class SparkRouteTests(unittest.TestCase):
    """The maintainer's speed test settings: Spark moves, SAM stays on Meta, other testers can't change anything."""

    class SpyOpener(RoutingOpener):
        def __init__(self):
            super().__init__()
            self.sent = []

        def __call__(self, request, timeout=None):
            with self.lock:
                self.sent.append((request.full_url, request.get_header("Authorization"), json.loads(request.data)))
            return super().__call__(request, timeout)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        folder = Path(self.tmp.name)
        self.env = folder / ".env.local"
        self.env.write_text(f"MODEL_API_KEY={FAKE_KEY}\nBASETEN_API_KEY=baseten-test-key\n")
        self.invites = guide.Invites(folder)
        self.tester, _ = self.invites.create("tester")
        self.owner, _ = self.invites.create("maintainer", record=True)
        self.opener = self.SpyOpener()
        self.httpd = guide.GuideServer("127.0.0.1", 0, ["guide.example.com"], self.env, folder / "recordings",
                                       self.opener, invites=self.invites)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def plan(self, code, spark=None):
        body = {"frame": base64.b64encode(tiny_jpeg()).decode(), "question": "Nasıl?", "language": "Turkish"}
        if spark:
            body["spark"] = spark
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/guide/plan", data=json.dumps(body).encode(), method="POST",
            headers={"Host": f"guide.example.com:{self.port}", guide.CLIENT_HEADER: guide.CLIENT_NAME,
                     "Content-Type": "application/json", "Authorization": f"Bearer {code}"})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def test_baseten_gets_the_spark_calls_and_meta_keeps_sam(self):
        status, _ = self.plan(self.owner, {"provider": "baseten", "effort": "minimal"})
        self.assertEqual(status, 200)
        sparks = [sent for sent in self.opener.sent if sent[2]["model"] != guide.SAM_MODEL]
        sams = [sent for sent in self.opener.sent if sent[2]["model"] == guide.SAM_MODEL]
        self.assertEqual(len(sparks), 2)  # plan and ground
        for url, authorization, payload in sparks:
            self.assertEqual(url, guide.BASETEN_BASE + "/chat/completions")
            self.assertEqual(authorization, "Api-Key baseten-test-key")
            self.assertEqual((payload["model"], payload["reasoning_effort"]), (guide.BASETEN_MODEL, "minimal"))
        self.assertTrue(sams)
        for url, authorization, _ in sams:
            self.assertTrue(url.startswith(server.API_BASE))
            self.assertEqual(authorization, f"Bearer {FAKE_KEY}")
        self.assertEqual(last_record(self.httpd)["spark"], "baseten-minimal")

    def test_meta_low_changes_only_the_effort(self):
        self.assertEqual(self.plan(self.owner, {"provider": "meta", "effort": "low"})[0], 200)
        url, authorization, payload = self.opener.sent[0]
        self.assertTrue(url.startswith(server.API_BASE))
        self.assertEqual(authorization, f"Bearer {FAKE_KEY}")
        self.assertEqual((payload["model"], payload["reasoning_effort"]), (server.REASONING_MODEL, "low"))

    def test_without_a_setting_nothing_changes_and_the_route_does_not_leak(self):
        self.plan(self.owner, {"provider": "baseten", "effort": "minimal"})
        self.opener.sent.clear()
        self.assertEqual(self.plan(self.tester)[0], 200)
        self.assertEqual((self.opener.sent[0][2]["model"], self.opener.sent[0][2]["reasoning_effort"]),
                         (server.REASONING_MODEL, "minimal"))
        self.assertEqual(last_record(self.httpd)["spark"], "meta-minimal")

    def test_only_the_maintainer_may_change_the_setting(self):
        status, body = self.plan(self.tester, {"provider": "baseten", "effort": "low"})
        self.assertEqual((status, body["error"]["kind"]), (400, "request"))
        self.assertEqual(self.opener.sent, [])
        self.assertEqual(self.plan(self.tester, {"provider": "meta", "effort": "low"})[0], 400)
        self.assertEqual(self.plan(self.tester, {"provider": "meta", "effort": "minimal"})[0], 200)  # the default is fine
        self.assertEqual(self.invites._load(self.invites.usage_path, {})["codes"].get(
            self.invites.find(self.tester)["id"], {}).get("plan"), 1)  # refused requests spend nothing

    def test_an_unknown_setting_is_refused(self):
        for spark in ({"provider": "openai", "effort": "low"}, {"provider": "meta", "effort": "high"}, "baseten"):
            self.assertEqual(self.plan(self.owner, spark)[0], 400)
        self.assertEqual(self.opener.sent, [])

    def test_baseten_without_its_key_is_a_setup_error(self):
        self.env.write_text(f"MODEL_API_KEY={FAKE_KEY}\n")
        status, body = self.plan(self.owner, {"provider": "baseten", "effort": "low"})
        self.assertEqual((status, body["error"]["kind"]), (503, "setup"))
        self.assertIn(guide.BASETEN_KEY_NAME, body["error"]["message"])

    def test_durations_keep_each_setting_apart(self):
        records = [{"endpoint": "plan", "status": 200, "seconds": 10, "firstSeconds": 5},  # older than the field: low
                   {"endpoint": "plan", "status": 200, "seconds": 12, "spark": "meta-low"},
                   {"endpoint": "plan", "status": 200, "seconds": 7, "firstSeconds": 3, "spark": "meta-minimal"}]
        spreads = guide.durations(records)
        self.assertEqual(spreads["plan · meta-low"]["count"], 2)
        self.assertEqual(spreads["plan"]["median"], 7)
        self.assertEqual(spreads["plan (first step)"]["median"], 3)


class StartTests(unittest.TestCase):
    def test_guide_is_off_without_a_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / ".env.local"
            env.write_text("MODEL_API_KEY=x\n")
            self.assertFalse(guide.start(0, env, Path(tmp)))

    def test_the_internet_listener_starts_on_loopback_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / ".env.local"
            env.write_text("MODEL_API_KEY=x\nNOVA_PUBLIC_HOST=guide.example.com\nNOVA_GUIDE_PUBLIC_PORT=0\n")
            listeners = guide.start(0, env, Path(tmp))
            try:
                self.assertEqual(len(listeners.servers), 1)
                self.assertEqual(listeners.servers[0].server_address[0], "127.0.0.1")
                self.assertIsNotNone(listeners.servers[0].invites)
            finally:
                for server in listeners.servers:
                    server.shutdown()
                listeners.server_close()

    def test_a_non_tailscale_address_is_refused(self):
        with self.assertRaises(server.ConfigError):
            guide.tailscale_address("localhost")


if __name__ == "__main__":
    unittest.main()
