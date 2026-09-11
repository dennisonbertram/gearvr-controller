"""Use the Gear VR Controller as a mouse / keyboard / media remote on macOS.

    .venv/bin/python remote.py [config.toml] [--viewer]

--viewer also serves the 3D web viewer at http://localhost:8765 (see bridge.py).

Reconnects automatically: if the controller sleeps, press any button to wake it.
"""
import asyncio
import math
import subprocess
import sys
import time
import tomllib
from collections import deque

from gearvr import BUTTON_BITS, Controller, Packet
from macos_input import MEDIA_KEYS, Output, accessibility_ok, parse_combo

SWIPE_MAX_S = 0.45
SWIPE_MIN_DIST = 70  # touchpad units (pad is ~315 across)
TAP_MAX_DIST = 20


def validate_action(action: str) -> None:
    kind, _, arg = action.partition(":")
    if kind == "key":
        parse_combo(arg)
    elif kind == "media" and arg not in MEDIA_KEYS:
        raise ValueError(f"unknown media key {arg!r}")
    elif kind not in {"key", "media", "shell", "left_click", "right_click",
                      "middle_click", "toggle_pointer", "none"}:
        raise ValueError(f"unknown action {action!r}")


class GyroBias:
    """Tracks the gyro zero-offset, re-estimating it whenever the controller is still."""

    def __init__(self, window: int = 100):
        self.samples: deque = deque(maxlen=window)
        self.bias = (0.0, 0.0, 0.0)
        self.calibrated = False

    def update(self, g: tuple[float, float, float]) -> None:
        self.samples.append(g)
        if len(self.samples) < self.samples.maxlen:
            return
        cols = list(zip(*self.samples))
        means = [sum(c) / len(c) for c in cols]
        sds = [math.sqrt(sum((v - m) ** 2 for v in c) / len(c)) for c, m in zip(cols, means)]
        if max(sds) >= 0.8:
            return
        if not self.calibrated:
            self.bias = tuple(means)
            self.calibrated = True
            print(f"gyro calibrated, bias {tuple(round(b, 2) for b in self.bias)} dps", flush=True)
        elif all(abs(m - b) < 3 for m, b in zip(means, self.bias)):
            # small drift correction; the guard avoids absorbing a slow deliberate turn
            self.bias = tuple(b + 0.2 * (m - b) for b, m in zip(self.bias, means))
        self.samples.clear()


