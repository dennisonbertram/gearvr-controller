"""Behaviour tests for the input mapper (no Bluetooth or macOS events involved)."""
import pytest

from gearvr import ImuSample, Packet, Touch
import remote

IDLE_TOUCH = Touch(touching=False, lifted=False, x=0, y=0)


class FakeOut:
    def __init__(self):
        self.events = []
        self.held = set()

    def move(self, dx, dy):
        self.events.append(("move", round(dx, 2), round(dy, 2)))

    def mouse_button(self, name, down):
        self.events.append((name, "down" if down else "up"))

    def scroll(self, dy, dx=0):
        self.events.append(("scroll", dy))

    def key(self, combo, down):
        self.events.append(("key", combo, down))

    def media(self, name, down):
        self.events.append(("media", name, down))

    def release_all(self):
        pass

    def kinds(self):
        return [e[0] if e[0] in ("move", "scroll") else e for e in self.events]


def make_mapper(**clutch):
    cfg = {
        "buttons": {"trigger": "left_click", "touchpad": "right_click", "back": "key:escape"},
        "gestures": {},
        "pointer": {"enabled": True, "sensitivity": 20.0, "deadzone_dps": 0.0, "click_freeze_ms": 0},
        "touchpad": {"mode_pointer_on": "scroll", "mode_pointer_off": "cursor", "cursor_speed": 1,
                     "scroll_speed": 1, "invert_scroll": False},
        "clutch": {"enabled": True, "sound": False, **clutch},
    }
    out = FakeOut()
    m = remote.Mapper(cfg, out=out)
    m.bias.calibrated = True
    return m, out


class Feed:
    """Builds consecutive packets: 3 samples each, 4850 us apart, controller lying flat."""

    def __init__(self, mapper):
        self.m = mapper
        self.t = 1000

    def __call__(self, buttons=(), touch=IDLE_TOUCH, yaw_dps=0.0, n=1):
        for _ in range(n):
            samples = []
            for _ in range(3):
                self.t += 4850
                samples.append(ImuSample(self.t, (0.0, 0.0, 1.0), (0.0, 0.0, yaw_dps)))
            self.m.on_packet(Packet(tuple(samples), (0, 0, 0), touch, 25, frozenset(buttons), 100, b""))


def touch_at(x, y):
    return Touch(touching=True, lifted=False, x=x, y=y)


def test_trigger_tap_clicks_on_release():
    m, out = make_mapper()
    f = Feed(m)
    f()
    f(buttons={"trigger"}, n=5)
    assert out.events == []  # nothing yet: could still become a drag or a clutch
    f()
    assert out.events == [("left", "down"), ("left", "up")]


def test_small_jitter_while_pressed_does_not_move_or_drag():
    m, out = make_mapper(drag_threshold_px=12)
    f = Feed(m)
    f()
    f(buttons={"trigger"}, yaw_dps=5, n=4)  # ~1.2 px of motion
    f()
    assert out.kinds() == [("left", "down"), ("left", "up")]


def test_moving_while_pressed_starts_a_drag():
    m, out = make_mapper(drag_threshold_px=12)
    f = Feed(m)
    f()
    f(buttons={"trigger"}, yaw_dps=-60, n=10)  # turning right, ~17 px
    f()
    kinds = out.kinds()
    assert kinds[0] == ("left", "down")
    assert "move" in kinds and kinds[-1] == ("left", "up")
    assert sum(e[1] for e in out.events if e[0] == "move") > 12  # buffered motion not lost


def test_clutch_freezes_cursor_and_never_clicks():
    m, out = make_mapper()
    f = Feed(m)
    f()
    f(buttons={"trigger"}, n=3)
    f(buttons={"trigger"}, touch=touch_at(157, 290), n=3)  # touch the bottom of the pad
    assert m.clutched
    f(buttons={"trigger"}, touch=touch_at(157, 200), n=3)  # thumb slides: no scrolling
    f(buttons={"trigger"}, yaw_dps=90, n=20)  # hand repositions: cursor frozen
    assert out.events == []
    f()  # release trigger
    assert not m.clutched and out.events == []
    f(yaw_dps=90, n=3)  # pointer works again
    assert out.kinds() and set(out.kinds()) == {"move"}


def test_touching_elsewhere_while_pressed_does_not_clutch():
    m, out = make_mapper()
    f = Feed(m)
    f()
    f(buttons={"trigger"}, touch=touch_at(157, 60), n=3)  # top of pad
    assert not m.clutched
    f()
    assert ("left", "down") in out.events and ("left", "up") in out.events


def test_touchpad_click_during_clutch_is_suppressed():
    m, out = make_mapper()
    f = Feed(m)
    f()
    f(buttons={"trigger"}, n=2)
    f(buttons={"trigger"}, touch=touch_at(150, 300), n=2)
    f(buttons={"trigger", "touchpad"}, touch=touch_at(150, 300), n=2)  # pressed the pad down
    f(buttons={"trigger"}, n=2)
    f()
    assert out.events == []


def test_clutch_disabled_keeps_immediate_press():
    m, out = make_mapper(enabled=False)
    f = Feed(m)
    f()
    f(buttons={"trigger"})
    assert out.events == [("left", "down")]


@pytest.mark.parametrize("zone,x,y,hit", [("bottom", 157, 300, True), ("bottom", 157, 10, False),
                                          ("top", 157, 10, True), ("left", 5, 157, True)])
def test_zones(zone, x, y, hit):
    m, _ = make_mapper(zone=zone)
    assert m.in_clutch_zone(touch_at(x, y)) is hit
