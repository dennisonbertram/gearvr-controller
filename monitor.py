"""Live terminal view of the decoded controller state. Ctrl-C to quit."""
import asyncio
import math
import sys

from gearvr import TOUCH_MAX, Controller, Packet

PAD_W, PAD_H = 21, 9
state: dict = {"pkt": None, "count": 0}


def on_packet(p: Packet) -> None:
    state["pkt"] = p
    state["count"] += 1


def pad(p: Packet) -> list[str]:
    rows = []
    cx = round(p.touch.x / TOUCH_MAX * (PAD_W - 1))
    cy = round(p.touch.y / TOUCH_MAX * (PAD_H - 1))
    for r in range(PAD_H):
        line = ""
        for c in range(PAD_W):
            dx = (c - (PAD_W - 1) / 2) / ((PAD_W - 1) / 2)
            dy = (r - (PAD_H - 1) / 2) / ((PAD_H - 1) / 2)
            if p.touch.touching and (c, r) == (cx, cy):
                line += "@"
            elif dx * dx + dy * dy <= 1.0:
                line += "."
            else:
                line += " "
        rows.append(line)
    return rows


def render(p: Packet, rate: float) -> str:
    s = p.latest
    ax, ay, az = s.accel_g
    pitch = math.degrees(math.atan2(ay, math.hypot(ax, az)))
    roll = math.degrees(math.atan2(ax, az))
    names = ["trigger", "home", "back", "touchpad", "volume_up", "volume_down"]
    btns = "  ".join(f"[{n.upper()}]" if n in p.buttons else f" {n} " for n in names)
    lines = [
        f"packets/s {rate:5.1f}   battery {p.battery:3d}%   temp {p.temperature_c}C",
        "",
        btns,
        "",
        f"accel g    x {ax:+6.2f}  y {ay:+6.2f}  z {az:+6.2f}   |a| {math.hypot(ax, ay, az):4.2f}",
        f"gyro dps   x {s.gyro_dps[0]:+8.1f}  y {s.gyro_dps[1]:+8.1f}  z {s.gyro_dps[2]:+8.1f}",
        f"tilt       pitch {pitch:+6.1f}  roll {roll:+6.1f}",
        f"mag raw    {p.mag_raw}",
        f"touch      {'DOWN' if p.touch.touching else ('lift' if p.touch.lifted else 'up  ')}"
        f"  x {p.touch.x:3d}  y {p.touch.y:3d}",
        "",
        *pad(p),
    ]
    return "\x1b[H\x1b[J" + "\n".join(lines) + "\n"


async def main() -> None:
    async with Controller(on_packet=on_packet) as c:
        await c.start_vr_stream()
        last_count, last_t = 0, asyncio.get_running_loop().time()
        rate = 0.0
        while c.client.is_connected:
            await asyncio.sleep(0.05)
            now = asyncio.get_running_loop().time()
            if now - last_t >= 1.0:
                rate = (state["count"] - last_count) / (now - last_t)
                last_count, last_t = state["count"], now
            if state["pkt"]:
                sys.stdout.write(render(state["pkt"], rate))
                sys.stdout.flush()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
