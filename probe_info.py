"""Second probe pass: read the 0300 and 0500 reports properly, check they're stable,
and sweep the remaining command values.

usage: probe_info.py
"""
import asyncio
import struct

from bleak import BleakClient

from gearvr import CMD_CHAR, DATA_CHAR, find_controller


def dump(data: bytes) -> str:
    text = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
    return f"{len(data)} bytes  |{text}|"


def as_words(data: bytes) -> str:
    n = len(data) // 4
    return " ".join(str(v) for v in struct.unpack_from(f"<{n}I", data))


async def main() -> None:
    device = await find_controller()
    blobs: dict[str, list[bytes]] = {}
    current = {"cmd": "?"}

    def on_data(_c, data):
        data = bytes(data)
        if len(data) not in (60, 2):
            blobs.setdefault(current["cmd"], []).append(data)

    async with BleakClient(device) as client:
        await client.start_notify(DATA_CHAR, on_data)

        async def ask(cmd: str, wait: float = 2.5) -> list[bytes]:
            current["cmd"] = cmd
            blobs[cmd] = []
            await client.write_gatt_char(CMD_CHAR, bytes.fromhex(cmd), response=True)
            await asyncio.sleep(wait)
            return blobs[cmd]

        print("== 0300, three times (identical => stored calibration, not live data)")
        runs = []
        for i in range(3):
            got = await ask("0300")
            runs.append(b"".join(got))
            print(f"  run {i + 1}: {dump(runs[-1])}")
        print(f"  identical: {len(set(runs)) == 1}")
        if runs[0]:
            print(f"  as int16 LE: {struct.unpack_from('<%dh' % (len(runs[0]) // 2), runs[0])}")

        print("\n== 0500 device record")
        rec = b"".join(await ask("0500"))
        print(f"  {dump(rec)}")
        if len(rec) >= 44:
            print(f"  leading words: {as_words(rec[:44])}")
            print(f"  text tail: {rec[44:].split(bytes([0]))[0].decode(errors='replace')}")

        print("\n== remaining command values")
        for cmd in ["0b00", "0c00", "0d00", "0e00", "1000", "0301", "0501", "0400"]:
            got = await ask(cmd, 1.5)
            print(f"  {cmd}: {[dump(g) for g in got] if got else 'nothing'}")

        print("\n== command characteristic read-back")
        try:
            print(f"  value: {bytes(await client.read_gatt_char(CMD_CHAR)).hex() or '(empty)'}")
        except Exception as exc:
            print(f"  read failed: {exc}")

        await client.write_gatt_char(CMD_CHAR, bytes.fromhex("0000"), response=True)


if __name__ == "__main__":
    asyncio.run(main())
