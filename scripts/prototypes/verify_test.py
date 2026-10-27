"""Step verification test: can Muse Spark tell from one photo whether a step was done right?

Reads test-photos/verify_cases.json:
  [{"image": "<file in test-photos/>", "instruction": "...", "success": "<what is visible when it is done>",
    "expected": "done" | "not_done"}]
For each photo, asks Spark for done / not_done / unsure plus what it observed and a correction, then prints a
table and the share of correct answers ("unsure" counts as safe but not correct). Photos are resized and stripped
of metadata first (see sam_test.prepared_photo). Standard model IDs only (HACKATHON.md rule 1).
Usage: python3 verify_test.py [--effort low|medium]
"""
import argparse
import json
from concurrent.futures import ThreadPoolExecutor

import sam_test as st

VERIFY_SCHEMA = {
    "type": "json_schema",
    "json_schema": {
        "name": "step_check",
        "schema": {
            "type": "object",
            "properties": {
                "status": {"type": "string", "enum": ["done", "not_done", "unsure"]},
                "observed": {"type": "string"},
                "correction": {"type": "string"},
            },
            "required": ["status", "observed", "correction"],
            "additionalProperties": False,
        },
    },
}

VERIFY_PROMPT = """You check one step of a task on the device in this photo.
Step the person was asked to do: "{instruction}"
It is done when: {success}
Look closely at the relevant control or display and report:
- status: "done" if the photo clearly shows the success condition, "not_done" if it clearly does not,
  "unsure" if the control or display is not visible or readable enough to tell.
- observed: what you actually see on that control or display (for example the label the knob points to, or the
  digits on the display), in English.
- correction: if not_done, one short sentence telling the person what to change, in Turkish; otherwise "".
Do not guess. Prefer "unsure" over a wrong answer."""


def check(case: dict, key: str, effort: str) -> dict:
    image = st.data_url(st.prepared_photo(case["image"]))
    text, seconds, model = st.spark(
        [{"type": "text", "text": VERIFY_PROMPT.format(instruction=case["instruction"], success=case["success"])},
         {"type": "image_url", "image_url": {"url": image}}], key, effort, VERIFY_SCHEMA)
    return {**case, **json.loads(text), "seconds": seconds, "served": model}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--effort", default="low")
    parser.add_argument("--cases", default="verify_cases.json", help="case file in test-photos/")
    args = parser.parse_args()
    cases = json.loads((st.PHOTOS / args.cases).read_text())
    key = st.api_key()
    for name in dict.fromkeys(case["image"] for case in cases):
        st.prepared_photo(name)  # once per photo, before the parallel checks share it
    with ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(lambda case: check(case, key, args.effort), cases))

    correct = sum(r["status"] == r["expected"] for r in results)
    wrong = sum(r["status"] not in (r["expected"], "unsure") for r in results)
    for r in results:
        mark = "OK " if r["status"] == r["expected"] else ("?? " if r["status"] == "unsure" else "XX ")
        print(f"{mark} {r['image']:<22} {r.get('check', ''):<16} expected {r['expected']:<8} got {r['status']:<8} {r['seconds']:>5}s | "
              f"{r['observed']}" + (f" | fix: {r['correction']}" if r["correction"] else ""))
    print(f"\ncorrect {correct}/{len(results)}, wrong {wrong}, unsure {len(results) - correct - wrong}; "
          f"effort {args.effort}; served {sorted({r['served'] for r in results})}")
    st.OUT.mkdir(parents=True, exist_ok=True)
    (st.OUT / f"verify_results_{args.effort}_{args.cases}").write_text(json.dumps(results, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
