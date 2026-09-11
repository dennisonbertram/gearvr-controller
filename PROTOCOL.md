# Samsung Gear VR Controller BLE protocol

Verified on real hardware, an **ET-YO324** (SM-R324) with firmware `YO324XXU0AQC1`,
talking to macOS through CoreBluetooth (bleak). The recordings are in `caps/`, and
`test_gearvr.py` checks the decoder against real packets.

Items marked **(new)** differ from, or aren't covered by, the earlier public work
(jsyang/gearvr-controller-webbluetooth, gb2111/Access-GearVR-Controller-from-PC,
polygraphene/FreePIEVRController).

## Advertising

* Local name: `Gear VR Controller(XXXX)`. The suffix is the first two bytes of the
  BLE address, reversed (`6A:46:…` becomes `466A`).
* Manufacturer data, company `0x0075` (Samsung): `01 00 02 00 fb 01 02 0e 03` +
  ASCII `vrsetupwizard` + `10`.

## GATT table

| Service | Characteristic | Props | Notes |
|---|---|---|---|
| `180F` Battery | `2A19` | read, notify | percent |
| `180A` Device Info | `2A29` / `2A24` / `2A26` … | read | "Samsung", "ET-YO324", fw `YO324XXU0AQC1`, serial "123456" |
| `1879` (HID-over-GATT layout, non-standard UUID) **(new)** | `2A4E` protocol mode, `2A4B` report map, `2A4D` report (ref: ID 3, input), `2A22`/`2A32` boot kbd | | reading any of these requires encryption, which triggers bonding |
| `4f63756c-7573-2054-6872-65656d6f7465` ("Oculus Three Remote") | `c8c51726-81bc-483b-a052-f7a14ea3d281` | read, notify | **data** |
| | `c8c51726-81bc-483b-a052-f7a14ea3d282` | read, write | **commands** |
| `FEF5` Dialog Semiconductor SUOTA | 9 characteristics | | firmware-update service; don't touch |

## Commands (write 2 bytes to `…d282`)

| Cmd | Meaning | Observed behaviour |
|---|---|---|
| `0000` | off | stops streaming |
| `0100` | sensor / start streaming | alone: ~30 pkt/s with gaps. After an acked `0800`: **68 pkt/s, no drops** |
| `0400` | keep-alive | no ack, doesn't disturb the stream |
| `0800` | VR mode (high rate) | **acked after ~1.5 s (new)**, see below |
| `0200`, `0300`, `0500`, `0600`, `0700` | fw-update?, calibrate, "setting", LPM on/off | not exercised; `0200` may enter firmware update |

### Command acknowledgement (new)

Once a command has been applied, the controller sends a **2-byte notification on
`…d281` echoing the command**. For `0800` this takes about 1.5 s, which is
probably a connection-parameter update to a faster interval.

The ordering matters:

* `0800` → wait for the `08 00` ack → `0100`: steady 68 pkt/s indefinitely (the right way).
* `0800` then `0100` straight away: streams fast for ~1.5 s, then the controller echoes `01 00` and **stops**.
* `0100` then `0800`: streaming stops immediately, then `08 00` is echoed ~1.5 s later.

This is probably why some earlier projects only ever got the slow, gappy rate.

## Data packet (60 bytes, little-endian)

Each packet carries **three IMU samples** (new). Earlier code read only one sample
and took bytes 32–37 as the magnetometer, but those bytes are sample 3's timestamp
and accelerometer.

| Bytes | Field |
|---|---|
| 0–3 | sample 1 timestamp, uint32, **microseconds** |
| 4–9 | sample 1 accel x, y, z, int16 |
| 10–15 | sample 1 gyro x, y, z, int16 |
| 16–31 | sample 2 (same layout) |
| 32–47 | sample 3 (same layout) |
| 48–53 | magnetometer x, y, z, int16, raw. All zero for the first ~1 s after streaming starts |
| 54–56 | touchpad (see below) |
| 57 | temperature, °C (rose 25 → 28 while held) |
| 58 | buttons (see below) |
| 59 | battery, percent |

### IMU

* Sample rate: **~206 Hz** (Δt ≈ 4850 µs), 3 samples per packet at 68 pkt/s.
* Accelerometer: **2048 LSB/g** (±16 g). At rest, |a| reads 2030–2100.
* Gyroscope: **14.285 LSB/(°/s)** (70 mdps/LSB, ±2000 °/s). Fitted independently
  at 14.40 by integrating the gyro between static poses and matching the change in
  gravity direction (≈1° error). 16.4 and 32.8 are clearly wrong.
  Typical zero-rate bias is around (−1.1, −4.5, +1.8) °/s, so compensate for it.
* **Axes (new, verified):** right-handed.
  +X = right, +Y = forward (toward the far/trigger end), +Z = out of the
  touchpad face. The gyro uses the same axes with the right-hand rule, so turning
  left gives +Z and raising the nose gives +X.
* Magnetometer: raw int16 with a large hard-iron offset (x ≈ +6000). Scale and
  axis alignment weren't determined; that needs a dedicated calibration away from
  metal and laptop magnets.

### Touchpad (bytes 54–56)

```
b54: 0 0 S S x x x x      SS = 01 touching, 10 not touching, 00 finger just lifted (one packet)
b55: x x x x x x y y
b56: y y y y y y y y
x = ((b54 & 0x0F) << 6) | (b55 >> 2)      0 = left      .. ~315 = right
y = ((b55 & 0x03) << 8) | b56             0 = far edge  .. ~315 = near edge
```

The pad is circular (x and y each span about 7–314 around the rim). Idle is
`20 00 00`. The one-packet `00 00 00` lift marker **(new)** gives clean tap
detection. The "unknown" 9-bit fields in gb2111's C# port are these coordinates.

### Buttons (byte 58)

| Bit | Mask | Button |
|---|---|---|
| 0 | `0x01` | trigger |
| 1 | `0x02` | home |
| 2 | `0x04` | back |
| 3 | `0x08` | touchpad click |
| 4 | `0x10` | **volume up** |
| 5 | `0x20` | **volume down** |
| 6 | `0x40` | idle flag **(new)**: clear while any button is down, set ~20 ms after release |

The gb2111 port has the volume bits swapped; jsyang's is right.

## HID consumer channel (new)

When the data stream isn't running, the controller can send **consumer-control
reports** on the HID `2A4D` characteristic (report ID 3, 16-bit usage):
`EA 00` (Volume Decrement) on press, `00 00` on release. Only volume-down was
captured this way, and nothing arrived after a VR-mode session was stopped. The
HID report map also declares a keyboard (report 1) and a vendor report 2 (1 byte,
0–100), but neither has been seen in use.

## Pairing gotchas

* Subscribing to or reading the HID characteristics makes macOS **bond** with the
  controller. The Oculus service works fine without bonding.
* **Holding HOME** for a few seconds puts the controller into pairing mode and
  **erases its bond**. After that, macOS fails with `CBErrorDomain 14 "Peer
  removed pairing information"` until you use *System Settings → Bluetooth →
  Forget This Device*. (`blueutil --unpair` doesn't work on current macOS.)
