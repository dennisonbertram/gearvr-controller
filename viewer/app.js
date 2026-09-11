import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { buildController } from './controller-model.js';
import { BluetoothSource, BridgeSource, DemoSource, Orientation, TOUCH_MAX } from './gearvr.js';

// ---------------------------------------------------------------- scene
const container = document.getElementById('scene');
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setSize(innerWidth, innerHeight);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
container.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.55;

const camera = new THREE.PerspectiveCamera(30, innerWidth / innerHeight, 1, 5000);
const VIEWS = { // camera presets (three.js Y-up world; the controller points toward -Z)
  hand: [-40, 120, 230],
  side: [260, 30, 20],
  top: [0, 300, 1],
  front: [-120, 70, -200],
};
camera.position.set(...VIEWS[new URLSearchParams(location.search).get('view')] ?? VIEWS.hand);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.target.set(0, -5, 0);
controls.minDistance = 110;
controls.maxDistance = 700;

const key = new THREE.DirectionalLight(0xffffff, 2.4);
key.position.set(-120, 260, 140);
key.castShadow = true;
key.shadow.mapSize.set(2048, 2048);
Object.assign(key.shadow.camera, { left: -150, right: 150, top: 150, bottom: -150, near: 10, far: 800 });
key.shadow.radius = 6;
key.shadow.bias = -0.0004;
scene.add(key);
const rim = new THREE.DirectionalLight(0x7fb4ff, 1.6);
rim.position.set(160, 60, -200);
scene.add(rim);
scene.add(new THREE.HemisphereLight(0xcfd8ff, 0x0c0e12, 0.35));

const ground = new THREE.Mesh(new THREE.PlaneGeometry(2000, 2000), new THREE.ShadowMaterial({ opacity: 0.32 }));
ground.rotation.x = -Math.PI / 2;
ground.position.y = -78;
ground.receiveShadow = true;
scene.add(ground);

// The model lives in the controller's sensor frame (Z up); convert to three's Y-up.
const world = new THREE.Group();
world.rotation.x = -Math.PI / 2;
scene.add(world);
const pivot = new THREE.Group();
world.add(pivot);
const model = buildController();
model.group.position.set(0, -2, 18); // rotate about the middle of the body
pivot.add(model.group);

// sensor-axis arrows (toggle with A)
const axes = new THREE.Group();
[[0xff5c6c, [1, 0, 0], 'X right'], [0x3ddc97, [0, 1, 0], 'Y forward'], [0x4aa3ff, [0, 0, 1], 'Z up']].forEach(([c, d]) => {
  axes.add(new THREE.ArrowHelper(new THREE.Vector3(...d), new THREE.Vector3(0, 0, 0), 80, c, 8, 4));
});
axes.visible = false;
pivot.add(axes);

addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

// ---------------------------------------------------------------- data
const $ = (id) => document.getElementById(id);
const fusion = new Orientation();
const yawOffset = new THREE.Quaternion();
const targetQ = new THREE.Quaternion();
let source = null, latest = null, connected = false, isDemo = false;
let pktCount = 0, sampleCount = 0, recenterPending = true, prevHome = false;
const gyroHist = [];
const padTrail = [];

function setStatus(text, live = false) {
  $('status').querySelector('span').textContent = text;
  $('status').classList.toggle('live', live);
}

function onPacket(pkt) {
  latest = pkt;
  pktCount++;
  for (const s of pkt.samples) {
    fusion.update(s);
    sampleCount++;
    gyroHist.push(s.gyro.map((g, i) => g - fusion.bias[i]));
  }
  if (gyroHist.length > 240) gyroHist.splice(0, gyroHist.length - 240);
  if (pkt.buttons.home && !prevHome) recenter();
  prevHome = pkt.buttons.home;
  if (recenterPending && fusion.warmup > 450) { recenter(); recenterPending = false; }
  if (pkt.touch.touching) {
    padTrail.push({ x: pkt.touch.x, y: pkt.touch.y, t: performance.now() });
  }
  model.setState(pkt, connected);
}

function currentQuat() {
  const [w, x, y, z] = fusion.q;
  return new THREE.Quaternion(x, y, z, w);
}

