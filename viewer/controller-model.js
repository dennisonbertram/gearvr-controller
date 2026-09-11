// Procedural, to-scale model of the Samsung Gear VR Controller (ET-YO324).
// Units are millimetres, in the controller's own sensor frame:
//   +X right, +Y forward (toward the touchpad end), +Z out of the touchpad face.
// Overall 108.1 x 38.2 x 48.1 mm (Samsung spec). Layout measured from product photos.
import * as THREE from 'three';

// --- plan-view outline: round head + straight handle + concave fillets -------
const HEAD_R = 19.1;
const HEAD_Y = 54.0 - HEAD_R; // head centre (front tip at y = +54)
const HALF_W = 13.6; // handle half-width
const END_Y = -54.1 + HALF_W; // end-cap centre
const FILLET_R = 8;
const FILLET_CX = HALF_W + FILLET_R;
const FILLET_CY = HEAD_Y - Math.sqrt((HEAD_R + FILLET_R) ** 2 - FILLET_CX ** 2);
export const LAYOUT = {
  headY: HEAD_Y,
  padR: 15.0,
  back: { x: -6.0, y: 11.0, r: 4.3 },
  home: { x: 6.0, y: 11.0, r: 4.3 },
  volume: { x: -0.6, y: -6.5, len: 16.5, w: 6.4 },
  led: { x: 0, y: -28.6 },
  logo: { x: 0, y: -33.1 },
};

const TOP = 0; // flat top face
const EDGE_R = 2.5; // top edge fillet radius
const Z_MID = TOP - EDGE_R; // widest point of the side wall
const BOTTOM_ROUND = 13; // horizontal reach of the rounded underside

// underside depth along the body (deeper lobe under the head that houses the trigger)
const BOTTOM_PROFILE = [
  [-60, -18], [-40, -18.5], [-10, -19], [10, -19.5], [18, -21], [26, -27],
  [34, -31], [42, -31], [50, -29], [60, -27],
];

function smoothInterp(points, x) {
  if (x <= points[0][0]) return points[0][1];
  for (let i = 0; i < points.length - 1; i++) {
    const [x0, y0] = points[i];
    const [x1, y1] = points[i + 1];
    if (x <= x1) {
      const p = points[i - 1] ?? points[i];
      const n = points[i + 2] ?? points[i + 1];
      const m0 = (y1 - p[1]) / (x1 - p[0]) * (x1 - x0);
      const m1 = (n[1] - y0) / (n[0] - x0) * (x1 - x0);
      const t = (x - x0) / (x1 - x0), t2 = t * t, t3 = t2 * t;
      return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * m1;
    }
  }
  return points[points.length - 1][1];
}
const bottomAt = (y) => smoothInterp(BOTTOM_PROFILE, y);

function outline(step = 0.5) {
  // CCW when viewed from +Z, starting at the back tip.
  const segs = [];
  const arc = (cx, cy, r, a0, a1) => segs.push({ kind: 'arc', cx, cy, r, a0, a1, len: Math.abs(a1 - a0) * r });
  const line = (x0, y0, x1, y1) => segs.push({ kind: 'line', x0, y0, x1, y1, len: Math.hypot(x1 - x0, y1 - y0) });
  const tangA = Math.atan2(FILLET_CY - HEAD_Y, FILLET_CX); // head-circle tangent angle (right side)
  arc(0, END_Y, HALF_W, -Math.PI / 2, 0);
  line(HALF_W, END_Y, HALF_W, FILLET_CY);
  arc(FILLET_CX, FILLET_CY, FILLET_R, Math.PI, Math.PI + tangA); // concave: sweeps clockwise
  arc(0, HEAD_Y, HEAD_R, tangA, Math.PI - tangA);
  arc(-FILLET_CX, FILLET_CY, FILLET_R, -tangA, 0);
  line(-HALF_W, FILLET_CY, -HALF_W, END_Y);
  arc(0, END_Y, HALF_W, Math.PI, Math.PI * 1.5);
  const pts = [];
  for (const s of segs) {
    const n = Math.max(2, Math.round(s.len / step));
    for (let i = 0; i < n; i++) {
      const t = i / n;
      if (s.kind === 'line') pts.push(new THREE.Vector2(s.x0 + (s.x1 - s.x0) * t, s.y0 + (s.y1 - s.y0) * t));
      else {
        const a = s.a0 + (s.a1 - s.a0) * t;
        pts.push(new THREE.Vector2(s.cx + s.r * Math.cos(a), s.cy + s.r * Math.sin(a)));
      }
    }
  }
  // inward normals (left of the CCW tangent)
  const normals = pts.map((_, i) => {
    const a = pts[(i - 1 + pts.length) % pts.length], b = pts[(i + 1) % pts.length];
    const t = new THREE.Vector2().subVectors(b, a).normalize();
    return new THREE.Vector2(-t.y, t.x);
  });
  return { pts, normals };
}

