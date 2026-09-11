"""Tests against real packets recorded from an ET-YO324 controller.

    .venv/bin/python -m pytest -q
"""
import json
import os

import pytest

from gearvr import parse

FIXTURES = json.load(open(os.path.join(os.path.dirname(__file__), "tests_fixtures.json")))


def pkt(name):
    return parse(bytes.fromhex(FIXTURES[name]))


@pytest.mark.parametrize("button", ["trigger", "home", "back", "touchpad", "volume_up", "volume_down"])
def test_each_button_decodes_alone(button):
    assert pkt(button).buttons == {button}


def test_idle_packet():
    p = pkt("idle")
    assert p.buttons == set()
    assert not p.touch.touching and not p.touch.lifted
    assert p.battery == 100
    assert 15 <= p.temperature_c <= 40


def test_touch_center_and_lift():
    center = pkt("touch_center").touch
    assert center.touching and 120 < center.x < 190 and 120 < center.y < 200
    lift = pkt("touch_lift").touch
    assert lift.lifted and not lift.touching


def test_samples_are_timestamped_in_microseconds():
    s = pkt("idle").samples
    deltas = [b.timestamp_us - a.timestamp_us for a, b in zip(s, s[1:])]
    assert all(4000 < d < 6000 for d in deltas)  # ~206 Hz


@pytest.mark.parametrize("pose,axis", [("idle", 2), ("point_up", 1), ("roll_left", 0)])
def test_gravity_axes(pose, axis):
    """Flat = +Z up, far end up = +Y up, rolled onto its left side = +X up."""
    a = pkt(pose).latest.accel_g
    assert a[axis] > 0.9
    assert abs(sum(v * v for v in a) ** 0.5 - 1.0) < 0.1


def test_air_mouse_direction_on_recorded_pitch_up():
    """Replay the recorded flat -> point-at-ceiling motion: the cursor must go up."""
    path = os.path.join(os.path.dirname(__file__), "caps", "guided.jsonl")
    if not os.path.exists(path):
        pytest.skip("guided capture not present")
    import remote

    moves = []

    class FakeOut:
        held = set()

        def move(self, dx, dy):
            moves.append((dx, dy))

    cfg = {"buttons": {}, "gestures": {}, "pointer": {"enabled": True, "sensitivity": 20.0,
           "deadzone_dps": 1.0, "click_freeze_ms": 0}, "touchpad": {"mode_pointer_on": "scroll",
           "mode_pointer_off": "cursor", "cursor_speed": 1, "scroll_speed": 1, "invert_scroll": False}}
    m = remote.Mapper(cfg, out=FakeOut())
    for line in open(path):
        rec = json.loads(line)
        if rec["src"] == "data" and len(rec["hex"]) == 120 and rec["label"] in ("rotate_yaw", "point_up:prompt"):
            m.handle_motion(parse(bytes.fromhex(rec["hex"])))
    total_dy = sum(dy for _, dy in moves)
    assert total_dy < -500  # screen y decreases = cursor moves up