function recenter() {
  const f = new THREE.Vector3(0, 1, 0).applyQuaternion(currentQuat());
  const heading = Math.atan2(f.y, f.x);
  yawOffset.setFromAxisAngle(new THREE.Vector3(0, 0, 1), Math.PI / 2 - heading);
}

async function use(kind) {
  source?.disconnect();
  fusion.reset();
  recenterPending = true;
  connected = false;
  isDemo = kind === 'demo';
  const handlers = {
    onPacket,
    onStatus: (text) => {
      connected = /streaming/.test(text) || kind === 'demo';
      setStatus(text, /streaming/.test(text));
    },
  };
  source = kind === 'bluetooth' ? new BluetoothSource(handlers)
    : kind === 'bridge' ? new BridgeSource(handlers) : new DemoSource(handlers);
  try {
    await source.connect();
  } catch (err) {
    setStatus(`${kind}: ${err.message || err}`);
    if (kind !== 'demo') setTimeout(() => { if (!latest || !connected) use('demo'); }, 2500);
  }
}

if (BluetoothSource.supported) $('btnBluetooth').hidden = false;
$('btnBluetooth').onclick = () => use('bluetooth');
$('btnBridge').onclick = () => use('bridge');
$('btnDemo').onclick = () => use('demo');
$('btnRecenter').onclick = () => recenter();
$('btnAxes').onclick = () => { axes.visible = !axes.visible; };
addEventListener('keydown', (e) => {
  const preset = { 1: 'hand', 2: 'side', 3: 'top', 4: 'front' }[e.key];
  if (preset) camera.position.set(...VIEWS[preset]);
  if (e.key === 'r' || e.key === 'R') recenter();
  if (e.key === 'a' || e.key === 'A') axes.visible = !axes.visible;
});

const params = new URLSearchParams(location.search);
use(params.get('source') ?? (location.port === '8765' ? 'bridge' : 'demo'));

// ---------------------------------------------------------------- HUD
const FIELD_COLORS = (() => {
  const css = getComputedStyle(document.documentElement);
  const c = (n) => css.getPropertyValue(n).trim();
  const map = new Array(60);
  for (let k = 0; k < 3; k++) {
    for (let i = 0; i < 4; i++) map[k * 16 + i] = c('--f-ts');
    for (let i = 4; i < 10; i++) map[k * 16 + i] = c('--f-acc');
    for (let i = 10; i < 16; i++) map[k * 16 + i] = c('--f-gyr');
  }
  for (let i = 48; i < 54; i++) map[i] = c('--f-mag');
  for (let i = 54; i < 57; i++) map[i] = c('--f-touch');
  map[57] = c('--f-temp'); map[58] = c('--f-btn'); map[59] = c('--f-bat');
  return map;
})();
const hexEl = $('hex');
const hexSpans = FIELD_COLORS.map((color) => {
  const s = document.createElement('span');
  s.style.color = color;
  s.textContent = '··';
  hexEl.appendChild(s);
  return s;
});

function axisRows(el, labels) {
  el.innerHTML = labels.map((l) => `<span>${l}</span><div class="bar"><div></div></div><span>0</span>`).join('');
  const bars = [...el.querySelectorAll('.bar div')];
  const vals = [...el.querySelectorAll(':scope > span:nth-child(3n)')];
  return (values, range) => values.forEach((v, i) => {
    const f = Math.max(-1, Math.min(1, v / range)) * 50;
    bars[i].style.width = `${Math.abs(f)}%`;
    bars[i].style.left = f >= 0 ? '50%' : `${50 + f}%`;
    vals[i].textContent = v.toFixed(range > 10 ? 1 : 2).padStart(7);
  });
}
const setAcc = axisRows($('acc'), ['x', 'y', 'z']);
const setGyr = axisRows($('gyr'), ['x', 'y', 'z']);
const chips = [...document.querySelectorAll('.chip')];
const padCtx = $('pad').getContext('2d');
const sparkCtx = $('spark').getContext('2d');

