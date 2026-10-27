"""Spike: can Muse Spark + SAM 3.1 find the exact control to press on a photo of a device?

For each case (photo + question) it runs:
  1. Spark plan     - identify the device, safety check, steps with a target phrase and a point;
                      for dials, also the printed label to turn the dial to.
  2. Spark ground   - a dedicated point-grounding call for every target and dial label.
  3. SAM from point - SAM 3.1 point prompt seeded with Spark's grounded point -> one box.
  4. Fallback       - if that box is weak (low confidence, too large, or misses the point), search
                      SAM for every generic "button"/"knob" plus the target phrase, and take the box
                      nearest to Spark's point.
Reads test-photos/cases.json ([{"image": "<file in test-photos/>", "question": "..."}]); photos are resized and
stripped of metadata before they are sent. Writes results.json and report.html to
web-prototype/static/reports/sam-test/ (both folders are git-ignored).
Standard model IDs only; any Contributor model in a response aborts (HACKATHON.md rule 1).
Usage: python3 sam_test.py [image ...]   (no args: all cases; an unknown arg: rebuild the report only)
"""
import base64
import html
import json
import math
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ENV_FILE = REPO / ".env.local"
PHOTOS = REPO / "test-photos"  # git-ignored: cases.json plus the photos it names
OUT = REPO / "web-prototype" / "static" / "reports" / "sam-test"  # git-ignored; served at /reports/sam-test/
API_BASE = "https://api.meta.ai/v1"
SPARK = "muse-spark-1.3"
SAM = "sam-3.1"
MAX_PHOTO_SIDE = 1600

MIN_CONFIDENCE = 0.5
MAX_BOX_SHARE = 0.15  # a control never covers more than this share of the photo
MIN_SIDE_SHARE = 0.012  # a control's shorter side is at least this share of the photo width (icons are smaller)
POINT_MARGIN = 0.02  # how far (share of the photo width) the point may sit outside the box

PLAN_SCHEMA = {
    "type": "json_schema",
    "json_schema": {
        "name": "device_guide",
        "schema": {
            "type": "object",
            "properties": {
                "device_type": {"type": "string"},
                "brand_or_model_seen": {"type": "string"},
                "safe_to_guide": {"type": "boolean"},
                "safety_note": {"type": "string"},
                "steps": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "instruction": {"type": "string"},
                            "target_phrase": {"type": "string"},
                            "x": {"type": "integer"},
                            "y": {"type": "integer"},
                            "set_to_label": {"type": "string"},
                        },
                        "required": ["instruction", "target_phrase", "x", "y", "set_to_label"],
                        "additionalProperties": False,
                    },
                },
                "uncertainty": {"type": "string"},
            },
            "required": ["device_type", "brand_or_model_seen", "safe_to_guide", "safety_note", "steps", "uncertainty"],
            "additionalProperties": False,
        },
    },
}

PLAN_PROMPT = """You guide a person who is standing in front of the device in this photo.
Their question: "{question}"
1. Identify the device type, and any brand or model text you can read.
2. Decide whether it is safe to guide them. Refuse gas valves, electrical panels, a moving vehicle, and medication dosing.
3. Give the shortest list of physical steps (at most 4). For each step:
   - instruction: one short sentence in the same language as the question.
   - target_phrase: a short English noun phrase naming the exact control to touch, as it looks in the photo
     (for example "rinse button", "program selector dial"). Name one control, not a region.
   - x, y: where that control is, on a 0-1000 grid of this image, (0,0) top-left.
   - set_to_label: if the step turns a dial or knob to a position, the exact label printed at that position
     (for example "very dry" or "on"), copied from the photo. Otherwise an empty string.
4. uncertainty: say what you could not read or are guessing. Empty string if none.
Only describe controls you can actually see. If the needed control is not visible, say so in uncertainty."""

GROUND_PROMPT = ('Point to each of the following objects in the image: {names}. For each object, answer in the '
                 'format {{"object_name": "<name>", "x": <int>, "y": <int>}}. The coordinates should be in the '
                 '0-1000 range. Return a JSON array of results. If you cannot find an object, omit it from the results.')