class Mapper:
    def __init__(self, cfg: dict, out=None):
        self.cfg = cfg
        self.out = out or Output()
        self.buttons = cfg["buttons"]
        self.gestures = cfg.get("gestures", {})
        for action in [*self.buttons.values(), *self.gestures.values()]:
            validate_action(action)
        self.pointer_on = cfg["pointer"]["enabled"]
        self.prev_buttons: frozenset[str] = frozenset()
        self.freeze_until = 0.0
        self.bias = GyroBias()
        self.up = (0.0, 0.0, 1.0)
        self.last_ts: int | None = None
        self.touch_prev: tuple[int, int] | None = None
        self.touch_start: tuple[float, int, int] | None = None
        self.scroll_frac = 0.0

    # --- actions -------------------------------------------------------------
    def run_action(self, action: str, down: bool) -> None:
        kind, _, arg = action.partition(":")
        if kind in ("left_click", "right_click", "middle_click"):
            self.out.mouse_button(kind.split("_")[0], down)
        elif kind == "key":
            self.out.key(arg, down)
        elif kind == "media":
            self.out.media(arg, down)
        elif kind == "shell" and down:
            subprocess.Popen(arg, shell=True)
        elif kind == "toggle_pointer" and down:
            self.pointer_on = not self.pointer_on
            print(f"air-mouse {'ON' if self.pointer_on else 'OFF'}", flush=True)

    def tap_action(self, action: str) -> None:
        self.run_action(action, True)
        self.run_action(action, False)

    # --- packet handling -----------------------------------------------------
    def on_packet(self, p: Packet) -> None:
        self.handle_buttons(p)
        self.handle_motion(p)
        self.handle_touch(p)

    def handle_buttons(self, p: Packet) -> None:
        if p.buttons == self.prev_buttons:
            return
        for name in BUTTON_BITS:
            was, now = name in self.prev_buttons, name in p.buttons
            if was != now:
                if now:
                    self.freeze_until = time.monotonic() + self.cfg["pointer"]["click_freeze_ms"] / 1000
                self.run_action(self.buttons.get(name, "none"), now)
        self.prev_buttons = p.buttons

    def handle_motion(self, p: Packet) -> None:
        pc = self.cfg["pointer"]
        for s in p.samples:
            self.bias.update(s.gyro_dps)
            # low-pass the accelerometer to track which way is up (body frame)
            a = s.accel_g
            n = math.hypot(*a)
            if 0.7 < n < 1.3:
                self.up = tuple(0.97 * u + 0.03 * v / n for u, v in zip(self.up, a))
            if self.last_ts is None:
                self.last_ts = s.timestamp_us
                continue
            dt = ((s.timestamp_us - self.last_ts) & 0xFFFFFFFF) / 1e6
            self.last_ts = s.timestamp_us
            if not (0 < dt < 0.1) or not self.pointer_on or not self.bias.calibrated:
                continue
            if time.monotonic() < self.freeze_until:
                continue
            w = [g - b for g, b in zip(s.gyro_dps, self.bias.bias)]
            up = self.up
            un = math.hypot(*up) or 1.0
            up = [u / un for u in up]
            # right = forward(+Y) x up ; falls back to +X when pointing straight up
            right = (up[2], 0.0, -up[0])
            rn = math.hypot(*right)
            right = [r / rn for r in right] if rn > 0.2 else [1.0, 0.0, 0.0]
            yaw = sum(wi * ui for wi, ui in zip(w, up))  # + = turning left
            pitch = sum(wi * ri for wi, ri in zip(w, right))  # + = nose up
            dz = pc["deadzone_dps"]
            yaw = math.copysign(max(abs(yaw) - dz, 0.0), yaw)
            pitch = math.copysign(max(abs(pitch) - dz, 0.0), pitch)
            gain = pc["sensitivity"] * dt
            self.out.move(-yaw * gain, -pitch * gain)

    def handle_touch(self, p: Packet) -> None:
        tc = self.cfg["touchpad"]
        mode = tc["mode_pointer_on"] if self.pointer_on else tc["mode_pointer_off"]
        t = p.touch
        now = time.monotonic()
        if t.touching:
            if self.touch_start is None:
                self.touch_start = (now, t.x, t.y)
            if self.touch_prev is not None:
                dx, dy = t.x - self.touch_prev[0], t.y - self.touch_prev[1]
                if mode == "cursor":
                    self.out.move(dx * tc["cursor_speed"], dy * tc["cursor_speed"])
                elif mode == "scroll":
                    sign = -1 if tc["invert_scroll"] else 1
                    self.scroll_frac += sign * dy * tc["scroll_speed"] * 4
                    step = int(self.scroll_frac)
                    if step:
                        self.out.scroll(step)
                        self.scroll_frac -= step
            self.touch_prev = (t.x, t.y)
            return
        if self.touch_start is not None and mode == "gestures":
            t0, x0, y0 = self.touch_start
            x1, y1 = self.touch_prev or (x0, y0)
            dx, dy, dur = x1 - x0, y1 - y0, now - t0
            if dur < SWIPE_MAX_S and max(abs(dx), abs(dy)) >= SWIPE_MIN_DIST:
                if abs(dx) > abs(dy):
                    name = "swipe_right" if dx > 0 else "swipe_left"
                else:
                    name = "swipe_down" if dy > 0 else "swipe_up"
                self.tap_action(self.gestures.get(name, "none"))
            elif dur < SWIPE_MAX_S and max(abs(dx), abs(dy)) < TAP_MAX_DIST and "touchpad" not in self.prev_buttons:
                self.tap_action(self.gestures.get("tap", "none"))
        self.touch_prev = None
        self.touch_start = None

    def reset(self) -> None:
        self.out.release_all()
        self.prev_buttons = frozenset()
        self.last_ts = None
        self.touch_prev = self.touch_start = None


async def main(config_path: str, with_viewer: bool = False) -> None:
    viewer = None
    if with_viewer:
        from bridge import ViewerServer

        viewer = ViewerServer()
        await viewer.start()
    with open(config_path, "rb") as f:
        cfg = tomllib.load(f)
    if not accessibility_ok():
        print("WARNING: this terminal app lacks Accessibility permission, so input events will be\n"
              "ignored by macOS. Grant it in System Settings > Privacy & Security > Accessibility,\n"
              "then restart this script.", flush=True)
    mapper = Mapper(cfg)
    while True:
        disconnected = asyncio.Event()
        try:
            print("looking for the controller (press a button to wake it)...", flush=True)
            async with Controller(on_packet=mapper.on_packet, on_disconnect=disconnected.set,
                                  on_raw=viewer.publish if viewer else None) as c:
                await c.start_vr_stream()
                if viewer:
                    viewer.set_status("streaming")
                print("connected - hold it still for a second to calibrate the gyro", flush=True)
                await disconnected.wait()
                print("controller disconnected", flush=True)
        except Exception as exc:
            print(f"connection problem: {exc}", flush=True)
        if viewer:
            viewer.set_status("disconnected")
        mapper.reset()
        mapper.bias.calibrated = False
        await asyncio.sleep(2)


if __name__ == "__main__":
    try:
        args = [a for a in sys.argv[1:] if not a.startswith("--")]
        asyncio.run(main(args[0] if args else "config.toml", "--viewer" in sys.argv))
    except KeyboardInterrupt:
        pass
