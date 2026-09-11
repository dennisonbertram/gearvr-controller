"""Decode the guided capture: per-step changes in the packet tail bytes."""
import json
import sys
from collections import Counter, OrderedDict


def load(path: str):
    steps = OrderedDict()
    for line in open(path):
        rec = json.loads(line)
        if rec["src"] == "data" and len(rec["hex"]) == 120:
            steps.setdefault(rec["label"], []).append((rec["t"], bytes.fromhex(rec["hex"])))
    return steps


def transitions(pkts, idx):
    out, prev = [], None
    for t, d in pkts:
        if d[idx] != prev:
            out.append((round(t, 2), f"{d[idx]:08b}"))
            prev = d[idx]
    return out


def main(path: str) -> None:
    steps = load(path)
    for label, pkts in steps.items():
        if ":prompt" in label:
            continue
        print(f"\n== {label} ({len(pkts)} pkts)")
        tr = transitions(pkts, 58)
        print(f"  byte58 transitions ({len(tr) - 1}): {tr[:14]}")
        for i in (54, 55, 56, 57, 59):
            vals = Counter(d[i] for _, d in pkts)
            print(f"  byte{i}: {len(vals)} distinct, top {[(hex(v), n) for v, n in vals.most_common(6)]}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "caps/guided.jsonl")
