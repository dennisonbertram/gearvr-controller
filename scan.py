"""Scan for nearby BLE devices and print everything we can see."""
import asyncio
import sys

from bleak import BleakScanner


async def main(seconds: float) -> None:
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    rows = sorted(found.values(), key=lambda da: -da[1].rssi)
    for device, adv in rows:
        name = adv.local_name or device.name or "?"
        print(f"{device.address}  rssi={adv.rssi:4d}  name={name!r}")
        if adv.service_uuids:
            print(f"    services: {adv.service_uuids}")
        if adv.manufacturer_data:
            for cid, data in adv.manufacturer_data.items():
                print(f"    mfr 0x{cid:04x}: {data.hex()}")


if __name__ == "__main__":
    asyncio.run(main(float(sys.argv[1]) if len(sys.argv) > 1 else 10))
