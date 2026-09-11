// Gear VR Controller protocol for the browser: packet decoder, data sources
// (Web Bluetooth, local WebSocket bridge, demo) and 6-axis orientation fusion.
// Mirrors gearvr.py; see PROTOCOL.md for the byte layout.

export const SERVICE = '4f63756c-7573-2054-6872-65656d6f7465';
export const DATA_CHAR = 'c8c51726-81bc-483b-a052-f7a14ea3d281';
export const CMD_CHAR = 'c8c51726-81bc-483b-a052-f7a14ea3d282';

const ACCEL_LSB_PER_G = 2048;
const GYRO_LSB_PER_DPS = 14.285;
export const TOUCH_MAX = 315;
export const BUTTONS = ['trigger', 'home', 'back', 'touchpad', 'volume_up', 'volume_down'];

export function parsePacket(buf) {
  const v = new DataView(buf.buffer ?? buf, buf.byteOffset ?? 0, 60);
  const samples = [0, 16, 32].map((o) => ({
    t: v.getUint32(o, true),
    accel: [v.getInt16(o + 4, true), v.getInt16(o + 6, true), v.getInt16(o + 8, true)].map((a) => a / ACCEL_LSB_PER_G),
    gyro: [v.getInt16(o + 10, true), v.getInt16(o + 12, true), v.getInt16(o + 14, true)].map((g) => g / GYRO_LSB_PER_DPS),
  }));
  const b54 = v.getUint8(54), b55 = v.getUint8(55), b56 = v.getUint8(56), b58 = v.getUint8(58);
  const buttons = {};
  BUTTONS.forEach((name, i) => { buttons[name] = !!(b58 & (1 << i)); });
  return {
    raw: new Uint8Array(v.buffer, v.byteOffset, 60),
    samples,
    mag: [v.getInt16(48, true), v.getInt16(50, true), v.getInt16(52, true)],
    touch: {
      touching: !!(b54 & 0x10),
      lifted: (b54 & 0x30) === 0,
      x: ((b54 & 0x0f) << 6) | (b55 >> 2),
      y: ((b55 & 0x03) << 8) | b56,
    },
    temperature: v.getUint8(57),
    buttons,
    battery: v.getUint8(59),
  };
}

// ---------------------------------------------------------------------------
// Data sources. Each emits: onStatus(text), onPacket(packet)

class Source {
  constructor({ onStatus, onPacket }) { this.onStatus = onStatus; this.onPacket = onPacket; }
  handleRaw(bytes) {
    if (bytes.byteLength === 60) this.onPacket(parsePacket(bytes));
  }
}

export class BluetoothSource extends Source {
  static get supported() { return !!navigator.bluetooth; }

  async connect() {
    this.onStatus('choose the controller…');
    this.device = await navigator.bluetooth.requestDevice({
      filters: [{ namePrefix: 'Gear VR Controller' }],
      optionalServices: [SERVICE],
    });
    this.device.addEventListener('gattserverdisconnected', () => {
      clearInterval(this.keepalive);
      this.onStatus('disconnected');
    });
    this.onStatus('connecting');
    const server = await this.device.gatt.connect();
    const service = await server.getPrimaryService(SERVICE);
    this.data = await service.getCharacteristic(DATA_CHAR);
    this.cmd = await service.getCharacteristic(CMD_CHAR);
    let ackResolve = null;
    this.data.addEventListener('characteristicvaluechanged', (e) => {
      const dv = e.target.value;
      const bytes = new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength);
      if (bytes.length === 2 && ackResolve) { ackResolve(bytes); ackResolve = null; }
      this.handleRaw(bytes);
    });
    await this.data.startNotifications();
    // VR mode must be acknowledged (~1.5 s) before starting the stream.
    const ack = new Promise((res) => { ackResolve = res; });
    await this.send([0x08, 0x00]);
    this.onStatus('waiting for VR-mode ack');
    await Promise.race([ack, new Promise((r) => setTimeout(r, 4000))]);
    await this.send([0x01, 0x00]);
    this.keepalive = setInterval(() => this.send([0x04, 0x00]).catch(() => {}), 3000);
    this.onStatus(`streaming · ${this.device.name}`);
  }

  send(bytes) { return this.cmd.writeValueWithResponse(new Uint8Array(bytes)); }

  disconnect() {
    clearInterval(this.keepalive);
    if (this.device?.gatt.connected) {
      this.send([0x00, 0x00]).finally(() => this.device.gatt.disconnect());
    }
  }
}

