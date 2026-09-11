"""Connect to the Gear VR Controller and dump its full GATT table."""
import asyncio

from bleak import BleakClient, BleakScanner

NAME_PREFIX = "Gear VR Controller"


def show(data: bytes) -> str:
    text = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
    return f"{data.hex()}  |{text}|"


async def main() -> None:
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: (adv.local_name or d.name or "").startswith(NAME_PREFIX),
        timeout=15,
    )
    if device is None:
        raise SystemExit("controller not found - press a button to wake it")
    print(f"connecting to {device.name} ({device.address})")
    async with BleakClient(device) as client:
        for service in client.services:
            print(f"\n[service] {service.uuid}  {service.description}")
            for char in service.characteristics:
                props = ",".join(char.properties)
                print(f"  [char] {char.uuid}  h={char.handle}  ({props})  {char.description}")
                if "read" in char.properties:
                    try:
                        print(f"      value: {show(await client.read_gatt_char(char))}")
                    except Exception as exc:
                        print(f"      read failed: {exc}")
                for desc in char.descriptors:
                    try:
                        value = show(await client.read_gatt_descriptor(desc.handle))
                    except Exception as exc:
                        value = f"read failed: {exc}"
                    print(f"      [desc] {desc.uuid}  h={desc.handle}  {value}")


if __name__ == "__main__":
    asyncio.run(main())
