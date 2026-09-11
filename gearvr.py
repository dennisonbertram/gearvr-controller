"""Driver for the Samsung Gear VR Controller (ET-YO324 / SM-R324) over BLE.

See PROTOCOL.md for the full, hardware-verified protocol description. In short:
  * Service 4f63756c-7573-2054-6872-65656d6f7465 ("Oculus Three Remote" in ASCII)
  * Write 2-byte commands to ...d282; data arrives as notifications on ...d281
  * Commands are acknowledged by a 2-byte notification echoing them
  * 60-byte packets: three 16-byte IMU samples, magnetometer, touchpad,
    temperature, buttons, battery
"""
import asyncio
import struct
from dataclasses import dataclass

from bleak import BleakClient, BleakScanner

NAME_PREFIX = "Gear VR Controller"
DATA_CHAR = "c8c51726-81bc-483b-a052-f7a14ea3d281"
CMD_CHAR = "c8c51726-81bc-483b-a052-f7a14ea3d282"
BATTERY_CHAR = "00002a19-0000-1000-8000-00805f9b34fb"

CMD_OFF = "0000"
CMD_SENSOR = "0100"
CMD_KEEPALIVE = "0400"
CMD_VR_MODE = "0800"

ACCEL_LSB_PER_G = 2048.0  # +/-16 g
GYRO_LSB_PER_DPS = 14.285  # +/-2000 dps, 70 mdps/LSB
TOUCH_MAX = 315  # circular pad, both axes span roughly 0..315

BUTTON_BITS = {
    "trigger": 0x01,
    "home": 0x02,
    "back": 0x04,
    "touchpad": 0x08,
    "volume_up": 0x10,
    "volume_down": 0x20,
}
IDLE_BIT = 0x40  # set when no button has been pressed for ~20 ms


@dataclass(frozen=True)
class ImuSample:
    timestamp_us: int  # device clock, microseconds, wraps at 2**32
    accel_g: tuple[float, float, float]  # +X right, +Y forward, +Z out of touchpad
    gyro_dps: tuple[float, float, float]  # same axes, right-hand rule


@dataclass(frozen=True)
class Touch:
    touching: bool
    lifted: bool  # True for exactly one packet when the finger leaves the pad
    x: int  # 0 (left) .. ~315 (right)
    y: int  # 0 (far edge) .. ~315 (near edge, toward the user)


@dataclass(frozen=True)
class Packet:
    samples: tuple[ImuSample, ImuSample, ImuSample]
    mag_raw: tuple[int, int, int]  # uncalibrated; all zero for ~1 s after start
    touch: Touch
    temperature_c: int
    buttons: frozenset[str]
    battery: int
    raw: bytes

    @property
    def latest(self) -> ImuSample:
        return self.samples[-1]


def parse(data: bytes) -> Packet:
    if len(data) != 60:
        raise ValueError(f"expected 60 bytes, got {len(data)}")
    samples = []
    for off in (0, 16, 32):
        ts, ax, ay, az, gx, gy, gz = struct.unpack_from("<I6h", data, off)
        samples.append(ImuSample(
            ts,
            (ax / ACCEL_LSB_PER_G, ay / ACCEL_LSB_PER_G, az / ACCEL_LSB_PER_G),
            (gx / GYRO_LSB_PER_DPS, gy / GYRO_LSB_PER_DPS, gz / GYRO_LSB_PER_DPS),
        ))
    b54, b55, b56 = data[54], data[55], data[56]
    touch = Touch(
        touching=bool(b54 & 0x10),
        lifted=(b54 & 0x30) == 0,
        x=((b54 & 0x0F) << 6) | (b55 >> 2),
        y=((b55 & 0x03) << 8) | b56,
    )
    buttons = frozenset(name for name, bit in BUTTON_BITS.items() if data[58] & bit)
    return Packet(
        samples=tuple(samples),
        mag_raw=struct.unpack_from("<3h", data, 48),
        touch=touch,
        temperature_c=data[57],
        buttons=buttons,
        battery=data[59],
        raw=bytes(data),
    )


async def find_controller(timeout: float = 20.0):
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: (adv.local_name or d.name or "").startswith(NAME_PREFIX),
        timeout=timeout,
    )
    if device is None:
        raise RuntimeError("Gear VR Controller not found - press a button to wake it")
    return device


class Controller:
    """Async context manager that connects and delivers parsed packets.

    on_packet(Packet) is called for every 60-byte packet; on_raw(bytes) for every
    notification on the data characteristic (including 2-byte command acks).
    """

    def __init__(self, on_packet=None, on_raw=None, on_disconnect=None):
        self.on_packet = on_packet
        self.on_raw = on_raw
        self.on_disconnect = on_disconnect
        self.client: BleakClient | None = None
        self._ack: asyncio.Queue[bytes] = asyncio.Queue()
        self._keepalive: asyncio.Task | None = None

    async def __aenter__(self):
        device = await find_controller()
        self.client = BleakClient(device, disconnected_callback=self._disconnected)
        await self.client.connect()
        await self.client.start_notify(DATA_CHAR, self._on_notify)
        return self

    async def __aexit__(self, *exc):
        if self._keepalive:
            self._keepalive.cancel()
        if self.client.is_connected:
            try:
                await self.send(CMD_OFF, wait_ack=False)
            finally:
                await self.client.disconnect()

    def _disconnected(self, _client) -> None:
        if self._keepalive:
            self._keepalive.cancel()
        if self.on_disconnect:
            self.on_disconnect()

    def _on_notify(self, _char, data: bytearray) -> None:
        data = bytes(data)
        if self.on_raw:
            self.on_raw(data)
        if len(data) == 60:
            if self.on_packet:
                self.on_packet(parse(data))
        elif len(data) == 2:
            self._ack.put_nowait(data)

    async def send(self, cmd: str, wait_ack: bool = True, timeout: float = 4.0) -> bool:
        while not self._ack.empty():
            self._ack.get_nowait()
        await self.client.write_gatt_char(CMD_CHAR, bytes.fromhex(cmd), response=True)
        if not wait_ack:
            return True
        try:
            ack = await asyncio.wait_for(self._ack.get(), timeout)
            return ack == bytes.fromhex(cmd)
        except asyncio.TimeoutError:
            return False

    async def start_vr_stream(self, keepalive_interval: float = 3.0) -> None:
        """High-rate streaming: ~68 packets/s = ~206 Hz IMU.

        0800 takes ~1.5 s to be acknowledged; sending 0100 before the ack
        arrives makes the controller stop streaming shortly afterwards.
        """
        if not await self.send(CMD_VR_MODE):
            raise RuntimeError("controller did not acknowledge VR mode")
        await self.send(CMD_SENSOR, wait_ack=False)
        if keepalive_interval:
            self._keepalive = asyncio.create_task(self._keepalive_loop(keepalive_interval))

    async def start_sensor_stream(self) -> None:
        """Low-rate streaming (~30 packets/s, gappy); no VR-mode handshake."""
        await self.send(CMD_SENSOR, wait_ack=False)

    async def _keepalive_loop(self, interval: float) -> None:
        while True:
            await asyncio.sleep(interval)
            try:
                await self.send(CMD_KEEPALIVE, wait_ack=False)
            except Exception:
                return

    async def battery(self) -> int:
        return (await self.client.read_gatt_char(BATTERY_CHAR))[0]