// --- body shell: offset rings of the outline, rounded top edge + deep rounded underside
function bodyGeometry() {
  const { pts, normals } = outline();
  const N = pts.length;
  const rows = []; // each row: array of Vector3
  const ring = (d, zf) => pts.map((p, i) => {
    const x = p.x + normals[i].x * d, y = p.y + normals[i].y * d;
    return new THREE.Vector3(x, y, zf(y));
  });
  rows.push(ring(EDGE_R + 1.0, () => TOP)); // flat top, inner
  const TOP_STEPS = 8;
  for (let k = TOP_STEPS; k >= 0; k--) { // top fillet, from flat to vertical
    const phi = (k / TOP_STEPS) * Math.PI / 2;
    rows.push(ring(EDGE_R * (1 - Math.cos(phi)), () => Z_MID + EDGE_R * Math.sin(phi)));
  }
  const BOT_STEPS = 22;
  for (let k = 1; k <= BOT_STEPS; k++) { // underside, elliptical per-position depth
    const phi = (k / BOT_STEPS) * Math.PI / 2;
    rows.push(ring(BOTTOM_ROUND * (1 - Math.cos(phi)), (y) => Z_MID - (Z_MID - bottomAt(y)) * Math.sin(phi)));
  }

  const pos = [];
  rows.forEach((row) => row.forEach((v) => pos.push(v.x, v.y, v.z)));
  const idx = [];
  const at = (r, i) => r * N + (i % N);
  for (let r = 0; r < rows.length - 1; r++) {
    for (let i = 0; i < N; i++) {
      const a = at(r, i), b = at(r, i + 1), c = at(r + 1, i), d = at(r + 1, i + 1);
      idx.push(a, c, b, b, c, d);
    }
  }
  // caps
  const cap = (r, up) => {
    const contour = rows[r].map((v) => new THREE.Vector2(v.x, v.y));
    const tris = THREE.ShapeUtils.triangulateShape(contour, []);
    const ccw = !THREE.ShapeUtils.isClockWise(contour);
    for (const [a, b, c] of tris) {
      const flip = up !== ccw;
      idx.push(at(r, a), flip ? at(r, c) : at(r, b), flip ? at(r, b) : at(r, c));
    }
  };
  cap(0, true);
  cap(rows.length - 1, false);

  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setIndex(idx);
  g.computeVertexNormals();

  // seam between the top shell and the battery cover, just below the widest point
  const seamZ = Z_MID - 2.0;
  const seamPts = [];
  for (let i = 0; i < N; i += 3) {
    const hb = Z_MID - bottomAt(pts[i].y);
    const phi = Math.asin(Math.min(1, 2.0 / hb));
    const d = BOTTOM_ROUND * (1 - Math.cos(phi));
    seamPts.push(new THREE.Vector3(pts[i].x + normals[i].x * d, pts[i].y + normals[i].y * d, seamZ));
  }
  return { body: g, seam: new THREE.CatmullRomCurve3(seamPts, true) };
}

// rounded "button cap" via lathe, axis along +Z, base at z=0
function roundedDisc(radius, height, bevel, segments = 64) {
  // profile runs bottom -> top so the lathe faces point outward
  const prof = [new THREE.Vector2(0, 0), new THREE.Vector2(radius, 0)];
  for (let i = 8; i >= 0; i--) {
    const a = (i / 8) * Math.PI / 2;
    prof.push(new THREE.Vector2(radius - bevel + Math.sin(a) * bevel, height - bevel + Math.cos(a) * bevel));
  }
  prof.push(new THREE.Vector2(0, height));
  const g = new THREE.LatheGeometry(prof, segments);
  g.rotateX(Math.PI / 2);
  return g;
}

