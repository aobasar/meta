"""Step verification test: can Muse Spark tell from one photo whether a step was done right?

Reads test-photos/verify_cases.json:
  [{"image": "<file in test-photos/>", "instruction": "...", "success": "<what is visible when it is done>",
    "expected": "done" | "not_done"}]
For each photo, asks Spark for done / not_done / unsure plus what it observed and a correction, with the same
prompt the iPhone app uses (web-prototype/guide.py, VERIFY_PROMPT), then prints a
table and the share of correct answers ("unsure" counts as safe but not correct). Photos are resized and stripped
of metadata first (see sam_test.prepared_photo). Standard model IDs only (HACKATHON.md rule 1).
Usage: python3 verify_test.py [--effort low|medium]
"""
import argparse
import contextvars
import json
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import sam_test as st

sys.path.insert(0, str(st.REPO / "web-prototype"))
import guide  # noqa: E402  the app's own verify prompt, so this test measures what the app sends


def check(case: dict, key: str) -> dict:
    image = st.prepared_photo(case["image"]).read_bytes()
    result = guide.verify(image, case["instruction"], case["success"], "Turkish", key, urllib.request.urlopen)
    return {**case, **result, "served": ",".join(result["served"]) or "-"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--effort", default="low")
    parser.add_argument("--cases", default="verify_cases.json", help="case file in test-photos/")
    args = parser.parse_args()
    cases = json.loads((st.PHOTOS / args.cases).read_text())
    key = st.api_key()
    # The route, not the constant, sets the effort; a ContextVar default also reaches the worker threads.
    guide.SPARK_ROUTE = contextvars.ContextVar("spark_route", default=guide.SparkRoute(effort=args.effort))
    for name in dict.fromkeys(case["image"] for case in cases):
        st.prepared_photo(name)  # once per photo, before the parallel checks share it
    with ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(lambda case: check(case, key), cases))

    correct = sum(r["status"] == r["expected"] for r in results)
    wrong = sum(r["status"] not in (r["expected"], "unsure") for r in results)
    for r in results:
        mark = "OK " if r["status"] == r["expected"] else ("?? " if r["status"] == "unsure" else "XX ")
        print(f"{mark} {r['image']:<22} {r.get('check', ''):<16} expected {r['expected']:<8} got {r['status']:<8} {r['seconds']:>5}s | "
              f"{r['observed']}" + (f" | fix: {r['correction']}" if r["correction"] else "")
              + (f" | said: {r['confirmation']}" if r.get("confirmation") else ""))
    print(f"\ncorrect {correct}/{len(results)}, wrong {wrong}, unsure {len(results) - correct - wrong}; "
          f"effort {args.effort}; served {sorted({r['served'] for r in results})}")
    st.OUT.mkdir(parents=True, exist_ok=True)
    (st.OUT / f"verify_results_{args.effort}_{args.cases}").write_text(json.dumps(results, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
