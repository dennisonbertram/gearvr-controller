"""Guided, voice-prompted capture session for decoding the controller.

Your Mac speaks each instruction; every notification is logged to a JSONL file
with the currently active step label, so analysis can attribute bit changes to
physical actions.

Hold the controller like a TV remote: touchpad up under your thumb, trigger
under your index finger, the far end pointing away from you.

usage: guided.py [outfile.jsonl]
"""
import asyncio
import json
import sys
import time

from gearvr import CMD_KEEPALIVE, Controller

EXTRA_NOTIFY = {
    "00002a4d-0000-1000-8000-00805f9b34fb": "hid_report",
    "00002a22-0000-1000-8000-00805f9b34fb": "boot_kbd",
    "00002a19-0000-1000-8000-00805f9b34fb": "battery",
}

# (label, spoken instruction, seconds to record)
HID_STEPS = [
    ("hid_buttons", "First, before streaming starts. Press each button once, slowly: "
     "trigger, home, back, touchpad click, volume up, volume down.", 14),
]
STREAM_STEPS = [
    ("rest_flat", "Streaming. Lay the controller flat on the table, touchpad up, and let go.", 6),
    ("btn_trigger", "Pick it up. Press the trigger three times.", 6),
    ("btn_home", "Press the home button three times.", 6),
    ("btn_back", "Press the back button three times.", 6),
    ("btn_touch_click", "Click the touchpad down three times.", 6),
    ("btn_vol_up", "Press volume up three times.", 6),
    ("btn_vol_down", "Press volume down three times.", 6),
    ("touch_center", "Rest your thumb on the center of the touchpad and hold it there.", 5),
    ("touch_left_right", "Slide your thumb slowly from left to right across the touchpad. Repeat a few times.", 7),
    ("touch_far_near", "Now slide from the far edge toward you. Repeat a few times.", 7),
    ("touch_circle", "Trace slow circles around the outer edge of the touchpad.", 8),
    ("rotate_yaw", "Lay it flat on the table again. When you hear the tone, turn it one full circle "
     "counter clockwise, flat on the table, and stop where you started.", 10),
    ("point_up", "Pick it up and point the far end straight up at the ceiling. Hold still.", 5),
    ("roll_left", "Hold it level, pointing away from you, and roll it onto its left side, "
     "so the touchpad faces left. Hold still.", 5),
    ("wave", "Last one. Wave it around in big figure eights, in every direction.", 12),
    ("hid_after_off", "Streaming is now off. Press each button once more: trigger, home, "
     "back, touchpad click, volume up, volume down.", 14),
]


async def speak(text: str) -> None:
    print(f"\n>>> {text}", flush=True)
    proc = await asyncio.create_subprocess_exec("say", "-r", "190", text)
    await proc.wait()


async def tone(name: str = "Tink") -> None:
    proc = await asyncio.create_subprocess_exec("afplay", f"/System/Library/Sounds/{name}.aiff")
    await proc.wait()


async def main(outfile: str) -> None:
    start = time.monotonic()
    label = "setup"
    with open(outfile, "w") as out:

        def log(src: str, data: bytes) -> None:
            out.write(json.dumps({"t": round(time.monotonic() - start, 4), "label": label,
                                  "src": src, "hex": data.hex()}) + "\n")

        async def run_step(step) -> None:
            nonlocal label
            name, text, seconds = step
            label = f"{name}:prompt"
            await speak(text)
            await tone("Tink")
            label = name
            print(f"    recording {name} for {seconds}s", flush=True)
            await asyncio.sleep(seconds)
            await tone("Pop")

        from gearvr import find_controller

        while True:
            try:
                await find_controller(timeout=4)
                break
            except RuntimeError:
                await speak("I can't see the controller. Give the home button a short press to wake it.")

        async with Controller(on_raw=lambda d: log("data", d)) as c:
            for uuid, src in EXTRA_NOTIFY.items():
                await c.client.start_notify(uuid, lambda _c, d, src=src: log(src, bytes(d)))
            await asyncio.sleep(1)  # let any pairing/encryption settle
            try:
                print(f"connected, battery {await c.battery()}%", flush=True)
            except Exception as exc:
                print(f"connected (battery read failed: {exc})", flush=True)

            for step in HID_STEPS:
                await run_step(step)

            await c.start_vr_stream()

            async def keepalive() -> None:
                while True:
                    await asyncio.sleep(3)
                    await c.send(CMD_KEEPALIVE, wait_ack=False)

            ka = asyncio.create_task(keepalive())
            for step in STREAM_STEPS[:-1]:
                await run_step(step)
            ka.cancel()
            await c.send("0000", wait_ack=False)
            await run_step(STREAM_STEPS[-1])
            await speak("All done. Thank you.")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "caps/guided.jsonl"))