function stadiumShape(len, w) {
  const r = w / 2, h = len / 2 - r;
  const s = new THREE.Shape();
  s.moveTo(-r, -h);
  s.lineTo(-r, h);
  s.absarc(0, h, r, Math.PI, 0, true);
  s.lineTo(r, -h);
  s.absarc(0, -h, r, 0, Math.PI, true);
  return s;
}

function canvasTexture(w, h, draw) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  const ctx = c.getContext('2d');
  draw(ctx, w, h);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  return t;
}

function decal(tex, w, h, x, y, z, color = 0xffffff) {
  const m = new THREE.Mesh(
    new THREE.PlaneGeometry(w, h),
    new THREE.MeshStandardMaterial({ map: tex, transparent: true, roughness: 0.6, color, depthWrite: false,
      polygonOffset: true, polygonOffsetFactor: -2 }),
  );
  m.position.set(x, y, z);
  return m;
}

const ICON = '#7b828c';
const backIcon = () => canvasTexture(256, 256, (ctx) => {
  ctx.strokeStyle = ICON; ctx.fillStyle = ICON; ctx.lineWidth = 16; ctx.lineCap = 'round';
  ctx.beginPath(); ctx.arc(128, 136, 62, Math.PI * 1.15, Math.PI * 0.75, false); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(44, 70); ctx.lineTo(66, 124); ctx.lineTo(112, 94); ctx.closePath(); ctx.fill();
});
const homeIcon = () => canvasTexture(256, 256, (ctx) => {
  ctx.strokeStyle = ICON; ctx.lineWidth = 15; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
  ctx.beginPath(); ctx.moveTo(56, 128); ctx.lineTo(128, 62); ctx.lineTo(200, 128); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(78, 112); ctx.lineTo(78, 196); ctx.lineTo(178, 196); ctx.lineTo(178, 112); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(114, 196); ctx.lineTo(114, 152); ctx.lineTo(142, 152); ctx.lineTo(142, 196); ctx.stroke();
});
const glyph = (ch) => canvasTexture(128, 128, (ctx) => {
  ctx.strokeStyle = ICON; ctx.lineWidth = 11; ctx.lineCap = 'round';
  ctx.beginPath(); ctx.moveTo(30, 64); ctx.lineTo(98, 64);
  if (ch === '+') { ctx.moveTo(64, 30); ctx.lineTo(64, 98); }
  ctx.stroke();
});
const logoTex = () => canvasTexture(1024, 160, (ctx, w, h) => {
  ctx.fillStyle = '#8e949d';
  ctx.font = '800 118px "Helvetica Neue", Helvetica, Arial, sans-serif';
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  if ('letterSpacing' in ctx) ctx.letterSpacing = '6px';
  ctx.save(); ctx.scale(1.18, 1); ctx.fillText('SAMSUNG', w / 2 / 1.18, h / 2 + 6); ctx.restore();
});

export const ACCENT = new THREE.Color(0x4aa3ff);

