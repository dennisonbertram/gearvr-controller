"""Fit IMU axis orientation and gyro scale from the guided capture.

Uses static poses (rest_flat, point_up, roll_left) for gravity direction and
integrates the gyro between consecutive still periods, choosing the scale
that best rotates one gravity vector into the next.
"""
import json
import math
import struct
import sys

import numpy as np


def load_samples(path):
    """Return arrays: t (s, from device us clock), accel (N,3), gyro (N,3), labels."""
    ts, acc, gyr, labels = [], [], [], []
    last = None
    for line in open(path):
        rec = json.loads(line)
        if rec["src"] != "data" or len(rec["hex"]) != 120:
            continue
        d = bytes.fromhex(rec["hex"])
        for off in (0, 16, 32):
            t, ax, ay, az, gx, gy, gz = struct.unpack_from("<I6h", d, off)
            if last is not None and t <= last:
                continue  # duplicate / reordered sample
            last = t
            ts.append(t / 1e6)
            acc.append((ax, ay, az))
            gyr.append((gx, gy, gz))
            labels.append(rec["label"])
    return np.array(ts), np.array(acc, float), np.array(gyr, float), labels


def still_segments(t, acc, gyr, min_len=0.6):
    gnorm = np.linalg.norm(gyr - np.median(gyr, axis=0), axis=1)
    # moving-window standard deviation of accel magnitude
    amag = np.linalg.norm(acc, axis=1)
    k = 40
    sd = np.array([amag[max(0, i - k):i + k].std() for i in range(len(amag))])
    still = (gnorm < 40) & (sd < 15)
    segs, start = [], None
    for i, s in enumerate(still):
        if s and start is None:
            start = i
        if (not s or i == len(still) - 1) and start is not None:
            if t[i - 1] - t[start] >= min_len:
                segs.append((start, i - 1))
            start = None
    return segs


def quat_mul(a, b):
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return np.array([
        w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
        w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
        w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
        w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
    ])


def rotate(q, v):
    qv = np.concatenate([[0.0], v])
    qc = q * np.array([1, -1, -1, -1])
    return quat_mul(quat_mul(q, qv), qc)[1:]


def integrate(t, gyr_rad):
    """Body orientation change as quaternion (body_end expressed in body_start)."""
    q = np.array([1.0, 0, 0, 0])
    for i in range(1, len(t)):
        w = gyr_rad[i]
        dt = t[i] - t[i - 1]
        ang = np.linalg.norm(w) * dt
        if ang > 0:
            axis = w / np.linalg.norm(w)
            dq = np.concatenate([[math.cos(ang / 2)], axis * math.sin(ang / 2)])
            q = quat_mul(q, dq)
    return q


def main(path):
    t, acc, gyr, labels = load_samples(path)
    print(f"{len(t)} IMU samples over {t[-1] - t[0]:.1f}s, rate {len(t) / (t[-1] - t[0]):.1f} Hz")

    segs = still_segments(t, acc, gyr)
    bias = np.mean([gyr[a:b].mean(axis=0) for a, b in segs], axis=0)
    print(f"gyro bias (counts): {bias.round(1)}")
    print("\nstill segments:")
    grav = []
    for a, b in segs:
        g = acc[a:b].mean(axis=0)
        grav.append(g)
        print(f"  {t[a] - t[0]:7.1f}-{t[b] - t[0]:7.1f}s  {labels[a]:22s} accel={g.round(0)} |a|={np.linalg.norm(g):.0f}")

    # Fit gyro scale: counts -> deg/s is 1/s_lsb
    candidates = np.linspace(8, 40, 321)
    best = None
    for sign in (1, -1):
        for lsb in candidates:
            err, total = 0.0, 0.0
            for (a0, b0), (a1, b1), g0, g1 in zip(segs, segs[1:], grav, grav[1:]):
                u0, u1 = g0 / np.linalg.norm(g0), g1 / np.linalg.norm(g1)
                if math.degrees(math.acos(np.clip(u0 @ u1, -1, 1))) < 20:
                    continue  # too little tilt change to be informative
                w = sign * np.radians((gyr[b0:a1 + 1] - bias) / lsb)
                q = integrate(t[b0:a1 + 1], w)
                pred = rotate(q * np.array([1, -1, -1, -1]), u0)  # gravity seen in new body frame
                e = math.degrees(math.acos(np.clip(pred @ u1, -1, 1)))
                err += e
                total += 1
            if total and (best is None or err / total < best[0]):
                best = (err / total, sign, lsb, total)
    print(f"\nbest gyro fit: {best[2]:.2f} LSB per deg/s, sign {best[1]:+d}, "
          f"mean tilt error {best[0]:.2f} deg over {best[3]} transitions")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "caps/guided.jsonl")
