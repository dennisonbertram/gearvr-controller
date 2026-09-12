"""Probe the controller for undocumented behaviour.

Sends the commands nobody has explained (0300, 0500, 0600, 0700 and a few beyond
0800) one at a time and watches everything that could react: the sensor stream,
the HID characteristics, the battery service, and the accelerometer's noise floor
- a vibration motor would show up as a burst of high-frequency accel noise while
the controller lies still.

0200 is deliberately never sent: jsyang's notes suspect it starts a firmware update.

usage: probe_features.py [seconds per command]
"""
import asyncio
import statistics
import struct
import sys

from bleak import BleakClient

from gearvr import CMD_CHAR, DATA_CHAR, Packet, find_controller

EXTRA_NOTIFY = {
    "00002a4d-0000-1000-8000-00805f9b34fb": "hid_report",
    "00002a22-0000-1000-8000-00805f9b34fb": "boot_keyboard",
    "00002a19-0000-1000-8000-00805f9b34fb": "battery_service",
    "5f78df94-798c-46f5-990a-b3eb6a065c88": "dialog_suota",
}
COMMANDS = ["0300", "0500", "0900", "0a00", "0f00", "0101", "0801", "0600", "0700"]
LABELS = {
    "0300": "calibrate?", "0500": "unknown setting?", "0600": "LPM enable?", "0700": "LPM disable?",
    "0900": "beyond the known range", "0a00": "beyond the known range", "0f00": "beyond the known range",
    "0101": "sensor with a non-zero argument", "0801": "VR mode with a non-zero argument",
}


class Watcher:
    def __init__(self):
        self.reset()

    def reset(self):
        self.packets = 0
        self.acks = []
        self.other = []
        self.accel = []
        self.gyro = []
        self.battery = set()
        self.temp = set()

    def on_data(self, _c, data):
        data = bytes(data)
        if len(data) == 60:
            self.packets += 1
            p = Packet if False else None
            for off in (0, 16, 32):
                ax, ay, az = struct.unpack_from("<3h", data, off + 4)
                gx, gy, gz = struct.unpack_from("<3h", data, off + 10)
                self.accel.append((ax, ay, az))
                self.gyro.append((gx, gy, gz))
            self.battery.add(data[59])
            self.temp.add(data[57])
        elif len(data) == 2:
            self.acks.append(data.hex())
        else:
            self.other.append(data.hex())

    def handler(self, name):
        def h(_c, data):
            self.other.append(f"{name}:{bytes(data).hex()}")
        return h

    def report(self, seconds):
        bits = [f"{self.packets / seconds:5.1f} pkt/s"]
        if self.accel:
            # high-frequency accel noise: mean |sample - previous sample|, a vibration motor
            # would push this far above the sensor's own noise floor
            diffs = [sum(abs(a - b) for a, b in zip(x, y)) for x, y in zip(self.accel, self.accel[1:])]
            gyro_mag = [max(abs(v) for v in g) for g in self.gyro]
            bits.append(f"accel jitter {statistics.mean(diffs):5.1f} LSB")
            bits.append(f"gyro max {max(gyro_mag):4d}")
        if self.acks:
            bits.append(f"acks {self.acks}")
        if self.battery:
            bits.append(f"battery {sorted(self.battery)}")
        if self.temp:
            bits.append(f"temp {sorted(self.temp)}")
        if self.other:
            bits.append(f"OTHER {self.other[:6]}")
        return "  ".join(bits)


async def main(seconds: float) -> None:
    device = await find_controller()
    watcher = Watcher()
    async with BleakClient(device) as client:
        await client.start_notify(DATA_CHAR, watcher.on_data)
        for uuid, name in EXTRA_NOTIFY.items():
            try:
                await client.start_notify(uuid, watcher.handler(name))
            except Exception as exc:
                print(f"  (cannot subscribe to {name}: {str(exc)[:60]})")

        async def send(cmd):
            await client.write_gatt_char(CMD_CHAR, bytes.fromhex(cmd), response=True)

        async def window(label, seconds=seconds):
            watcher.reset()
            await asyncio.sleep(seconds)
            print(f"{label:34s} {watcher.report(seconds)}", flush=True)

        # get a normal high-rate stream going first, so anything that disturbs it shows up
        await send("0800")
        await asyncio.sleep(2)
        await send("0100")
        await asyncio.sleep(1)
        await window("baseline (streaming, at rest)")

        for cmd in COMMANDS:
            await send(cmd)
            await window(f"after {cmd}  {LABELS.get(cmd, '')}")
            if watcher.packets == 0:  # something stopped the stream: restart it for the next test
                await send("0800")
                await asyncio.sleep(2)
                await send("0100")
                await asyncio.sleep(1)
                await window(f"  (stream restarted after {cmd})")

        await send("0000")
    print("\ndone")


if __name__ == "__main__":
    asyncio.run(main(float(sys.argv[1]) if len(sys.argv) > 1 else 4))
