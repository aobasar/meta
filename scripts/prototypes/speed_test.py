"""Replay recorded Göster bana requests with other Spark settings and time them (speed plan, stage 2).

Uses the maintainer's own recordings in web-prototype/data/recordings (git-ignored, made with recording mode) and
writes web-prototype/data/speed-tests/<time>/results.json and compare.html (git-ignored too). Production settings
are not changed: each configuration only rewrites the Spark chat calls made by this script. SAM stays on Meta.

    python3 scripts/prototypes/speed_test.py --configs meta-low,meta-minimal
    python3 scripts/prototypes/speed_test.py --configs meta-low,baseten --limit 3
    python3 scripts/prototypes/speed_test.py --page web-prototype/data/speed-tests/<time>   # rebuild the page

Configurations:
    meta-low      Meta Model API, muse-spark-1.3, reasoning_effort "low"
    meta-minimal  the same with reasoning_effort "minimal" (what the app uses since 2026-10-29)
    baseten          Baseten Model APIs, meta-models/muse-spark-open-1026 (open weights, a pinned version), the
                     provider's default reasoning
    baseten-minimal  the same with reasoning_effort "minimal"
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import statistics
import sys
import time
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "web-prototype"))

import guide  # noqa: E402
import server as nova  # noqa: E402

RECORDINGS = ROOT / "web-prototype" / "data" / "recordings"
RESULTS = ROOT / "web-prototype" / "data" / "speed-tests"
ENV_FILE = ROOT / ".env.local"
BASETEN_BASE = "https://inference.baseten.co/v1"


@dataclass(frozen=True)
class Config:
    name: str
    effort: str | None  # None: leave reasoning_effort out
    base: str | None = None  # None: Meta, unchanged
    model: str | None = None
    key_name: str | None = None


CONFIGS = {
    "meta-low": Config("meta-low", "low"),
    "meta-minimal": Config("meta-minimal", "minimal"),
    "baseten": Config("baseten", None, BASETEN_BASE, "meta-models/muse-spark-open-1026", "BASETEN_API_KEY"),
    "baseten-minimal": Config("baseten-minimal", "minimal", BASETEN_BASE, "meta-models/muse-spark-open-1026",
                              "BASETEN_API_KEY"),
}


class Rerouted:
    """An opener that rewrites Spark chat calls for one configuration; every other call goes out unchanged."""

    def __init__(self, config: Config, key: str | None):
        self.config, self.key = config, key

    def __call__(self, request, timeout=None):
        if request.full_url.endswith("/chat/completions"):
            body = json.loads(request.data)
            body.pop("reasoning_effort", None)
            if self.config.effort:
                body["reasoning_effort"] = self.config.effort
            if self.config.base:
                body["model"] = self.config.model
                request = urllib.request.Request(
                    f"{self.config.base}/chat/completions", data=json.dumps(body).encode(), method="POST",
                    headers={"Authorization": f"Api-Key {self.key}", "Content-Type": "application/json"})
            else:
                request.data = json.dumps(body).encode()
        return urllib.request.urlopen(request, timeout=timeout)


def spark_tokens(calls: list[dict]) -> dict:
    out = reasoning = 0
    for call in calls:
        usage = call.get("usage") or {}
        if call.get("model") == guide.SAM_MODEL:
            continue
        out += usage.get("completion_tokens") or usage.get("output_tokens") or 0
        details = usage.get("completion_tokens_details") or usage.get("output_tokens_details") or {}
        reasoning += details.get("reasoning_tokens") or 0
    return {"output": out, "reasoning": reasoning}


def run_plan(folder: Path, api_key: str, opener) -> dict:
    request = json.loads((folder / "request.json").read_text())
    frame = (folder / "frame.jpg").read_bytes()
    calls: list = []
    token = guide.CALLS.set(calls)
    started = time.monotonic()
    first = None
    try:
        for result in guide.plan_parts(frame, request["question"], request.get("language", "English"), api_key, opener,
                                       request.get("autoLanguage") is True):
            first = first if first is not None else round(time.monotonic() - started, 2)
    finally:
        guide.CALLS.reset(token)
    return {"first": first, "total": round(time.monotonic() - started, 2), "tokens": spark_tokens(calls),
            "served": result["served"], "device": result["device"], "safe": result["safe"],
            "uncertainty": result["uncertainty"], "timings": result["timings"],
            "steps": [{key: step[key] for key in ("instruction", "target", "point", "box", "boxMethod", "setTo")}
                      for step in result["steps"]]}


def run_verify(folder: Path, api_key: str, opener) -> dict:
    request = json.loads((folder / "request.json").read_text())
    crop = (folder / "frame.jpg").read_bytes()
    calls: list = []
    token = guide.CALLS.set(calls)
    started = time.monotonic()
    try:
        result = guide.verify(crop, request["instruction"], request["success"], request.get("language", "English"),
                              api_key, opener)
    finally:
        guide.CALLS.reset(token)
    return {"total": round(time.monotonic() - started, 2), "tokens": spark_tokens(calls), "status": result["status"],
            "observed": result["observed"], "correction": result["correction"]}


def run(configs: list[Config], limit: int | None, kinds: list[str]) -> Path:
    api_key = nova.load_api_key(ENV_FILE)
    openers = {}
    for config in configs:
        key = guide.env_value(ENV_FILE, config.key_name) if config.key_name else None
        if config.key_name and not key:
            sys.exit(f"{config.key_name} is not set in .env.local.")
        openers[config.name] = Rerouted(config, key)
    secrets = [api_key] + [opener.key for opener in openers.values() if opener.key]

    out = RESULTS / datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True)
    results: dict = {"configs": [config.name for config in configs], "plan": [], "verify": []}
    for kind in kinds:
        folders = sorted(RECORDINGS.glob(f"*-{kind}"))[:limit]
        for number, folder in enumerate(folders, 1):
            request = json.loads((folder / "request.json").read_text())
            item = {"recording": folder.name, "request": {k: v for k, v in request.items() if k != "camera"},
                    "original": json.loads((folder / "response.json").read_text()) if kind == "verify" else None,
                    "runs": {}}
            # Configurations alternate per recording, so a slow minute on Meta's side hits all of them alike.
            for config in configs:
                try:
                    runner = run_plan if kind == "plan" else run_verify
                    item["runs"][config.name] = runner(folder, api_key, openers[config.name])
                except nova.UpstreamError as exc:
                    message = exc.message
                    for secret in secrets:
                        message = message.replace(secret, "[key]")
                    item["runs"][config.name] = {"error": f"{exc.status} {message}"}
                run = item["runs"][config.name]
                print(f"{kind} {number}/{len(folders)} {config.name:<13} "
                      + (run["error"] if "error" in run else f"{run.get('first') or '':>6} {run['total']:>6} s"),
                      flush=True)
            results[kind].append(item)
            (out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1))
    page(out)
    return out


# ---------------------------------------------------------------------------
# The comparison page (local file; frames are embedded, nothing is uploaded)

COLORS = ["#d97706", "#2563eb", "#059669", "#db2777"]


def spread(values: list[float]) -> str:
    if not values:
        return "–"
    values = sorted(values)
    return f"{statistics.median(values):.1f} / {values[min(len(values) - 1, int(len(values) * 0.9))]:.1f}"


def marker(step: dict) -> dict:
    box = step.get("box")
    if box and step.get("boxMethod") in ("point", "fallback"):
        return {"x": (box["x1"] + box["x2"]) / 2, "y": (box["y1"] + box["y2"]) / 2}
    return step["point"]


def page(folder: Path) -> Path:
    results = json.loads((folder / "results.json").read_text())
    configs = results["configs"]
    color = {name: COLORS[i % len(COLORS)] for i, name in enumerate(configs)}
    esc = html.escape

    rows = []
    for name in configs:
        plans = [item["runs"].get(name, {}) for item in results["plan"]]
        checks = [item["runs"].get(name, {}) for item in results["verify"]]
        ok_plans = [run for run in plans if "error" not in run]
        ok_checks = [run for run in checks if "error" not in run]
        agree = sum(1 for item in results["verify"]
                    if (item["runs"].get(name) or {}).get("status") == (item["original"] or {}).get("status"))
        tokens = [run["tokens"]["output"] for run in ok_plans]
        rows.append(f"<tr><td><span class=dot style='background:{color[name]}'></span>{esc(name)}</td>"
                    f"<td>{spread([run['first'] for run in ok_plans if run.get('first')])}</td>"
                    f"<td>{spread([run['total'] for run in ok_plans])}</td>"
                    f"<td>{spread([run['total'] for run in ok_checks])}</td>"
                    f"<td>{round(statistics.mean(tokens)) if tokens else '–'}</td>"
                    f"<td>{len(plans) - len(ok_plans) + len(checks) - len(ok_checks)}</td>"
                    f"<td>{agree} / {len(checks)}</td></tr>")

    cards = []
    for item in results["plan"]:
        frame = (RECORDINGS / item["recording"] / "frame.jpg").read_bytes()
        dots, columns = [], []
        width, height = guide.jpeg_size(frame)
        for name in configs:
            run = item["runs"].get(name, {})
            if "error" in run:
                columns.append(f"<div class=col><h4 style='color:{color[name]}'>{esc(name)}</h4>"
                               f"<p class=err>{esc(run['error'])}</p></div>")
                continue
            for number, step in enumerate(run["steps"], 1):
                point = marker(step)
                dots.append(f"<g transform='translate({point['x']:.4f},{point['y'] * height / width:.4f})'>"
                            f"<circle r='.022' fill='{color[name]}' fill-opacity='.85' stroke='#fff' stroke-width='.004'/>"
                            f"<text y='.009' font-size='.026' text-anchor='middle' fill='#fff'"
                            f" font-weight='700'>{number}</text></g>")
            steps = "".join(f"<li>{esc(step['instruction'])} <small>{esc(step['boxMethod'])}</small></li>"
                            for step in run["steps"])
            device = " · ".join(part for part in (run["device"].get("brand"), run["device"].get("type")) if part)
            note = "" if run["safe"] else f"<p class=err>Refused: {esc(run.get('uncertainty', ''))}</p>"
            columns.append(f"<div class=col><h4 style='color:{color[name]}'>{esc(name)}</h4>"
                           f"<p class=meta>{run['first']} s to the steps · {run['total']} s in all · "
                           f"{run['tokens']['output']} tokens · {esc(device)}</p>{note}<ol>{steps}</ol></div>")
        image = base64.b64encode(frame).decode()
        cards.append(
            f"<section><h3>{esc(item['request'].get('question', ''))}</h3>"
            f"<div class=pair><div class=photo style='aspect-ratio:{width}/{height}'>"
            f"<img src='data:image/jpeg;base64,{image}' alt=''>"
            f"<svg viewBox='0 0 1 {height / width:.4f}'>{''.join(dots)}</svg></div>"
            f"<div class=cols>{''.join(columns)}</div></div>"
            f"<p class=rate>Which is accurate enough? "
            + "".join(f"<label><input type=checkbox> {esc(name)}</label>" for name in configs) + "</p></section>")

    checks = []
    for item in results["verify"]:
        cells = "".join(
            f"<td>{esc((item['runs'].get(name) or {}).get('status') or (item['runs'].get(name) or {}).get('error', ''))}"
            f" <small>{(item['runs'].get(name) or {}).get('total', '')} s</small></td>" for name in configs)
        checks.append(f"<tr><td>{esc(item['request'].get('instruction', ''))}</td>"
                      f"<td>{esc((item['original'] or {}).get('status', ''))}</td>{cells}</tr>")

    document = f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Spark speed test</title><style>
:root{{--bg:#fafaf9;--card:#fff;--ink:#1c1917;--muted:#78716c;--line:#e7e5e4;--err:#b91c1c}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1c1917;--card:#292524;--ink:#f5f5f4;--muted:#a8a29e;--line:#44403c;--err:#f87171}}}}
body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,system-ui,sans-serif}}
main{{max-width:1180px;margin:0 auto;padding:24px 16px 64px}}
h1{{font-size:22px;margin:0 0 4px}} h3{{font-size:16px;margin:0 0 12px}} h4{{margin:0 0 4px;font-size:14px}}
p.lead,.meta,small{{color:var(--muted)}} .meta{{font-size:13px;margin:0 0 6px}}
table{{border-collapse:collapse;width:100%;background:var(--card);margin:12px 0 28px}}
td,th{{border-bottom:1px solid var(--line);padding:8px 10px;text-align:left;vertical-align:top;font-size:14px}}
th{{font-weight:600;color:var(--muted)}}
.dot{{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:8px}}
section{{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin:0 0 16px}}
.pair{{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.3fr);gap:16px}}
@media (max-width:760px){{.pair{{grid-template-columns:1fr}}}}
.photo{{position:relative;width:100%}} .photo img,.photo svg{{position:absolute;inset:0;width:100%;height:100%;border-radius:8px}}
.cols{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}}
ol{{margin:0;padding-left:20px;font-size:14px}} li{{margin-bottom:4px}} .err{{color:var(--err);font-size:13px}}
.rate{{margin:12px 0 0;font-size:14px}} .rate label{{margin-left:12px}}
</style></head><body><main>
<h1>Spark speed test</h1>
<p class=lead>{len(results['plan'])} recorded plans and {len(results['verify'])} recorded checks, replayed with each
configuration. Seconds are median / slowest 10%. Dots are where each configuration puts the marker.
Frames stay on this Mac: this page is a local file.</p>
<table><tr><th>Configuration</th><th>Plan: to the steps</th><th>Plan: in all</th><th>Check</th>
<th>Plan output tokens (mean)</th><th>Errors</th><th>Check agrees with the recording</th></tr>{''.join(rows)}</table>
{''.join(cards)}
<h3>Step checks</h3>
<table><tr><th>Step</th><th>Recorded</th>{''.join(f'<th>{esc(name)}</th>' for name in configs)}</tr>{''.join(checks)}</table>
</main></body></html>"""
    path = folder / "compare.html"
    path.write_text(document)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--configs", default="meta-low,meta-minimal",
                        help="comma-separated: " + ", ".join(CONFIGS))
    parser.add_argument("--limit", type=int, help="only the first N recordings of each kind")
    parser.add_argument("--kinds", default="plan,verify")
    parser.add_argument("--page", type=Path, help="rebuild compare.html for an earlier run folder and stop")
    args = parser.parse_args()
    if args.page:
        print(page(args.page.resolve()))
        return
    unknown = [name for name in args.configs.split(",") if name not in CONFIGS]
    if unknown:
        parser.error(f"unknown configuration: {', '.join(unknown)}")
    out = run([CONFIGS[name] for name in args.configs.split(",")], args.limit, args.kinds.split(","))
    print(out / "compare.html")


if __name__ == "__main__":
    main()
