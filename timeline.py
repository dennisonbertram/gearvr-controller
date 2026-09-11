"""Condensed timeline of a capture: commands, short notifications, and data
packet bursts bucketed per 0.5s so mode changes are easy to see."""
import json
import sys


def main(path: str) -> None:
    bucket_start, count = None, 0
    for line in open(path):
        rec = json.loads(line)
        is_data = rec["src"] == "data" and len(rec["hex"]) == 120
        if is_data:
            b = int(rec["t"] * 2) / 2
            if b != bucket_start:
                if count:
                    print(f"  {bucket_start:6.1f}s  {count:3d} data pkts")
                bucket_start, count = b, 0
            count += 1
            continue
        if count:
            print(f"  {bucket_start:6.1f}s  {count:3d} data pkts")
            bucket_start, count = None, 0
        print(f"{rec['t']:8.3f}s  {rec['src']:10s} {rec['hex']}")
    if count:
        print(f"  {bucket_start:6.1f}s  {count:3d} data pkts")


if __name__ == "__main__":
    main(sys.argv[1])