// Builds the model. Returns { group, parts, setState(packet), update(dt) }.
export function buildController() {
  const group = new THREE.Group();
  const shell = new THREE.MeshPhysicalMaterial({ color: 0x23262c, roughness: 0.6, metalness: 0,
    clearcoat: 0.25, clearcoatRoughness: 0.5 });
  const padMat = new THREE.MeshPhysicalMaterial({ color: 0x1a1c21, roughness: 0.32, clearcoat: 0.6,
    clearcoatRoughness: 0.25, emissive: ACCENT, emissiveIntensity: 0 });
  const buttonMat = () => new THREE.MeshPhysicalMaterial({ color: 0x262a31, roughness: 0.42, clearcoat: 0.4,
    clearcoatRoughness: 0.3, emissive: ACCENT, emissiveIntensity: 0 });
  const grooveMat = new THREE.MeshBasicMaterial({ color: 0x07080a });

  const { body, seam } = bodyGeometry();
  const bodyMesh = new THREE.Mesh(body, shell);
  bodyMesh.castShadow = bodyMesh.receiveShadow = true;
  group.add(bodyMesh);
  group.add(new THREE.Mesh(new THREE.TubeGeometry(seam, 600, 0.16, 6, true), grooveMat));

  // touchpad + bezel groove
  const L = LAYOUT;
  const pad = new THREE.Mesh(roundedDisc(L.padR, 1.6, 0.7, 128), padMat);
  pad.position.set(0, L.headY, -1.35);
  pad.castShadow = true;
  group.add(pad);
  const padGroove = new THREE.Mesh(new THREE.RingGeometry(L.padR - 0.05, L.padR + 0.65, 128), grooveMat);
  padGroove.position.set(0, L.headY, TOP + 0.02);
  group.add(padGroove);

  // round face buttons with printed icons
  const faceButton = (spec, tex) => {
    const g = new THREE.Group();
    const mat = buttonMat();
    const cap = new THREE.Mesh(roundedDisc(spec.r, 1.7, 0.8), mat);
    cap.position.z = -1.0;
    cap.castShadow = true;
    g.add(cap);
    g.add(decal(tex, spec.r * 1.35, spec.r * 1.35, 0, 0, 0.72));
    g.position.set(spec.x, spec.y, 0);
    const groove = new THREE.Mesh(new THREE.RingGeometry(spec.r - 0.05, spec.r + 0.55, 64), grooveMat);
    groove.position.set(spec.x, spec.y, TOP + 0.02);
    group.add(groove, g);
    return { group: g, mat };
  };
  const back = faceButton(L.back, backIcon());
  const home = faceButton(L.home, homeIcon());

  // volume rocker (+ toward the head)
  const V = L.volume;
  const volGeo = new THREE.ExtrudeGeometry(stadiumShape(V.len, V.w), { depth: 0.9, bevelEnabled: true,
    bevelThickness: 0.45, bevelSize: 0.45, bevelSegments: 5, curveSegments: 32 });
  const volMat = buttonMat();
  const vol = new THREE.Group();
  const volMesh = new THREE.Mesh(volGeo, volMat);
  volMesh.position.z = -0.95; // top sits ~0.4 mm proud of the face
  volMesh.castShadow = true;
  vol.add(volMesh);
  vol.add(decal(glyph('+'), 3.2, 3.2, 0, V.len / 2 - 3.6, 0.42));
  vol.add(decal(glyph('-'), 3.2, 3.2, 0, -V.len / 2 + 3.6, 0.42));
  vol.position.set(V.x, V.y, 0);
  const volGroove = new THREE.Mesh(new THREE.ShapeGeometry(stadiumShape(V.len + 2.1, V.w + 2.1), 32), grooveMat);
  volGroove.position.set(V.x, V.y, TOP + 0.02);
  group.add(volGroove, vol);

  // status LED and wordmark
  const ledMat = new THREE.MeshBasicMaterial({ color: 0x0c1118 });
  const led = new THREE.Mesh(new THREE.CircleGeometry(0.55, 24), ledMat);
  led.position.set(L.led.x, L.led.y, TOP + 0.03);
  const ledGlow = new THREE.PointLight(ACCENT, 0, 12, 2);
  ledGlow.position.set(L.led.x, L.led.y, 2);
  group.add(led, ledGlow);
  group.add(decal(logoTex(), 16.5, 2.6, L.logo.x, L.logo.y, TOP + 0.03));

  // trigger: curved paddle under the head, pivoting about X
  const ts = new THREE.Shape();
  ts.moveTo(40.5, -24);
  ts.quadraticCurveTo(43, -35, 37.5, -40.5);
  ts.quadraticCurveTo(33, -44.8, 28.5, -44.2);
  ts.quadraticCurveTo(26.4, -43.7, 27.8, -41.4);
  ts.quadraticCurveTo(32.6, -35.5, 32, -24);
  ts.lineTo(40.5, -24);
  const tg = new THREE.ExtrudeGeometry(ts, { depth: 12, bevelEnabled: true, bevelThickness: 1.4,
    bevelSize: 1.4, bevelSegments: 5, curveSegments: 32 });
  const PIVOT = new THREE.Vector3(0, 36, -26);
  tg.applyMatrix4(new THREE.Matrix4().set(0, 0, 1, -6, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1));
  tg.translate(-PIVOT.x, -PIVOT.y, -PIVOT.z);
  tg.computeVertexNormals();
  const trigMat = buttonMat();
  trigMat.color.set(0x1f2227);
  const trigger = new THREE.Group();
  const trigMesh = new THREE.Mesh(tg, trigMat);
  trigMesh.castShadow = true;
  trigger.add(trigMesh);
  trigger.position.copy(PIVOT);
  group.add(trigger);

  // touch indicator + fading trail on the pad
  const touchDot = new THREE.Mesh(new THREE.SphereGeometry(1.5, 24, 16),
    new THREE.MeshBasicMaterial({ color: ACCENT, transparent: true, opacity: 0.95 }));
  touchDot.visible = false;
  const TRAIL = 48;
  const trailGeo = new THREE.BufferGeometry();
  trailGeo.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(TRAIL * 3), 3));
  trailGeo.setAttribute('color', new THREE.Float32BufferAttribute(new Float32Array(TRAIL * 3), 3));
  const trail = new THREE.Points(trailGeo, new THREE.PointsMaterial({ size: 1.4, vertexColors: true,
    transparent: true, opacity: 0.9, depthWrite: false, blending: THREE.AdditiveBlending }));
  trail.frustumCulled = false;
  const trailPts = [];
  group.add(touchDot, trail);

  // animated state, eased toward targets each frame
  const anim = { trigger: 0, back: 0, home: 0, pad: 0, volUp: 0, volDown: 0, led: 0 };
  const target = { ...anim };
  let lastTouch = null;

  function padPoint(x, y) {
    const px = (x / 315 - 0.5) * 2 * (L.padR - 1.2);
    const py = L.headY + (0.5 - y / 315) * 2 * (L.padR - 1.2);
    return new THREE.Vector3(px, py, 0.55);
  }

  function setState(pkt, connected = true) {
    const b = pkt?.buttons ?? {};
    target.trigger = b.trigger ? 1 : 0;
    target.back = b.back ? 1 : 0;
    target.home = b.home ? 1 : 0;
    target.pad = b.touchpad ? 1 : 0;
    target.volUp = b.volume_up ? 1 : 0;
    target.volDown = b.volume_down ? 1 : 0;
    target.led = connected ? 1 : 0;
    const t = pkt?.touch;
    if (t?.touching) {
      const p = padPoint(t.x, t.y);
      lastTouch = p;
      trailPts.push({ p, age: 0 });
      if (trailPts.length > TRAIL) trailPts.shift();
    } else {
      lastTouch = null;
    }
  }

  function update(dt) {
    const k = 1 - Math.exp(-dt * 30);
    for (const key in anim) anim[key] += (target[key] - anim[key]) * k;
    trigger.rotation.x = THREE.MathUtils.degToRad(14) * anim.trigger;
    trigMat.emissiveIntensity = 0.9 * anim.trigger;
    back.group.position.z = -0.6 * anim.back;
    back.mat.emissiveIntensity = 0.9 * anim.back;
    home.group.position.z = -0.6 * anim.home;
    home.mat.emissiveIntensity = 0.9 * anim.home;
    pad.position.z = -1.35 - 0.45 * anim.pad;
    padMat.emissiveIntensity = 0.35 * anim.pad;
    vol.rotation.x = THREE.MathUtils.degToRad(5) * (anim.volDown - anim.volUp);
    volMat.emissiveIntensity = 0.9 * Math.max(anim.volUp, anim.volDown);
    ledMat.color.copy(new THREE.Color(0x0c1118).lerp(ACCENT, anim.led));
    ledGlow.intensity = 30 * anim.led;

    touchDot.visible = !!lastTouch;
    if (lastTouch) touchDot.position.copy(lastTouch);
    const posAttr = trailGeo.attributes.position, colAttr = trailGeo.attributes.color;
    for (let i = 0; i < TRAIL; i++) {
      const e = trailPts[i];
      if (e) {
        e.age += dt;
        posAttr.setXYZ(i, e.p.x, e.p.y, e.p.z);
        const f = Math.max(0, 1 - e.age / 0.8);
        colAttr.setXYZ(i, ACCENT.r * f, ACCENT.g * f, ACCENT.b * f);
      } else {
        colAttr.setXYZ(i, 0, 0, 0);
      }
    }
    while (trailPts.length && trailPts[0].age > 0.8) trailPts.shift();
    posAttr.needsUpdate = colAttr.needsUpdate = true;
  }

  return { group, setState, update };
}