function drawPad(pkt) {
  const c = padCtx, W = 180, R = 80;
  c.clearRect(0, 0, W, W);
  c.strokeStyle = 'rgba(255,255,255,0.18)'; c.lineWidth = 2;
  c.beginPath(); c.arc(W / 2, W / 2, R, 0, Math.PI * 2); c.stroke();
  const now = performance.now();
  while (padTrail.length && now - padTrail[0].t > 700) padTrail.shift();
  const toXY = (p) => [W / 2 + (p.x / TOUCH_MAX - 0.5) * 2 * R, W / 2 + (p.y / TOUCH_MAX - 0.5) * 2 * R];
  padTrail.forEach((p) => {
    const [x, y] = toXY(p);
    c.fillStyle = `rgba(74,163,255,${0.6 * (1 - (now - p.t) / 700)})`;
    c.beginPath(); c.arc(x, y, 5, 0, Math.PI * 2); c.fill();
  });
  if (pkt.touch.touching) {
    const [x, y] = toXY(pkt.touch);
    c.fillStyle = '#4aa3ff'; c.shadowColor = '#4aa3ff'; c.shadowBlur = 16;
    c.beginPath(); c.arc(x, y, 9, 0, Math.PI * 2); c.fill();
    c.shadowBlur = 0;
  }
}

function drawSpark() {
  const c = sparkCtx, W = 536, H = 120;
  c.clearRect(0, 0, W, H);
  c.strokeStyle = 'rgba(255,255,255,0.08)'; c.beginPath(); c.moveTo(0, H / 2); c.lineTo(W, H / 2); c.stroke();
  const range = Math.max(30, ...gyroHist.flat().map(Math.abs));
  ['#ff5c6c', '#3ddc97', '#b07cff'].forEach((col, axis) => {
    c.strokeStyle = col; c.lineWidth = 2; c.beginPath();
    gyroHist.forEach((g, i) => {
      const x = (i / 239) * W, y = H / 2 - (g[axis] / range) * (H / 2 - 4);
      i ? c.lineTo(x, y) : c.moveTo(x, y);
    });
    c.stroke();
  });
}

let lastHud = 0, lastRate = performance.now(), rateP = 0, rateS = 0;
function updateHud(now) {
  if (now - lastRate >= 1000) {
    rateP = pktCount * 1000 / (now - lastRate);
    rateS = sampleCount * 1000 / (now - lastRate);
    pktCount = sampleCount = 0;
    lastRate = now;
  }
  if (!latest || now - lastHud < 50) return;
  lastHud = now;
  const p = latest, s = p.samples[2];
  $('battery').textContent = `${p.battery}%`;
  $('batteryBar').style.width = `${p.battery}%`;
  $('temp').textContent = `${p.temperature} °C`;
  $('rate').textContent = rateP.toFixed(1);
  $('srate').textContent = rateS.toFixed(0);
  $('bias').textContent = isDemo ? 'n/a (demo)'
    : fusion.calibrated ? fusion.bias.map((b) => b.toFixed(1)).join(' ') + ' °/s' : 'hold still…';
  chips.forEach((ch) => ch.classList.toggle('on', !!p.buttons[ch.dataset.b]));
  $('touchState').textContent = p.touch.touching ? 'touching' : p.touch.lifted ? 'lifted' : 'up';
  $('touchX').textContent = p.touch.touching ? p.touch.x : '–';
  $('touchY').textContent = p.touch.touching ? p.touch.y : '–';
  const e = new THREE.Euler().setFromQuaternion(pivot.quaternion, 'ZXY');
  $('yaw').textContent = `${THREE.MathUtils.radToDeg(e.z).toFixed(1)}°`;
  $('pitch').textContent = `${THREE.MathUtils.radToDeg(e.x).toFixed(1)}°`;
  $('roll').textContent = `${THREE.MathUtils.radToDeg(e.y).toFixed(1)}°`;
  setAcc(s.accel, 2);
  setGyr(s.gyro.map((g, i) => g - fusion.bias[i]), 250);
  $('mag').textContent = p.mag.join('  ');
  p.raw.forEach((b, i) => { hexSpans[i].textContent = b.toString(16).padStart(2, '0'); });
  drawPad(p);
  drawSpark();
}

// ---------------------------------------------------------------- loop
const clock = new THREE.Clock();
renderer.setAnimationLoop(() => {
  const dt = Math.min(clock.getDelta(), 0.1);
  targetQ.copy(yawOffset).multiply(currentQuat());
  pivot.quaternion.slerp(targetQ, 1 - Math.exp(-dt * 25));
  model.update(dt);
  controls.update();
  updateHud(performance.now());
  renderer.render(scene, camera);
});