def api_key() -> str:
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("MODEL_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("MODEL_API_KEY is missing from .env.local")


def post(path: str, payload: dict, key: str, timeout: int = 180) -> tuple[dict, float]:
    request = urllib.request.Request(
        f"{API_BASE}/{path}", data=json.dumps(payload).encode(), method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read())
    except urllib.error.HTTPError as error:
        sys.exit(f"{path} failed: HTTP {error.code} {error.read()[:400]!r}")
    served = str(data.get("model") or "")
    if "contributor" in served.lower():
        sys.exit(f"Meta served a Contributor model ({served}); stopping (HACKATHON.md rule 1).")
    return data, round(time.time() - started, 2)


def image_size(path: Path) -> tuple[int, int]:
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         capture_output=True, text=True, check=True).stdout
    return int(re.search(r"pixelWidth: (\d+)", out)[1]), int(re.search(r"pixelHeight: (\d+)", out)[1])


def prepared_photo(name: str) -> Path:
    """A resized JPEG copy of a test photo with all metadata (GPS, device) removed before it leaves the Mac."""
    target = OUT / "photos" / (Path(name).stem + ".jpg")
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["sips", "-Z", str(MAX_PHOTO_SIDE), "-s", "format", "jpeg", str(PHOTOS / name),
                        "--out", str(target)], capture_output=True, check=True)
        subprocess.run(["exiftool", "-q", "-q", "-overwrite_original", "-all=", str(target)], check=True)
    return target


def data_url(path: Path) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(path.read_bytes()).decode()


def spark(content: list, key: str, effort: str, schema: dict | None = None) -> tuple[str, float, str]:
    payload = {"model": SPARK, "reasoning_effort": effort, "messages": [{"role": "user", "content": content}]}
    if schema:
        payload["response_format"] = schema
    data, seconds = post("chat/completions", payload, key)
    return data["choices"][0]["message"].get("content") or "", seconds, str(data.get("model"))


def sam(image: str, prompt: str, key: str) -> tuple[list[dict], float, str]:
    payload = {"model": SAM, "metadata": {"include_confidence": "true", "mask_encoding": "one_bit"},
               "input": [{"type": "message", "role": "user", "content": [
                   {"type": "input_text", "text": prompt}, {"type": "input_image", "image_url": image}]}]}
    data, seconds = post("responses", payload, key)
    text = data.get("output_text") or "".join(
        part.get("text", "") for item in data.get("output", []) for part in item.get("content", []) or []
        if part.get("type") == "output_text")
    boxes = []
    for object_id, fields in re.findall(r"(\d+)<\|box;([^|]*)\|>", text):
        values = dict(field.split("=", 1) for field in fields.split(";"))
        boxes.append({"id": int(object_id), "x1": int(values["x1"]), "y1": int(values["y1"]),
                      "x2": int(values["x2"]), "y2": int(values["y2"]), "c": float(values.get("c", "nan"))})
    return boxes, seconds, str(data.get("model"))


def parse_json(text: str):
    match = re.search(r"[\[{].*[\]}]", text, re.S)
    return json.loads(match[0]) if match else None


def to_px(point: dict, width: int, height: int) -> list[int]:
    return [min(max(round(point["x"] * width / 1000), 0), width - 1),
            min(max(round(point["y"] * height / 1000), 0), height - 1)]


def weak_reason(box: dict | None, px: int, py: int, width: int, height: int) -> str:
    """Why a SAM box can't be trusted as the control at (px, py); empty when it can."""
    if box is None:
        return "no box"
    if not box["c"] >= MIN_CONFIDENCE:
        return f"confidence {box['c']:.2f}"
    if (box["x2"] - box["x1"]) * (box["y2"] - box["y1"]) > MAX_BOX_SHARE * width * height:
        return "box too large"
    if min(box["x2"] - box["x1"], box["y2"] - box["y1"]) < MIN_SIDE_SHARE * width:
        return "box too small"
    margin = POINT_MARGIN * width
    if not (box["x1"] - margin <= px <= box["x2"] + margin and box["y1"] - margin <= py <= box["y2"] + margin):
        return "point outside box"
    return ""


def generic_phrase(target: str) -> str:
    words = target.lower()
    if "knob" in words or "dial" in words:
        return "knob"
    if "button" in words or "key" in words or "pad" in words:
        return "button"
    return words.split()[-1]


