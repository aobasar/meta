"""Video prototype of "Göster bana": the whole AI chain on a phone video, without the iPhone app.

  video ──ffmpeg──> 10 fps 720p clip + 24 kHz mono WAV
  WAV ──Muse Voice Transcribe──> the spoken question
  sharpest frame ──Muse Spark──> device, safety, steps (target + dial label), translated panel labels
  Spark points ──SAM 3.1 point prompts──> verified control boxes on the key frame (with the photo fallback)
  boxes + label points ──SAM 3.1 video tracking──> per-frame boxes for every target and label
  ──> player.html (video + spotlight, arrows, translated labels, steps read aloud by the browser voice)

Usage: python3 video_proto.py <video> [--question "..."] [--lang Turkish] [--out NAME]
Output goes to the Nova server's git-ignored reports folder: http://127.0.0.1:9005/reports/NAME/player.html
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import sam_test as st

REPORTS = st.REPO / "web-prototype" / "static" / "reports"  # git-ignored; served by the Nova server
TRANSCRIBE_MODEL = "muse-voice-transcribe-1.0"
FPS = 10
HEIGHT = 720
MAX_LABELS = 6

PLAN_PROMPT = st.PLAN_PROMPT.replace("(at most 4)", "(at most 6), in the order the person does them") + """
5. labels: the printed panel labels the person needs for these steps (at most {max_labels}), each with
   text (exactly as printed), translation (into {lang}), meaning (one short sentence in {lang} that explains
   what the setting does, not just the words), and x, y on the same 0-1000 grid. Skip brand and model names.
