"""Raw packet logger for the Gear VR Controller.

Subscribes to every notifying characteristic, sends one or more commands to
the command characteristic, and writes each notification as a JSON line:
    {"t": <seconds since start>, "src": "<short char name>", "hex": "..."}

usage: capture.py <seconds> <outfile.jsonl> [cmd_hex ...] [ka=<hex>@<interval>]
       e.g. capture.py 20 caps/sensor.jsonl 0100
            capture.py 20 caps/vr.jsonl 0800 0100 ka=0400@1.0
"""
import asyncio
import json
import sys
import time

from bleak import BleakClient, BleakScanner

NAME_PREFIX = "Gear VR Controller"
CMD_CHAR = "c8c51726-81bc-483b-a052-f7a14ea3d282"
NOTIFY = {
    "c8c51726-81bc-483b-a052-f7a14ea3d281": "data",
    "00002a4d-0000-1000-8000-00805f9b34fb": "hid_report",
    "00002a22-0000-1000-8000-00805f9b34fb": "boot_kbd",
    "00002a19-0000-1000-8000-00805f9b34fb": "battery",
    "5f78df94-798c-46f5-990a-b3eb6a065c88": "suota",
}


async def find_controller():
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: (adv.local_name or d.name or "").startswith(NAME_PREFIX),
        timeout=20,
    )
    if device is None:
        raise SystemExit("controller not found - press a button to wake it")
    return device


async def main(seconds: float, outfile: str, args: list[str]) -> None:
    """args is a script: hex tokens are commands, 'w<sec>' waits in between."""
    keepalive = next((a[3:].split("@") for a in args if a.startswith("ka=")), None)
    script = [a for a in args if not a.startswith("ka=")]
    device = await find_controller()
    start = time.monotonic()
    counts: dict[str, int] = {}
    with open(outfile, "w") as out:

        def log(src: str, data: bytes) -> None:
            rec = {"t": round(time.monotonic() - start, 4), "src": src, "hex": data.hex()}
            out.write(json.dumps(rec) + "\n")

        def handler_for(src: str):
            def handler(_char, data: bytearray) -> None:
                counts[src] = counts.get(src, 0) + 1
                log(src, bytes(data))

            return handler

        async with BleakClient(device) as client:

            async def send(cmd: str) -> None:
                await client.write_gatt_char(CMD_CHAR, bytes.fromhex(cmd), response=True)
                log("cmd", bytes.fromhex(cmd))

            for uuid, src in NOTIFY.items():
                try:
                    await client.start_notify(uuid, handler_for(src))
                except Exception as exc:
                    print(f"could not subscribe to {src}: {exc}")
            end = time.monotonic() + seconds
            print(f"recording {seconds}s -> {outfile}", flush=True)
            for token in script:
                if token.startswith("w"):
                    await asyncio.sleep(float(token[1:]))
                else:
                    await send(token)
            if keepalive:
                ka_cmd, interval = keepalive[0], float(keepalive[1])
                while time.monotonic() < end:
                    await asyncio.sleep(interval)
                    await send(ka_cmd)
            else:
                await asyncio.sleep(max(0.0, end - time.monotonic()))
            try:
                await client.write_gatt_char(CMD_CHAR, bytes.fromhex("0000"), response=True)
            except Exception:
                pass
    print("packet counts:", counts)


if __name__ == "__main__":
    asyncio.run(main(float(sys.argv[1]), sys.argv[2], sys.argv[3:]))