export class BridgeSource extends Source {
  connect(url = `ws://${location.hostname || 'localhost'}:8765/ws`) {
    return new Promise((resolve, reject) => {
      this.onStatus('connecting to bridge');
      const ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      this.ws = ws;
      ws.onopen = () => resolve();
      ws.onerror = () => reject(new Error('bridge not reachable'));
      ws.onclose = () => this.onStatus('bridge closed');
      ws.onmessage = (e) => {
        const bytes = new Uint8Array(e.data);
        if (bytes[0] === 0x53 && bytes.length !== 60) { // 'S' + status text
          this.onStatus('bridge · ' + new TextDecoder().decode(bytes.subarray(1)));
        } else {
          this.handleRaw(bytes);
        }
      };
    });
  }

  disconnect() { this.ws?.close(); }
}

// Inverse of parsePacket, used by the demo so it exercises the real decoder.
export function encodePacket({ samples, mag, touch, temperature, buttons, battery }) {
  const bytes = new Uint8Array(60);
  const v = new DataView(bytes.buffer);
  samples.forEach((s, k) => {
    const o = k * 16;
    v.setUint32(o, s.t >>> 0, true);
    s.accel.forEach((a, i) => v.setInt16(o + 4 + 2 * i, Math.round(a * ACCEL_LSB_PER_G), true));
    s.gyro.forEach((g, i) => v.setInt16(o + 10 + 2 * i, Math.round(g * GYRO_LSB_PER_DPS), true));
  });
  mag.forEach((m, i) => v.setInt16(48 + 2 * i, m, true));
  if (touch.touching) {
    const x = Math.round(touch.x), y = Math.round(touch.y);
    bytes[54] = 0x10 | (x >> 6); bytes[55] = ((x & 0x3f) << 2) | (y >> 8); bytes[56] = y & 0xff;
  } else {
    bytes[54] = touch.lifted ? 0x00 : 0x20;
  }
  bytes[57] = temperature;
  let b = 0;
  BUTTONS.forEach((name, i) => { if (buttons[name]) b |= 1 << i; });
  bytes[58] = b || 0x40;
  bytes[59] = battery;
  return bytes;
}

// small quaternion helpers, [w, x, y, z]
const qmul = (a, b) => [
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
];
const qconj = (q) => [q[0], -q[1], -q[2], -q[3]];
const qaxis = (ax, ang) => [Math.cos(ang / 2), ...ax.map((c) => c * Math.sin(ang / 2))];
const qrot = (q, v) => qmul(qmul(q, [0, ...v]), qconj(q)).slice(1);

// Synthesized, physically consistent motion so the page is alive without hardware.
export class DemoSource extends Source {
  connect() {
    this.onStatus('demo · no controller connected');
    const d2r = Math.PI / 180;
    const pose = (s) => {
      const yaw = 28 * Math.sin(s * 0.45) * d2r;
      const pitch = (14 * Math.sin(s * 0.7) + 8) * d2r;
      const roll = 12 * Math.sin(s * 0.38 + 1) * d2r;
      return qmul(qmul(qaxis([0, 0, 1], yaw), qaxis([1, 0, 0], pitch)), qaxis([0, 1, 0], roll));
    };
    let t = 0;
    const start = performance.now();
    this.timer = setInterval(() => {
      const now = (performance.now() - start) / 1000;
      const samples = [0, 1, 2].map((k) => {
        const s = now + k * 0.00485, h = 0.001;
        const q = pose(s), q2 = pose(s + h);
        const dq = q2.map((c, i) => (c - q[i]) / h);
        const w = qmul(qconj(q), dq).slice(1).map((c) => (2 * c) / d2r);
        t += 4850;
        return { t, accel: qrot(qconj(q), [0, 0, 1]), gyro: w };
      });
      const phase = now % 14;
      const touching = phase > 2 && phase < 5.5;
      const a = now * 2.4;
      const buttons = {};
      const slot = Math.floor(now) % 14;
      BUTTONS.forEach((b, i) => { buttons[b] = slot === 7 + i && now % 1 < 0.35; });
      this.handleRaw(encodePacket({
        samples,
        mag: [6000, -600, 150],
        touch: { touching, lifted: false, x: 157 + Math.cos(a) * 105, y: 157 + Math.sin(a) * 105 },
        temperature: 24,
        buttons,
        battery: 100,
      }));
    }, 1000 / 68);
  }