Write every instruction in {lang}."""

PLAN_SCHEMA = json.loads(json.dumps(st.PLAN_SCHEMA))
_props = PLAN_SCHEMA["json_schema"]["schema"]["properties"]
_props["labels"] = {"type": "array", "items": {
    "type": "object",
    "properties": {"text": {"type": "string"}, "translation": {"type": "string"}, "meaning": {"type": "string"},
                   "x": {"type": "integer"}, "y": {"type": "integer"}},
    "required": ["text", "translation", "meaning", "x", "y"], "additionalProperties": False}}
PLAN_SCHEMA["json_schema"]["schema"]["required"].append("labels")


def run(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def prepare(video: Path, out: Path) -> dict:
    """Normalize the clip (rotation applied, 10 fps, 720p, no audio) and pull the audio as 24 kHz mono WAV."""
    clip, wav = out / "clip.mp4", out / "question.wav"
    run("ffmpeg", "-y", "-loglevel", "error", "-i", str(video), "-vf", f"fps={FPS},scale=-2:{HEIGHT}",
        "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(clip))
    has_audio = bool(run("ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                         "-of", "csv=p=0", str(video)).strip())
    if has_audio:
        run("ffmpeg", "-y", "-loglevel", "error", "-i", str(video), "-vn", "-ac", "1", "-ar", "24000",
            "-c:a", "pcm_s16le", str(wav))
    info = json.loads(run("ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
                          "stream=width,height,nb_read_frames", "-of", "json", str(clip)))["streams"][0]
    return {"clip": clip, "wav": wav if has_audio else None, "width": int(info["width"]),
            "height": int(info["height"]), "frames": int(info["nb_read_frames"])}


PICK_PROMPT = """These {count} numbered tiles are frames from one phone video of a device, numbered 1 to {count}
from left to right, top to bottom. Which tile shows the device's whole control panel most completely, sharply and
straight-on? Answer with JSON: {{"tile": <number>}}."""


def candidate_frames(clip: Path, frames: int, count: int = 6) -> list[int]:
    """The least blurry frame (ffmpeg blurdetect) in each of `count` equal parts of the clip."""
    log = subprocess.run(["ffmpeg", "-i", str(clip), "-vf", "blurdetect=block_width=32:block_height=32,"
                          "metadata=print:file=-", "-f", "null", "-"], capture_output=True, text=True).stdout
    scores = {int(f): float(b) for f, b in re.findall(r"frame:(\d+).*?\n.*?lavfi\.blur=([\d.]+)", log)}
    picks = []
    for part in range(count):
        window = [f for f in scores if part * frames / count <= f < (part + 1) * frames / count]
        if window:
            picks.append(min(window, key=scores.get))
    return picks or [frames // 2]


def pick_key_frame(clip: Path, frames: int, out: Path, key: str, timings: dict, served: list) -> int:
    """Let Muse Spark pick, from a contact sheet of sharp candidates, the frame that shows the whole panel."""
    picks = candidate_frames(clip, frames)
    select = "+".join(f"eq(n\\,{f})" for f in picks)
    sheet = out / "candidates.jpg"
    run("ffmpeg", "-y", "-loglevel", "error", "-i", str(clip), "-vf",
        f"select='{select}',scale=480:-2,tile=3x{(len(picks) + 2) // 3}", "-frames:v", "1", "-q:v", "3", str(sheet))
    text, timings["spark_pick_frame"], model = st.spark(
        [{"type": "text", "text": PICK_PROMPT.format(count=len(picks))},
         {"type": "image_url", "image_url": {"url": st.data_url(sheet)}}], key, "low")
    served.append(model)
    tile = (st.parse_json(text) or {}).get("tile", 1)
    return picks[min(max(int(tile), 1), len(picks)) - 1], picks


BOX_PROMPT = ('You are an object grounding expert. Provide the bounding box coordinates of the objects in the image: '
              '{names}. Ensure the objects accurately match the request and do not miss any objects. For each object, '
              'answer in the format {{"object_name": "<name>", "bbox": [{{"x_min": <int>, "y_min": <int>, "x_max": <int>, '
              '"y_max": <int>}}]}}. The coordinates should be in the 0-1000 range. Return a JSON array of results. '
              'If you cannot find an object, omit it from the results.')


def ground_boxes(names: dict[str, str], image: str, key: str, width: int, height: int) -> tuple[dict, float, str]:
    """Muse Spark box grounding. names maps the phrase sent to the model -> our key.
    Returns ({key: {x1, y1, x2, y2}} in pixels, seconds, served model)."""
    if not names:
        return {}, 0.0, st.SPARK
    text, seconds, model = st.spark(
        [{"type": "text", "text": BOX_PROMPT.format(names=", ".join(f"'{n}'" for n in names))},
         {"type": "image_url", "image_url": {"url": image}}], key, "low")
    boxes = {}
    for item in st.parse_json(text) or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("object_name", ""))
        found = names.get(name) or next((k for n, k in names.items() if n in name or name in n), None)
        bbox = (item.get("bbox") or [None])[0]
        if found and bbox and bbox["x_max"] > bbox["x_min"] and bbox["y_max"] > bbox["y_min"]:
            boxes[found] = {"x1": round(bbox["x_min"] * width / 1000), "y1": round(bbox["y_min"] * height / 1000),
                            "x2": round(bbox["x_max"] * width / 1000), "y2": round(bbox["y_max"] * height / 1000)}
    return boxes, seconds, model


def printed_names(texts: list[str]) -> dict[str, str]:
    return {f'the printed text "{t}"': t for t in texts}


def frame_jpeg(clip: Path, index: int, path: Path) -> Path:
    run("ffmpeg", "-y", "-loglevel", "error", "-i", str(clip), "-vf", f"select=eq(n\\,{index})",
        "-frames:v", "1", "-q:v", "2", str(path))
    return path


def transcribe(wav: Path, key: str, languages: list[str]) -> tuple[str, float]:
    boundary = f"nova-{uuid.uuid4().hex}"
    settings = {"model": TRANSCRIBE_MODEL, "audioEncoding": "WAV", "mode": "PUSH_TO_TALK", "languageBias": languages}
    parts = [("request", None, "application/json", json.dumps(settings).encode()),
             ("audio", "question.wav", "audio/wav", wav.read_bytes())]
    body = b""
    for name, filename, content_type, data in parts:
        disposition = f'form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        body += (f"--{boundary}\r\nContent-Disposition: {disposition}\r\nContent-Type: {content_type}\r\n\r\n"
                 .encode() + data + b"\r\n")
    body += f"--{boundary}--\r\n".encode()
    request = urllib.request.Request(f"{st.API_BASE}/asr/transcribe", data=body, method="POST", headers={
        "Authorization": f"Bearer {key}", "Accept": "application/json",
        "Content-Type": f"multipart/form-data; boundary={boundary}"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=120) as response:
        data = json.loads(response.read())
    return (data.get("transcript") or "").strip(), round(time.time() - started, 2)


def track(clip: Path, key: str, prompts: dict[int, dict[int, str]]) -> tuple[dict, float]:
    """SAM 3.1 video tracking of every prompted object, re-anchored on each prompted frame, both directions.
    prompts is {frame: {object id: prompt}}. Returns {object id: {frame: [x1, y1, x2, y2, c]}}."""
    text = "".join(f"<{frame}f>" + ",".join(f"{object_id}{prompt}" for object_id, prompt in objects.items())
                   for frame, objects in sorted(prompts.items()) if objects)
    payload = {"model": st.SAM, "metadata": {"include_confidence": "true", "mask_encoding": "one_bit",
                                             "propagation_direction": "both"},
               "input": [{"type": "message", "role": "user", "content": [
                   {"type": "input_text", "text": text},
                   {"type": "input_video", "video_url": "data:video/mp4;base64," + st.base64.b64encode(
                       clip.read_bytes()).decode()}]}]}
    data, seconds = st.post("responses", payload, key, timeout=600)
    output = data.get("output_text") or "".join(
        part.get("text", "") for item in data.get("output", []) for part in item.get("content", []) or []
        if part.get("type") == "output_text")
    tracks: dict[int, dict[int, list]] = {}
    for frame, line in re.findall(r"<(\d+)f>(.*?)(?=<\d+f>|$)", output, re.S):
        for object_id, fields in re.findall(r"(\d+)<\|box;([^|]*)\|>", line):
            values = dict(field.split("=", 1) for field in fields.split(";"))
            tracks.setdefault(int(object_id), {})[int(frame)] = [
                int(values["x1"]), int(values["y1"]), int(values["x2"]), int(values["y2"]), float(values.get("c", 1))]
    return tracks, seconds


def point_prompt(px: int, py: int, width: int, height: int) -> str:
    return f"<|point;x={px};y={py};w={width};h={height}|>"


def box_prompt(box: dict, width: int, height: int) -> str:
    return f"<|box;x1={box['x1']};y1={box['y1']};x2={box['x2']};y2={box['y2']};w={width};h={height}|>"


def write_player(out: Path) -> None:
    """Split the template into player.html/.css/.js: the Nova server's CSP allows only same-origin files."""
    template = (Path(__file__).parent / "player_template.html").read_text()
    css = re.search(r"<style>(.*?)</style>", template, re.S)[1]
    js = re.search(r"<script>(.*?)</script>", template, re.S)[1]
    page = (template.replace(f"<style>{css}</style>", '<link rel="stylesheet" href="player.css">')
            .replace(f"<script>{js}</script>", '<script src="player.js"></script>'))
    (out / "player.css").write_text(css.strip() + "\n")
    (out / "player.js").write_text(js.strip() + "\n")
    (out / "player.html").write_text(page)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("--question", help="use this question instead of the video's audio")
    parser.add_argument("--lang", default="Turkish", help="language for instructions and translations")
    parser.add_argument("--out", help="report folder name (default: the video's file name)")
    args = parser.parse_args()

    out = REPORTS / (args.out or args.video.stem.lower())
    out.mkdir(parents=True, exist_ok=True)
    key = st.api_key()
    timings, served = {}, []

    media = prepare(args.video, out)
    width, height = media["width"], media["height"]
    print(f"clip {width}x{height}, {media['frames']} frames at {FPS} fps", flush=True)

    question = args.question
    if not question and media["wav"]:
        question, timings["transcribe"] = transcribe(media["wav"], key, [args.lang, "English"])
        served.append(TRANSCRIBE_MODEL)
    if not question:
        sys.exit("No question: the video has no speech; pass --question.")
    print("question:", question, flush=True)

    key_frame, candidates = pick_key_frame(media["clip"], media["frames"], out, key, timings, served)
    key_path = frame_jpeg(media["clip"], key_frame, out / "key.jpg")
    image = st.data_url(key_path)
    print("key frame:", key_frame, flush=True)

    text, timings["spark_plan"], model = st.spark(
        [{"type": "text", "text": PLAN_PROMPT.format(question=question, lang=args.lang, max_labels=MAX_LABELS)},
         {"type": "image_url", "image_url": {"url": image}}], key, "low", PLAN_SCHEMA)
    served.append(model)
    plan = json.loads(text)
    print(json.dumps(plan, ensure_ascii=False, indent=1), flush=True)

    steps, labels = plan["steps"], plan["labels"][:MAX_LABELS]
    names = list(dict.fromkeys([s["target_phrase"] for s in steps] + [s["set_to_label"] for s in steps if s["set_to_label"]]))
    grounded = {}
    if names:
        text, timings["spark_ground"], model = st.spark(
            [{"type": "text", "text": st.GROUND_PROMPT.format(names=", ".join(f'"{n}"' for n in names))},
             {"type": "image_url", "image_url": {"url": image}}], key, "low")
        served.append(model)
        grounded = {item.get("object_name"): item for item in st.parse_json(text) or [] if isinstance(item, dict)}

    texts = list(dict.fromkeys([s["set_to_label"] for s in steps if s["set_to_label"]] + [l["text"] for l in labels]))
    printed, timings["spark_text_boxes"], model = ground_boxes(printed_names(texts), image, key, width, height)
    served.append(model)

    prompts, objects, tracked = {}, [], {}  # tracked: target phrase or printed text -> SAM object id

    def object_for(name: str, prompt: str) -> int | None:
        if name not in tracked:
            if len(prompts) >= 16:  # SAM 3.1 tracks at most 16 prompted objects
                return None
            tracked[name] = len(prompts) + 1
            prompts[tracked[name]] = prompt
        return tracked[name]

    for index, step in enumerate(steps):
        if step["target_phrase"] not in tracked:
            point = grounded.get(step["target_phrase"]) or {"x": step["x"], "y": step["y"]}
            px, py = st.to_px(point, width, height)
            found = st.locate(image, key, step, px, py, width, height, timings, served, f"s{index}")
            box = found.get("final")
            step["method"] = found.get("method")
            prompt = box_prompt(box, width, height) if box else point_prompt(px, py, width, height)
        object_id = object_for(step["target_phrase"], prompt if step["target_phrase"] not in tracked else "")
        objects.append({"id": object_id, "kind": "target", "step": index})
        label = step["set_to_label"]
        if label and label in printed:
            objects.append({"id": object_for(label, box_prompt(printed[label], width, height)),
                            "kind": "set_to", "step": index, "text": label})
    for label in labels:
        if label["text"] in printed:
            objects.append({"id": object_for(label["text"], box_prompt(printed[label["text"]], width, height)),
                            "kind": "label", **{k: label[k] for k in ("text", "translation", "meaning")}})
    objects = [item for item in objects if item["id"]]

    # Re-anchor every object on the other sharp candidate frames: Spark draws boxes there, SAM fills the gaps.
    by_frame = {key_frame: prompts}
    anchor_names = {name: name for name in tracked if name not in texts} | printed_names(
        [name for name in tracked if name in texts])

    def anchor(frame: int):
        frame_image = st.data_url(frame_jpeg(media["clip"], frame, out / f"anchor_{frame}.jpg"))
        return frame, *ground_boxes(anchor_names, frame_image, key, width, height)

    with ThreadPoolExecutor(max_workers=5) as pool:
        for frame, boxes, seconds, model in pool.map(anchor, [f for f in candidates if f != key_frame]):
            timings[f"spark_anchor_{frame}"] = seconds
            served.append(model)
            by_frame[frame] = {tracked[name]: box_prompt(box, width, height) for name, box in boxes.items()
                               if (box["x2"] - box["x1"]) * (box["y2"] - box["y1"]) < 0.5 * width * height
                               or name == steps[0]["target_phrase"]}
    for path in out.glob("anchor_*.jpg"):
        path.unlink()
    print("anchors per frame:", {f: len(p) for f, p in sorted(by_frame.items())}, flush=True)

    tracks, timings["sam_track"] = track(media["clip"], key, by_frame)
    served.append(st.SAM)
    for item in objects:
        item["frames"] = tracks.get(item["id"], {})
    print("tracked:", [(o["id"], o["kind"], o.get("text") or steps[o["step"]]["target_phrase"], len(o["frames"])) for o in objects], flush=True)
    print("timings:", timings, "total", round(sum(timings.values()), 1), "s", flush=True)

    data = {"question": question, "lang": args.lang, "plan": plan, "objects": objects, "fps": FPS,
            "width": width, "height": height, "key_frame": key_frame, "frames": media["frames"],
            "timings": timings, "served": sorted(set(served))}
    (out / "result.json").write_text(json.dumps(data, ensure_ascii=False, indent=1))
    write_player(out)
    if media["wav"]:
        media["wav"].unlink()  # the question audio is not kept
    print(f"open http://127.0.0.1:9005/reports/{out.name}/player.html")


if __name__ == "__main__":
    main()