def nearest(boxes: list[dict], px: int, py: int, width: int, height: int) -> dict | None:
    """The box whose edge is closest to the point (0 when the point is inside), ties broken by size."""
    def distance(box):
        dx = max(box["x1"] - px, 0, px - box["x2"])
        dy = max(box["y1"] - py, 0, py - box["y2"])
        return math.hypot(dx, dy), (box["x2"] - box["x1"]) * (box["y2"] - box["y1"])
    usable = [box for box in boxes if box["c"] >= MIN_CONFIDENCE / 2 and not weak_reason(box, box["x1"], box["y1"], width, height)]
    return min(usable, key=distance, default=None)


def locate(image: str, key: str, step: dict, px: int, py: int, width: int, height: int, timings: dict,
           served: list, label: str) -> dict:
    """Find the control at Spark's point: SAM point prompt first, then the nearest-box fallback."""
    boxes, seconds, model = sam(image, f"<0f>1<|point;x={px};y={py};w={width};h={height}|>", key)
    timings[f"{label}_sam_point"] = seconds
    served.append(model)
    found = {"point_box": boxes[0] if boxes else None}
    found["point_weak"] = weak_reason(found["point_box"], px, py, width, height)
    if not found["point_weak"]:
        found.update(final=found["point_box"], method="point")
        return found
    candidates = []
    for phrase in dict.fromkeys([generic_phrase(step["target_phrase"]), step["target_phrase"]]):
        boxes, seconds, model = sam(image, phrase, key)
        timings[f"{label}_sam_{phrase.replace(' ', '_')}"] = seconds
        served.append(model)
        candidates += boxes
    found["candidates"] = candidates
    best = nearest(candidates, px, py, width, height)
    found.update(final=best, method="fallback" if best else "none")
    if best:
        found["fallback_weak"] = weak_reason(best, px, py, width, height)
    return found


def run_case(case: dict, key: str, effort: str) -> dict:
    path = prepared_photo(case["image"])
    width, height = image_size(path)
    image = data_url(path)
    timings, served = {}, []
    result = {"image": case["image"], "question": case["question"], "width": width, "height": height,
              "timings": timings, "served": served}

    text, timings["spark_plan"], model = spark(
        [{"type": "text", "text": PLAN_PROMPT.format(question=case["question"])},
         {"type": "image_url", "image_url": {"url": image}}], key, effort, PLAN_SCHEMA)
    result["plan"] = json.loads(text)
    served.append(model)
    steps = result["plan"]["steps"]
    if not steps:
        return result

    names = [step["target_phrase"] for step in steps] + [s["set_to_label"] for s in steps if s["set_to_label"]]
    text, timings["spark_ground"], model = spark(
        [{"type": "text", "text": GROUND_PROMPT.format(names=", ".join(f'"{n}"' for n in dict.fromkeys(names)))},
         {"type": "image_url", "image_url": {"url": image}}], key, effort)
    served.append(model)
    result["ground"] = parse_json(text) or []
    grounded = {item.get("object_name"): item for item in result["ground"] if isinstance(item, dict)}

    for index, step in enumerate(steps):
        point = grounded.get(step["target_phrase"]) or {"x": step["x"], "y": step["y"]}
        step["ground_px"] = to_px(point, width, height)
        step["located"] = locate(image, key, step, *step["ground_px"], width, height, timings, served, f"s{index}")
        if step["set_to_label"] and step["set_to_label"] in grounded:
            step["set_to_px"] = to_px(grounded[step["set_to_label"]], width, height)
    return result


