"""Synthesize mouse, keyboard and media-key events on macOS via Quartz.

The process (i.e. your terminal app) needs Accessibility permission:
System Settings > Privacy & Security > Accessibility.
"""
import time

import Quartz as Q
from AppKit import NSEvent
from ApplicationServices import AXIsProcessTrusted

KEYCODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
    "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
    "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "f5": 96, "f6": 97,
    "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111,
    "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119,
    "f2": 120, "pagedown": 121, "f1": 122, "left": 123, "right": 124, "down": 125,
    "up": 126,
}
MODIFIERS = {
    "cmd": Q.kCGEventFlagMaskCommand,
    "command": Q.kCGEventFlagMaskCommand,
    "shift": Q.kCGEventFlagMaskShift,
    "alt": Q.kCGEventFlagMaskAlternate,
    "option": Q.kCGEventFlagMaskAlternate,
    "opt": Q.kCGEventFlagMaskAlternate,
    "ctrl": Q.kCGEventFlagMaskControl,
    "control": Q.kCGEventFlagMaskControl,
    "fn": Q.kCGEventFlagMaskSecondaryFn,
}
MEDIA_KEYS = {  # NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    "volume_up": 0, "volume_down": 1, "brightness_up": 2, "brightness_down": 3,
    "mute": 7, "play": 16, "next": 17, "previous": 18, "fast": 19, "rewind": 20,
}
MOUSE_BUTTONS = {
    "left": (Q.kCGEventLeftMouseDown, Q.kCGEventLeftMouseUp, Q.kCGEventLeftMouseDragged, Q.kCGMouseButtonLeft),
    "right": (Q.kCGEventRightMouseDown, Q.kCGEventRightMouseUp, Q.kCGEventRightMouseDragged, Q.kCGMouseButtonRight),
    "middle": (Q.kCGEventOtherMouseDown, Q.kCGEventOtherMouseUp, Q.kCGEventOtherMouseDragged, Q.kCGMouseButtonCenter),
}
DOUBLE_CLICK_S = 0.4


def accessibility_ok() -> bool:
    return bool(AXIsProcessTrusted())


def parse_combo(combo: str) -> tuple[int, int]:
    """'cmd+shift+[' -> (keycode, flags). Write a literal plus as 'shift+='."""
    flags = 0
    *mods, key = combo.lower().split("+")
    for m in mods:
        if m not in MODIFIERS:
            raise ValueError(f"unknown modifier {m!r} in {combo!r}")
        flags |= MODIFIERS[m]
    if key not in KEYCODES:
        raise ValueError(f"unknown key {key!r} in {combo!r}")
    return KEYCODES[key], flags


def _display_bounds() -> tuple[float, float, float, float]:
    err, ids, count = Q.CGGetActiveDisplayList(16, None, None)
    rects = [Q.CGDisplayBounds(i) for i in ids[:count]]
    x0 = min(r.origin.x for r in rects)
    y0 = min(r.origin.y for r in rects)
    x1 = max(r.origin.x + r.size.width for r in rects)
    y1 = max(r.origin.y + r.size.height for r in rects)
    return x0, y0, x1 - 1, y1 - 1


class Output:
    def __init__(self):
        self.held: set[str] = set()
        self._frac = [0.0, 0.0]
        self._bounds = _display_bounds()
        self._last_click = {"button": None, "t": 0.0, "count": 0}

    # --- pointer -----------------------------------------------------------
    @staticmethod
    def position() -> tuple[float, float]:
        loc = Q.CGEventGetLocation(Q.CGEventCreate(None))
        return loc.x, loc.y

    def move(self, dx: float, dy: float) -> None:
        self._frac[0] += dx
        self._frac[1] += dy
        ix, iy = int(self._frac[0]), int(self._frac[1])
        if ix == 0 and iy == 0:
            return
        self._frac[0] -= ix
        self._frac[1] -= iy
        x, y = self.position()
        x0, y0, x1, y1 = self._bounds
        x = min(max(x + ix, x0), x1)
        y = min(max(y + iy, y0), y1)
        event_type, button = Q.kCGEventMouseMoved, Q.kCGMouseButtonLeft
        for name in ("left", "right", "middle"):
            if name in self.held:
                _, _, event_type, button = MOUSE_BUTTONS[name]
                break
        ev = Q.CGEventCreateMouseEvent(None, event_type, (x, y), button)
        Q.CGEventSetIntegerValueField(ev, Q.kCGMouseEventDeltaX, ix)
        Q.CGEventSetIntegerValueField(ev, Q.kCGMouseEventDeltaY, iy)
        Q.CGEventPost(Q.kCGHIDEventTap, ev)

    def mouse_button(self, name: str, down: bool) -> None:
        down_t, up_t, _, button = MOUSE_BUTTONS[name]
        pos = self.position()
        if down:
            now = time.monotonic()
            lc = self._last_click
            same = lc["button"] == name and now - lc["t"] < DOUBLE_CLICK_S
            lc.update(button=name, t=now, count=lc["count"] + 1 if same else 1)
            self.held.add(name)
        else:
            self.held.discard(name)
        ev = Q.CGEventCreateMouseEvent(None, down_t if down else up_t, pos, button)
        Q.CGEventSetIntegerValueField(ev, Q.kCGMouseEventClickState, self._last_click["count"])
        Q.CGEventPost(Q.kCGHIDEventTap, ev)

    def scroll(self, dy: float, dx: float = 0.0) -> None:
        ev = Q.CGEventCreateScrollWheelEvent(None, Q.kCGScrollEventUnitPixel, 2, int(dy), int(dx))
        Q.CGEventPost(Q.kCGHIDEventTap, ev)

    # --- keyboard ----------------------------------------------------------
    @staticmethod
    def key(combo: str, down: bool) -> None:
        code, flags = parse_combo(combo)
        ev = Q.CGEventCreateKeyboardEvent(None, code, down)
        if flags:
            Q.CGEventSetFlags(ev, flags)
        Q.CGEventPost(Q.kCGHIDEventTap, ev)

    @staticmethod
    def media(name: str, down: bool) -> None:
        code = MEDIA_KEYS[name]
        state = 0xA if down else 0xB
        ev = NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
            14, (0, 0), state << 8, 0, 0, None, 8, (code << 16) | (state << 8), -1)
        Q.CGEventPost(Q.kCGHIDEventTap, ev.CGEvent())

    def release_all(self) -> None:
        for name in list(self.held):
            self.mouse_button(name, False)