  disconnect() { clearInterval(this.timer); }
}

// ---------------------------------------------------------------------------
// Orientation: Madgwick 6-axis filter + automatic gyro bias calibration.
// Frame: +X right, +Y forward (far end), +Z out of the touchpad; world Z is up.

export class Orientation {
  constructor() {
    this.q = [1, 0, 0, 0]; // w, x, y, z  (body -> world)
    this.bias = [0, 0, 0];
    this.calibrated = false;
    this.window = [];
    this.lastT = null;
    this.warmup = 0;
    this.beta = 0.04;
  }

  reset() { this.q = [1, 0, 0, 0]; this.warmup = 0; this.lastT = null; }

  update(sample) {
    const g = sample.gyro;
    this.trackBias(g);
    if (this.lastT === null) { this.lastT = sample.t; return; }
    let dt = ((sample.t - this.lastT) >>> 0) / 1e6;
    this.lastT = sample.t;
    if (!(dt > 0 && dt < 0.1)) return;
    const d2r = Math.PI / 180;
    const gx = (g[0] - this.bias[0]) * d2r, gy = (g[1] - this.bias[1]) * d2r, gz = (g[2] - this.bias[2]) * d2r;
    // converge quickly from the start, then trust the gyro more
    const beta = this.warmup++ < 400 ? 2.5 : this.beta;
    madgwick(this.q, gx, gy, gz, sample.accel, beta, dt);
  }

  trackBias(g) {
    this.window.push(g);
    if (this.window.length < 100) return;
    const mean = [0, 1, 2].map((i) => this.window.reduce((s, v) => s + v[i], 0) / this.window.length);
    const sd = [0, 1, 2].map((i) => Math.sqrt(this.window.reduce((s, v) => s + (v[i] - mean[i]) ** 2, 0) / this.window.length));
    this.window = [];
    if (Math.max(...sd) >= 0.8) return;
    if (!this.calibrated) { this.bias = mean; this.calibrated = true; return; }
    if (mean.every((m, i) => Math.abs(m - this.bias[i]) < 3)) {
      this.bias = this.bias.map((b, i) => b + 0.2 * (mean[i] - b));
    }
  }
}

function madgwick(q, gx, gy, gz, accel, beta, dt) {
  let [q0, q1, q2, q3] = q;
  let [ax, ay, az] = accel;
  let qDot1 = 0.5 * (-q1 * gx - q2 * gy - q3 * gz);
  let qDot2 = 0.5 * (q0 * gx + q2 * gz - q3 * gy);
  let qDot3 = 0.5 * (q0 * gy - q1 * gz + q3 * gx);
  let qDot4 = 0.5 * (q0 * gz + q1 * gy - q2 * gx);
  const norm = Math.hypot(ax, ay, az);
  if (norm > 0.5 && norm < 1.5) {
    ax /= norm; ay /= norm; az /= norm;
    const _2q0 = 2 * q0, _2q1 = 2 * q1, _2q2 = 2 * q2, _2q3 = 2 * q3;
    const _4q0 = 4 * q0, _4q1 = 4 * q1, _4q2 = 4 * q2, _8q1 = 8 * q1, _8q2 = 8 * q2;
    const q0q0 = q0 * q0, q1q1 = q1 * q1, q2q2 = q2 * q2, q3q3 = q3 * q3;
    let s0 = _4q0 * q2q2 + _2q2 * ax + _4q0 * q1q1 - _2q1 * ay;
    let s1 = _4q1 * q3q3 - _2q3 * ax + 4 * q0q0 * q1 - _2q0 * ay - _4q1 + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * az;
    let s2 = 4 * q0q0 * q2 + _2q0 * ax + _4q2 * q3q3 - _2q3 * ay - _4q2 + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * az;
    let s3 = 4 * q1q1 * q3 - _2q1 * ax + 4 * q2q2 * q3 - _2q2 * ay;
    const sn = Math.hypot(s0, s1, s2, s3) || 1;
    qDot1 -= beta * s0 / sn; qDot2 -= beta * s1 / sn; qDot3 -= beta * s2 / sn; qDot4 -= beta * s3 / sn;
  }
  q0 += qDot1 * dt; q1 += qDot2 * dt; q2 += qDot3 * dt; q3 += qDot4 * dt;
  const qn = Math.hypot(q0, q1, q2, q3);
  q[0] = q0 / qn; q[1] = q1 / qn; q[2] = q2 / qn; q[3] = q3 / qn;
}