def overlay(result: dict) -> str:
    w, h = result["width"], result["height"]

    def pct(value, total):
        return f"{100 * value / total:.2f}%"

    def box_div(box, css, text):
        return (f'<div class="box {css}" style="left:{pct(box["x1"], w)};top:{pct(box["y1"], h)};'
                f'width:{pct(box["x2"] - box["x1"], w)};height:{pct(box["y2"] - box["y1"], h)}"><span>{text}</span></div>')

    marks, rows = [], []
    for index, step in enumerate(result["plan"]["steps"]):
        n = index + 1
        found = step.get("located", {})
        gx, gy = step["ground_px"]
        marks.append(f'<div class="dot ground" style="left:{pct(gx, w)};top:{pct(gy, h)}">{n}</div>')
        if found.get("point_weak") and found.get("point_box"):
            marks.append(box_div(found["point_box"], "rejected", f'{n}: {found["point_box"]["c"]:.2f} rejected'))
        if found.get("final"):
            marks.append(box_div(found["final"], found["method"], f'{n}: {found["final"]["c"]:.2f} {found["method"]}'))
        if "set_to_px" in step:
            sx, sy = step["set_to_px"]
            marks.append(f'<div class="dot setto" style="left:{pct(sx, w)};top:{pct(sy, h)}">{n}</div>')
        status = found.get("method", "-")
        if found.get("point_weak"):
            status += f" (point prompt rejected: {found['point_weak']})"
        set_to = f", turn to <code>{html.escape(step['set_to_label'])}</code>" if step["set_to_label"] else ""
        rows.append(f"<li><b>{html.escape(step['instruction'])}</b> - target "
                    f"<code>{html.escape(step['target_phrase'])}</code>{set_to} - {html.escape(status)}</li>")
    plan = result["plan"]
    timings = ", ".join(f"{name} {value}s" for name, value in result["timings"].items())
    return f"""<section><h2>{html.escape(result['question'])}</h2>
<p>{html.escape(plan['device_type'])} · {html.escape(plan['brand_or_model_seen'])} · safe: {plan['safe_to_guide']}
{(' · ' + html.escape(plan['safety_note'])) if plan['safety_note'] else ''}</p>
<div class="frame"><img src="{data_url(prepared_photo(result['image']))}">{''.join(marks)}</div>
<ol>{''.join(rows)}</ol><p class="muted">Uncertainty: {html.escape(plan['uncertainty']) or 'none'}<br>
Timings: {timings} (total {sum(result['timings'].values()):.1f}s)<br>Served: {', '.join(sorted(set(result['served'])))}</p></section>"""


STYLE = """body{font:14px -apple-system,sans-serif;margin:16px;max-width:1000px}.frame{position:relative;display:inline-block;max-width:100%}
.frame img{max-width:100%;display:block}.dot{position:absolute;width:22px;height:22px;margin:-11px 0 0 -11px;border-radius:50%;
color:#fff;font:bold 12px sans-serif;display:flex;align-items:center;justify-content:center;border:2px solid #fff}
.ground{background:#e80}.setto{background:#83c}.box{position:absolute;border:3px solid}.box span{position:absolute;top:-18px;left:0;
font:bold 11px sans-serif;padding:0 3px;color:#fff;white-space:nowrap}.point{border-color:#1a3}.point span{background:#1a3}
.fallback{border-color:#26f}.fallback span{background:#26f}.rejected{border-color:#d33;border-style:dashed}
.rejected span{background:#d33;top:auto;bottom:-18px}.muted{color:#666}"""
LEGEND = ("<p>Orange dot: Spark's point for the control · Purple dot: the dial label to turn to · "
          "Green box: SAM from Spark's point · Red dashed box: point result rejected · "
          "Blue box: fallback (nearest generic match)</p>")


def main():
    cases = json.loads((PHOTOS / "cases.json").read_text())
    only = set(sys.argv[1:])
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "results.json"
    results = {r["image"] + "|" + r["question"]: r for r in (json.loads(path.read_text()) if path.exists() else [])}
    to_run = [case for case in cases if not only or case["image"] in only]
    key = api_key() if to_run else ""
    for case in to_run:
        print("running", case["image"], "-", case["question"], flush=True)
        result = run_case(case, key, "low")
        results[case["image"] + "|" + case["question"]] = result
    path.write_text(json.dumps(list(results.values()), ensure_ascii=False, indent=1))
    (OUT / "report.html").write_text(f"<!doctype html><meta charset=utf-8><title>SAM button test</title>"
                                     f"<style>{STYLE}</style>{LEGEND}" + "".join(overlay(r) for r in results.values()))
    print("wrote", OUT / "report.html", "(inline styles: open the file directly, not through the Nova server)")


if __name__ == "__main__":
    main()
