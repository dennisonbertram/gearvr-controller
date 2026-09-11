"""Quick statistics over a capture file (see capture.py)."""
import json
import struct
import sys
from statistics import mean, pstdev


def load(path: str, src: str = "data", size: int = 60) -> list[tuple[float, bytes]]:
    out = []
    for line in open(path):
        rec = json.loads(line)
        data = bytes.fromhex(rec["hex"])
        if rec["src"] == src and len(data) == size:
            out.append((rec["t"], data))
    return out


def main(path: str) -> None:
    pkts = load(path)
    print(f"{len(pkts)} data packets")
    if len(pkts) < 2:
        return
    wall = pkts[-1][0] - pkts[0][0]
    print(f"packet rate (wall clock): {(len(pkts) - 1) / wall:.1f} Hz")

    # per-sample timestamps: three 16-byte samples per packet
    stamps = [struct.unpack_from("<I", d, off)[0] for _, d in pkts for off in (0, 16, 32)]
    deltas = [b - a for a, b in zip(stamps, stamps[1:])]
    print(f"sample ts delta: mean={mean(deltas):.1f} sd={pstdev(deltas):.1f} min={min(deltas)} max={max(deltas)}")
    print(f"ts ticks per wall second: {(stamps[-1] - stamps[0]) / wall:.0f}")

    for label, base in (("accel", 4), ("gyro", 10)):
        vals = [struct.unpack_from("<3h", d, off + base) for _, d in pkts[10:] for off in (0, 16, 32)]
        for axis, col in zip("xyz", zip(*vals)):
            print(f"{label} {axis}: mean={mean(col):8.1f} sd={pstdev(col):6.1f}")
    mags = [struct.unpack_from("<3h", d, 48) for _, d in pkts if any(d[48:54])]
    if mags:
        for axis, col in zip("xyz", zip(*mags)):
            print(f"mag   {axis}: mean={mean(col):8.1f} sd={pstdev(col):6.1f}  (n={len(col)})")

    # Which of the tail bytes vary at all?
    for i in range(54, 60):
        seen = sorted({d[i] for _, d in pkts})
        print(f"byte {i}: {len(seen)} distinct -> {[hex(v) for v in seen[:12]]}")


if __name__ == "__main__":
    main(sys.argv[1])
