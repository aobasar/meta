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
PROGRAM = ["regular express", "normal", "casual", "delicate", "hand wash", "soak", "prewash", "heavy duty", "comforters/bedding"]
KNOBS = {
    "20261031-063103": "cool brights", "20261031-063112": "cool brights", "20261031-063118": "cool brights",
    "20261031-071437": "hot", "20261031-071445": "hot", "20261031-074215": "warm", "20261101-020127": "cold",
    "20261101-021300": "cold", "20261101-022122": "cool brights", "20261101-031726": "warm", "20261101-031733": "warm",
}
PROGRAM_CHECKS = {
    "20261031-065705": "comforters/bedding", "20261031-065719": "comforters/bedding", "20261031-065953": "regular express",
    "20261031-070000": "regular express", "20261101-021708": "regular express", "20261101-022155": "regular express",
    "20261101-031457": "regular express", "20261101-031746": "comforters/bedding",
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
        text, _ = guide.spark(guide.DIAL_READ_PROMPT.format(positions=", ".join(positions)), "data:image/jpeg;base64," + image,
                              key, urllib.request.urlopen, guide.DIAL_READ_SCHEMA)
        return job, guide.parse_json(text)

    jobs = [(stamp, truth, TEMPERATURE, False) for stamp, truth in KNOBS.items() for _ in range(runs)]
    jobs += [(stamp, target, PROGRAM, True) for stamp, target in PROGRAM_CHECKS.items() for _ in range(runs)]
    with ThreadPoolExecutor(6) as pool:
        results = list(pool.map(read, jobs))

    right, wrong, programs = collections.Counter(), collections.Counter(), collections.Counter()
    for (stamp, truth, positions, segments), reading in results:
        if segments:
            decision = guide.decide_dial(reading, dial(truth, positions, True))
            programs[decision] += 1
            print(stamp, truth, "->", decision, reading.get("position"), reading.get("pointer_clock"))
            continue
        right[guide.decide_dial(reading, dial(truth, positions))] += 1
        for other in positions:
            if other != truth:
                wrong[guide.decide_dial(reading, dial(other, positions))[0]] += 1
    print("right target:", dict(right))
    print("wrong targets:", dict(wrong))
    print("program dial:", dict(programs))


if __name__ == "__main__":
    main()
