#!/usr/bin/env python3
"""Reads recorded knob close-ups with the dial check, and scores it against positions judged by eye.

Run from web-prototype: python3 ../scripts/prototypes/dial_read_test.py <recordings folder> [runs]
The frames stay out of the repository. A small knob's reading is scored against every target: the right one should
pass, and a wrong one must not. The big program dial has no reliable truth, so it only shows where its checks go.
"""
import base64
import collections
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, ".")
import guide

TEMPERATURE = ["cool darks", "cool brights", "warm", "hot", "tap cold", "cold"]
PROGRAM = ["regular", "express", "normal", "casual", "delicate", "hand wash", "soak", "prewash", "heavy duty", "comforters/bedding"]
KNOBS = {
    "20261031-063103": "cool brights", "20261031-063112": "cool brights", "20261031-063118": "cool brights",
    "20261031-071437": "hot", "20261031-071445": "hot", "20261031-074215": "warm", "20261101-020127": "cold",
    "20261101-021300": "cold", "20261101-022122": "cool brights", "20261101-031726": "warm", "20261101-031733": "warm",
}
PROGRAM_CHECKS = {
    "20261101-040946": "casual", "20261101-040957": "casual", "20261101-041005": "casual", "20261101-041017": "casual",
    "20261101-041341": "express", "20261101-041357": "express", "20261101-041409": "express",
}


def dial(target, positions, segments=False):
    return {"target": target, "positions": positions, "aliases": [], "segments": segments, "any": False}


def main():
    folder, runs = Path(sys.argv[1]), int(sys.argv[2]) if len(sys.argv) > 2 else 3
    key = guide.nova.load_api_key(Path("../.env.local"))
    frames = {stamp: next(folder.glob(stamp + "-*-verify")) for stamp in list(KNOBS) + list(PROGRAM_CHECKS)}

    def read(job):
        stamp, target, positions, segments = job
        image = base64.b64encode((frames[stamp] / "frame.jpg").read_bytes()).decode()
        text, _ = guide.spark(guide.dial_prompt(dial(target, positions, segments)), "data:image/jpeg;base64," + image,
                              key, urllib.request.urlopen, guide.DIAL_READ_SCHEMA)
        return job, guide.parse_json(text)

    jobs = [(stamp, truth, TEMPERATURE, False) for stamp, truth in KNOBS.items() for _ in range(runs)]
    jobs += [(stamp, target, PROGRAM, True) for stamp, target in PROGRAM_CHECKS.items() for _ in range(runs)]
    with ThreadPoolExecutor(6) as pool:
        results = list(pool.map(read, jobs))

    right, wrong, programs = collections.Counter(), collections.Counter(), collections.Counter()
    program_wrong = collections.Counter()
    for (stamp, truth, positions, segments), reading in results:
        if segments:
            decision = guide.decide_dial(reading, dial(truth, positions, True))
            programs[decision] += 1
            for other in positions:
                if other != truth:
                    program_wrong[guide.decide_dial(reading, dial(other, positions, True))[0]] += 1
            print(stamp, truth, "->", decision, reading.get("position"), reading.get("pointer_clock"))
            continue
        right[guide.decide_dial(reading, dial(truth, positions))] += 1
        for other in positions:
            if other != truth:
                wrong[guide.decide_dial(reading, dial(other, positions))[0]] += 1
    report_sizes(results, frames)
    report_second_look(results)
    print("right target:", dict(right))
    print("wrong targets:", dict(wrong))
    print("program dial:", dict(programs))
    print("program dial, wrong targets:", dict(program_wrong))


def report_sizes(results, frames):
    """How often each frame reads right, by the short side of the crop."""
    scores = collections.defaultdict(collections.Counter)
    for (stamp, truth, positions, segments), reading in results:
        if not segments:
            scores[stamp][guide.plain_label(reading.get("position", "")) == truth] += 1
    for stamp in sorted(scores, key=lambda s: min(guide.jpeg_size((frames[s] / "frame.jpg").read_bytes()))):
        side = min(guide.jpeg_size((frames[stamp] / "frame.jpg").read_bytes()))
        print(f"{side:5d} px {stamp} right {scores[stamp][True]} of {sum(scores[stamp].values())}")


def report_second_look(results):
    """A not-sure first reading looks again at another frame of the same setting: must the two agree, or may a pass stand?"""
    groups = collections.defaultdict(list)
    for (stamp, truth, positions, segments), reading in results:
        if not segments:
            groups[truth].append((stamp, reading))
    same_rule, pass_rule = collections.Counter(), collections.Counter()
    wrong_same, wrong_pass = collections.Counter(), collections.Counter()
    for truth, readings in groups.items():
        pairs = [(a, b) for sa, a in readings for sb, b in readings if sa != sb]
        for first, second in pairs:
            for target, same, passed in ((t, wrong_same, wrong_pass) if t != truth else (t, same_rule, pass_rule) for t in TEMPERATURE):
                one = guide.decide_dial(first, dial(target, TEMPERATURE))
                two = guide.decide_dial(second, dial(target, TEMPERATURE))
                if one[1] not in ("near", "unclear"):
                    same[one[0]] += 1
                    passed[one[0]] += 1
                    continue
                agree = guide.plain_label(first.get("position", "")) == guide.plain_label(second.get("position", ""))
                same[two[0] if agree else "unsure"] += 1
                passed[two[0] if two[0] == "done" or agree else "unsure"] += 1
    print("second look, readings must agree: right", dict(same_rule), "wrong", dict(wrong_same))
    print("second look, a pass stands: right", dict(pass_rule), "wrong", dict(wrong_pass))


if __name__ == "__main__":
    main()
