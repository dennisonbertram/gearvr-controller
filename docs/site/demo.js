// Interactive demo: a simulated Gear VR controller driving a simulated Mac.
// Mirrors the real app's behaviour closely enough to teach it: gyro air-mouse,
// trigger click/drag, touchpad modes, clutch, magnetic buttons, volume, Home, Back.
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const hyp = Math.hypot;

  const stage = $('#demoStage');
  if (!stage) return;
  const screen = $('#screen'), cursorEl = $('#cursor'), win = $('#win'), tracksEl = $('#tracks');
  const ctx = $('#ctx'), hud = $('#hud'), hudFill = $('#hudFill'), hudLabel = $('#hudLabel');
  const toastEl = $('#toast'), bubble = $('#bubble'), logEl = $('#log');
  const ctl = $('#ctl'), ctlSvg = $('#ctlSvg'), padFace = $('.pad-face'), touchDot = $('#touchDot');
  const tilt = $('#tilt'), puck = $('#tiltPuck');
  const magnetIn = $('#magnet'), magVal = $('#magVal'), clutchOn = $('#clutchOn'), latch = $('#latch');
  const B = { trigger: $('#bTrigger'), pad: $('#bPad'), back: $('#bBack'), home: $('#bHome'), up: $('#bVolUp'), down: $('#bVolDown') };

  const TRACKS = [
    ['Signal Lost', 'Low Orbit', '3:42'], ['Paper Satellites', 'Kite Theory', '4:05'], ['Night Bus', 'Mara Holt', '2:58'],
    ['Gyroscope', 'The Tilt', '3:31'], ['Soft Reset', 'Analog Bloom', '5:12'], ['Two AAA', 'Pocket Arcade', '2:47'],
    ['Slow Drift', 'Calibrate', '4:20'], ['Home Button', 'Kite Theory', '3:09'], ['Tink & Pop', 'Clutch', '1:58'],
    ['Magnetic North', 'Low Orbit', '4:44'], ['Backlight', 'Mara Holt', '3:36'], ['68 Per Second', 'Pocket Arcade', '3:03'],
    ['Pairing Mode', 'Analog Bloom', '4:01'], ['Last Light', 'The Tilt', '5:27'],
  ];
  tracksEl.innerHTML = TRACKS.map(([t, a, d], i) =>
    `<li data-target="${t}, track ${i + 1}" data-act="row" data-i="${i}"><b>${t}</b>&nbsp;<small style="color:inherit;opacity:.6">${a}</small><span>${d}</span></li>`).join('');

  // ------------------------------------------------------------------ state
  const S = {
    x: 0, y: 0, air: true, mode: 'scroll', magnet: 0.3, clutchEnabled: true,
    trig: { down: false, srcs: new Set(), sx: 0, sy: 0, dragging: false },
    clutch: false, clutchMoved: 0,
    touch: null, volume: 0.5, playing: false, track: 0, sel: -1, liked: false,
    snapped: null, push: { x: 0, y: 0 }, magHint: null, hot: null, aimDist: 0,
    yaw: 0, pitch: 0, done: new Set(), viewStep: null, winState: 'open',
  };

  // ------------------------------------------------------------------ log
  let lastLog = null;
  function log(key, title, detail = '', cls = '') {
    const now = performance.now();
    if (lastLog && lastLog.key === key && now - lastLog.t < 1800 && logEl.firstChild === lastLog.li) {
      lastLog.n++;
      lastLog.li.querySelector('b').textContent = typeof title === 'function' ? title(lastLog.n) : title;
      lastLog.li.querySelector('small').textContent = detail;
      lastLog.t = now;
      return;
    }
    const li = document.createElement('li');
    li.className = 'new ' + cls;
    li.innerHTML = '<b></b><small></small>';
    li.querySelector('b').textContent = typeof title === 'function' ? title(1) : title;
    li.querySelector('small').textContent = detail;
    logEl.prepend(li);
    setTimeout(() => li.classList.remove('new'), 900);
    while (logEl.children.length > 40) logEl.lastChild.remove();
    lastLog = { key, t: now, li, n: 1 };
  }

  // ------------------------------------------------------------------ walkthrough
  const STEPS = ['aim', 'click', 'scroll', 'volume', 'clutch', 'magnet'];
  const stepLis = Object.fromEntries($$('#steps li').map((li) => [li.dataset.step, li]));
  function renderSteps() {
    const cur = S.viewStep && !S.done.has(S.viewStep) ? S.viewStep : STEPS.find((s) => !S.done.has(s));
    for (const s of STEPS) {
      stepLis[s].classList.toggle('done', S.done.has(s));
      stepLis[s].classList.toggle('current', s === cur);
    }
    $('#stepCount').textContent = `${S.done.size} of 6`;
  }
  function complete(step) {
    if (S.done.has(step)) return;
    S.done.add(step);
    if (S.viewStep === step) S.viewStep = null;
    stepLis[step].classList.add('flash');
    setTimeout(() => stepLis[step].classList.remove('flash'), 900);
    renderSteps();
    if (S.done.size === STEPS.length) toast('That\'s all six. With a real controller it works in every app on your Mac.', 4200);
  }
  $$('#steps li').forEach((li) => li.addEventListener('click', () => { S.viewStep = li.dataset.step; renderSteps(); }));
  $('#resetDemo').addEventListener('click', () => {
    S.done.clear(); S.viewStep = null; S.aimDist = 0; renderSteps();
    logEl.innerHTML = ''; lastLog = null;
    S.x = W() / 2; S.y = H() / 2; render();
  });

  // ------------------------------------------------------------------ geometry
  const W = () => screen.clientWidth, H = () => screen.clientHeight;
  function screenOrigin() {
    const r = screen.getBoundingClientRect();
    return { x: r.left + screen.clientLeft, y: r.top + screen.clientTop };
  }
  function targets() {
    const o = screenOrigin();
    const listR = tracksEl.getBoundingClientRect();
    const out = [];
    for (const el of $$('[data-target]', screen)) {
      if (el.closest('[hidden]')) continue;
      if (S.winState !== 'open' && win.contains(el)) continue;
      const r = el.getBoundingClientRect();
      if (!r.width) continue;
      const row = el.dataset.act === 'row';
      if (row && (r.bottom < listR.top + 4 || r.top > listR.bottom - 4)) continue;
      out.push({
        el, row, ctx: !!el.closest('#ctx'),
        l: r.left - o.x, t: r.top - o.y, r: r.right - o.x, b: r.bottom - o.y,
        cx: r.left - o.x + r.width / 2, cy: r.top - o.y + r.height / 2, area: r.width * r.height,
      });
    }
    return out;
  }
  const rectDist = (t, x, y) => hyp(Math.max(t.l - x, 0, x - t.r), Math.max(t.t - y, 0, y - t.b));
  function hit(x = S.x, y = S.y) {
    const inside = targets().filter((t) => x >= t.l && x <= t.r && y >= t.t && y <= t.b);
    if (!inside.length) return null;
    const c = inside.find((t) => t.ctx);
    return c || inside.sort((a, b) => a.area - b.area)[0];
  }
  const name = (t) => t ? t.el.dataset.target : 'the desktop';
  const isLight = (t) => t && t.el.classList.contains('tl');

  // ------------------------------------------------------------------ rendering
  function render() {
    S.x = clamp(S.x, 0, W() - 2); S.y = clamp(S.y, 0, H() - 2);
    cursorEl.style.transform = `translate(${(S.x - 2).toFixed(1)}px, ${(S.y - 2).toFixed(1)}px)`;
    cursorEl.classList.toggle('frozen', S.clutch);
    cursorEl.classList.toggle('snapped', !!S.snapped);
    cursorEl.classList.toggle('off', !S.air);
    const h = hit();
    const hel = h ? h.el : null;
    if (S.hot !== hel) { S.hot?.classList.remove('hot'); hel?.classList.add('hot'); S.hot = hel; }
    const m = S.snapped || S.magHint;
    $$('.mag', screen).forEach((e) => { if (e !== m) e.classList.remove('mag'); });
    m?.classList.add('mag');
    ctl.style.transform = `rotateX(${S.pitch.toFixed(1)}deg) rotateZ(${S.yaw.toFixed(1)}deg)`;
  }
  function status() {
    const air = $('#stAir');
    air.lastChild.textContent = S.air ? 'Air mouse on' : 'Air mouse off';
    air.classList.toggle('off', !S.air);
    $('#stRate').textContent = S.air ? '68 packets/s' : '30 packets/s';
    const eff = effMode();
    const label = { scroll: 'Scroll', cursor: 'Cursor', swipes: 'Swipes', volume: 'Volume' }[eff];
    $('#stMode').textContent = 'Touchpad: ' + label + (eff !== S.mode ? ' (air mouse off)' : '');
    const c = $('#stClutch');
    c.textContent = !S.clutchEnabled ? 'Clutch off' : S.clutch ? 'Clutch engaged' : 'Clutch ready';
    c.classList.toggle('engaged', S.clutch);
    $('#led').classList.toggle('on', S.air);
    $('#mbGlyph').classList.toggle('on', true);
    ctlSvg.classList.toggle('trig-held', S.trig.down && S.clutchEnabled);
    ctlSvg.classList.toggle('clutch-on', S.clutch);
    B.trigger.classList.toggle('down', S.trig.down);
    latch.setAttribute('aria-pressed', S.trig.srcs.has('latch') ? 'true' : 'false');
  }
  const effMode = () => (S.mode === 'scroll' && !S.air ? 'cursor' : S.mode);

  let toastT;
  function toast(html, ms = 1800, cls = '') {
    toastEl.innerHTML = html; toastEl.className = 'toast ' + cls; toastEl.hidden = false;
    clearTimeout(toastT); toastT = setTimeout(() => { toastEl.hidden = true; }, ms);
  }
  function say(text, cls = '') {
    bubble.hidden = true; void bubble.offsetWidth;
    bubble.textContent = text; bubble.className = 'bubble ' + cls;
    bubble.style.left = S.x + 'px'; bubble.style.top = S.y + 'px';
    bubble.hidden = false;
  }
  let hudT;
  function showHud(level, label, textOnly = false) {
    hud.classList.toggle('text', textOnly);
    if (!textOnly) hudFill.style.width = (level * 100).toFixed(1) + '%';
    hudLabel.textContent = label;
    hud.hidden = false;
    clearTimeout(hudT); hudT = setTimeout(() => { hud.hidden = true; }, 1400);
  }

  // ------------------------------------------------------------------ pointer movement + magnet
  function magnetMove(dx, dy) {
    const s = S.magnet;
    S.magHint = null;
    let nx = S.x + dx, ny = S.y + dy;
    if (s <= 0.01) { S.snapped = null; return [nx, ny]; }
    const T = targets().filter((t) => !t.row);
    if (s > 0.5) {
      const k = (s - 0.5) * 2;               // 0..1 past the middle
      const capture = 10 + k * 26;           // px from a button's edge that grabs the pointer
      const breakout = 12 + k * 30;          // push needed to leave it
      if (S.snapped) {
        const cur = T.find((t) => t.el === S.snapped);
        if (!cur) { S.snapped = null; return [nx, ny]; }
        S.push.x += dx; S.push.y += dy;
        const pm = hyp(S.push.x, S.push.y);
        if (pm < breakout) return [cur.cx + S.push.x * 0.15, cur.cy + S.push.y * 0.15];
        const ux = S.push.x / pm, uy = S.push.y / pm;
        let best = null, bd = 1e9;
        for (const t of T) {
          if (t.el === cur.el) continue;
          const vx = t.cx - cur.cx, vy = t.cy - cur.cy, d = hyp(vx, vy);
          if (d < 140 && (vx * ux + vy * uy) / d > 0.72 && d < bd) { best = t; bd = d; }
        }
        S.push = { x: 0, y: 0 };
        if (best) {
          S.snapped = best.el;
          log('hop', 'Magnet: hop to ' + name(best), 'a small push moves to the next button');
          if (isLight(best)) complete('magnet');
          return [best.cx, best.cy];
        }
        S.snapped = null;
        log('free', 'Magnet: pulled free', 'a push into empty space releases the pointer');
        return [cur.cx + ux * (breakout + 6), cur.cy + uy * (breakout + 6)];
      }
      let best = null, bd = 1e9;
      for (const t of T) { const d = rectDist(t, nx, ny); if (d < capture && d < bd) { best = t; bd = d; } }
      if (best) {
        S.snapped = best.el; S.push = { x: 0, y: 0 };
        log('snap', 'Magnet: snapped to ' + name(best), `strength ${Math.round(s * 100)}%`);
        if (isLight(best)) complete('magnet');
        return [best.cx, best.cy];
      }
      return [nx, ny];
    }
    // subtle: damp motion over and near buttons, bend slightly toward them, never move on its own
    S.snapped = null;
    const R = 26;
    let best = null, bd = 1e9;
    for (const t of T) { const d = rectDist(t, S.x, S.y); if (d < R && d < bd) { best = t; bd = d; } }
    if (!best) return [nx, ny];
    const near = 1 - bd / R;
    const speed = hyp(dx, dy);
    // damping is strongest when nearly still (cancels tremor), light when moving with intent
    const damp = Math.max(0.3, 1 - s * near * (speed < 4 ? 1.6 : 0.5));
    const vx = best.cx - S.x, vy = best.cy - S.y, vm = hyp(vx, vy) || 1;
    // bend only toward a button you're already heading for, never pull you back
    const toward = speed ? (vx * dx + vy * dy) / (vm * speed) : 0;
    const bend = bd > 0 && toward > 0.3 ? s * 0.3 * near * speed * toward : 0;
    S.magHint = best.el;
    return [S.x + dx * damp + (vx / vm) * bend, S.y + dy * damp + (vy / vm) * bend];
  }

  function moveBy(dx, dy, source) {
    if (S.clutch) { S.clutchMoved += hyp(dx, dy); return; }
    [S.x, S.y] = magnetMove(dx, dy);
    if (source === 'gyro') {
      S.aimDist += hyp(dx, dy);
      if (S.aimDist > 160) complete('aim');
    }
    if (S.trig.down && !S.trig.dragging && hyp(S.x - S.trig.sx, S.y - S.trig.sy) > 12) {
      S.trig.dragging = true;
      log('drag', 'Drag', 'left button held while moving past 12 px');
    }
    render();
  }

  // gyro: the tilt pad stands in for turning the controller
  let lastTilt = null;
  function tiltAt(e) {
    const r = tilt.getBoundingClientRect();
    const px = clamp(e.clientX - r.left, 0, r.width), py = clamp(e.clientY - r.top, 0, r.height);
    puck.style.left = px + 'px'; puck.style.top = py + 'px';
    S.yaw = ((px / r.width) - 0.5) * 50;
    S.pitch = (0.5 - (py / r.height)) * 44;
    if (lastTilt) {
      const k = 1.3 * (W() / 640 + 0.5);
      const dx = (e.clientX - lastTilt.x) * k, dy = (e.clientY - lastTilt.y) * k;
      if (!S.air) { render(); lastTilt = { x: e.clientX, y: e.clientY }; maybeAirOffHint(dx, dy); return; }
      moveBy(dx, dy, 'gyro');
    } else render();
    lastTilt = { x: e.clientX, y: e.clientY };
  }
  let airHintT = 0;
  function maybeAirOffHint(dx, dy) {
    if (hyp(dx, dy) > 3 && performance.now() - airHintT > 4000) {
      airHintT = performance.now();
      toast('Air mouse is off. Press <b>Home</b> to turn it back on.', 2200);
    }
  }
  tilt.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') { lastTilt = { x: e.clientX, y: e.clientY }; tilt.classList.add('active'); } });
  tilt.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') { lastTilt = null; tilt.classList.remove('active'); } });
  tilt.addEventListener('pointerdown', (e) => {
    if (e.pointerType !== 'mouse') { tilt.setPointerCapture(e.pointerId); lastTilt = { x: e.clientX, y: e.clientY }; tilt.classList.add('active'); }
  });
  tilt.addEventListener('pointermove', (e) => {
    if (e.pointerType !== 'mouse' && !tilt.hasPointerCapture(e.pointerId)) return;
    tiltAt(e);
  });
  const tiltEnd = (e) => { if (e.pointerType !== 'mouse') { lastTilt = null; tilt.classList.remove('active'); } };
  tilt.addEventListener('pointerup', tiltEnd);
  tilt.addEventListener('pointercancel', tiltEnd);

  // ------------------------------------------------------------------ clicks on the fake Mac
  function setTrack(i) {
    S.track = (i + TRACKS.length) % TRACKS.length;
    $('#npTitle').textContent = TRACKS[S.track][0];
    $('#npArtist').textContent = TRACKS[S.track][1];
    $$('li', tracksEl).forEach((li, j) => li.classList.toggle('cur', j === S.track));
  }
  function select(i) { S.sel = clamp(i, 0, TRACKS.length - 1); $$('li', tracksEl).forEach((li, j) => li.classList.toggle('sel', j === S.sel)); $$('li', tracksEl)[S.sel].scrollIntoView({ block: 'nearest' }); }
  function setWin(state) {
    S.winState = state;
    win.classList.toggle('closed', state === 'closed');
    win.classList.toggle('minimized', state === 'min');
    if (state !== 'open') { S.snapped = null; setTimeout(() => { setWin('open'); log('reopen', 'Window back', 'the demo reopens it so you can keep going'); render(); }, 1500); }
  }
  function flashPress(el) { el.classList.add('press'); setTimeout(() => el.classList.remove('press'), 140); }

  function leftClick() {
    const t = hit();
    const at = `at ${Math.round(S.x)}, ${Math.round(S.y)}`;
    if (!ctx.hidden && !(t && t.ctx)) ctx.hidden = true;
    if (!t) { log('click', 'Left click', 'on the desktop ' + at); if (screen.contains(document.activeElement)) {} return; }
    flashPress(t.el);
    const act = t.el.dataset.act;
    log('click-' + name(t), (n) => n > 1 ? `Left click ×${n}` : 'Left click', 'on ' + name(t));
    if (act !== 'row' && act !== 'ctx') complete('click');
    switch (act) {
      case 'close': toast('Closed the window. It comes back in a moment.'); setWin('closed'); break;
      case 'min': setWin('min'); break;
      case 'zoom': win.classList.toggle('zoomed'); S.snapped = null; break;
      case 'play':
        S.playing = !S.playing;
        win.classList.toggle('playing', S.playing);
        t.el.dataset.target = S.playing ? 'Pause' : 'Play';
        break;
      case 'prev': setTrack(S.track - 1); break;
      case 'next': setTrack(S.track + 1); break;
      case 'like': S.liked = !S.liked; t.el.classList.toggle('on', S.liked); t.el.dataset.target = S.liked ? 'Unlike' : 'Like'; break;
      case 'dock': t.el.classList.remove('bounce'); void t.el.offsetWidth; t.el.classList.add('bounce'); break;
      case 'row': select(+t.el.dataset.i); break;
      case 'ctx': ctx.hidden = true; toast(`${t.el.textContent}: done.`); break;
    }
    if (t.el.id === 'mbGlyph') toast('This glyph is GearVR Remote. In the real app, clicking it opens the menu with the quick switches.', 3200);
    render();
  }
  function rightClick() {
    const t = hit();
    if (t && t.el.dataset.act === 'row') select(+t.el.dataset.i);
    log('rclick', 'Right click', 'touchpad click, on ' + name(t));
    const pw = 160, ph = 86;
    ctx.style.left = Math.min(S.x + 4, W() - pw - 4) + 'px';
    ctx.style.top = Math.min(S.y + 4, H() - ph - 4) + 'px';
    ctx.hidden = false;
    render();
  }
  screen.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'mouse') toast('Use the controller: aim with the tilt pad, click with the <b>Trigger</b>.', 2400);
  });

  // ------------------------------------------------------------------ trigger + clutch
  function trigDown(src) {
    S.trig.srcs.add(src);
    if (S.trig.down) return;
    S.trig.down = true; S.trig.dragging = false; S.trig.sx = S.x; S.trig.sy = S.y;
    if (S.touch && S.touch.bottom) engageClutch();
    status();
  }
  function trigUp(src) {
    S.trig.srcs.delete(src);
    if (!S.trig.down || S.trig.srcs.size) { status(); return; }
    S.trig.down = false;
    if (S.clutch) { releaseClutch(); status(); return; }
    if (S.trig.dragging) log('drag-end', 'Drop', 'left button released');
    else leftClick();
    status();
  }
  function engageClutch() {
    if (!S.clutchEnabled || S.clutch || !S.trig.down) return;
    S.clutch = true; S.clutchMoved = 0; S.snapped = null;
    if (S.touch) S.touch.clutched = true;
    say('tink');
    log('clutch', 'Clutch engaged', 'tink: the pointer is frozen, move your hand freely', 'k-amber');
    status(); render();
  }
  function releaseClutch() {
    S.clutch = false;
    say('pop', 'pop');
    log('clutch-off', 'Clutch released', 'pop: the pointer resumes from where it was, nothing clicked', 'k-amber');
    complete('clutch');
    render();
  }
  latch.addEventListener('click', () => { if (S.trig.srcs.has('latch')) trigUp('latch'); else trigDown('latch'); });
  clutchOn.addEventListener('change', () => { S.clutchEnabled = clutchOn.checked; if (!S.clutchEnabled && S.clutch) { S.clutch = false; render(); } status(); });

  // ------------------------------------------------------------------ touchpad
  function padNorm(e) {
    const r = padFace.getBoundingClientRect();
    return { x: (e.clientX - (r.left + r.width / 2)) / (r.width / 2), y: (e.clientY - (r.top + r.height / 2)) / (r.height / 2) };
  }
  let scrollAcc = 0, scrollTotal = 0, volTouched = false;
  function padStart(e) {
    const p = padNorm(e);
    if (hyp(p.x, p.y) > 1.15) return;
    e.preventDefault();
    ctlSvg.setPointerCapture?.(e.pointerId);
    S.touch = { id: e.pointerId, x: p.x, y: p.y, sx: p.x, sy: p.y, t0: performance.now(), path: 0, bottom: p.y > 0.3 };
    ctlSvg.classList.add('touching');
    padDot(p);
    if (S.touch.bottom && S.trig.down) engageClutch();
  }
  function padDot(p) {
    const m = Math.min(1, 1 / (hyp(p.x, p.y) || 1));
    touchDot.setAttribute('cx', (100 + p.x * m * 52).toFixed(1));
    touchDot.setAttribute('cy', (90 + p.y * m * 52).toFixed(1));
  }
  function padMove(e) {
    const T = S.touch;
    if (!T || T.id !== e.pointerId) return;
    const p = padNorm(e);
    const dx = p.x - T.x, dy = p.y - T.y;
    T.x = p.x; T.y = p.y; T.path += hyp(dx, dy);
    T.bottom = p.y > 0.3;
    padDot(p);
    if (T.bottom && S.trig.down && !S.clutch) engageClutch();
    if (S.clutch) return;
    const mode = effMode();
    if (mode === 'scroll') {
      const lines = -dy * 9;
      tracksEl.scrollTop += lines * 26;
      scrollAcc += lines; scrollTotal += Math.abs(lines);
      const n = Math.round(Math.abs(scrollAcc));
      if (n >= 1) {
        const dir = scrollAcc > 0 ? 'down' : 'up';
        log('scroll-' + dir, (k) => `Scroll ${dir}`, `scroll wheel, ${Math.round(scrollTotal)} lines so far`);
        scrollAcc -= Math.sign(scrollAcc) * n;
      }
      if (scrollTotal >= 2) complete('scroll');
      render();
    } else if (mode === 'cursor') {
      moveBy(dx * 120, dy * 120, 'pad');
      log('padcursor', 'Move pointer', 'touchpad as a trackpad, 3.0× speed');
    } else if (mode === 'volume') {
      S.volume = clamp(S.volume - dy * 0.55, 0, 1);
      volTouched = true;
      const pct = Math.round(S.volume * 100);
      showHud(S.volume, pct + '%');
      log('vol-smooth', `System volume ${pct}%`, 'touchpad Volume mode sets the output device directly');
      complete('volume');
    }
  }
  function padEnd(e) {
    const T = S.touch;
    if (!T || T.id !== e.pointerId) return;
    S.touch = null;
    ctlSvg.classList.remove('touching');
    scrollAcc = 0;
    if (S.clutch || S.trig.down || T.clutched) return;
    const dt = performance.now() - T.t0;
    const ddx = T.x - T.sx, ddy = T.y - T.sy, d = hyp(ddx, ddy);
    if (dt < 300 && T.path < 0.12) { rightClick(); return; }
    if (effMode() === 'swipes' && d > 0.4 && dt < 900) {
      const dir = Math.abs(ddx) > Math.abs(ddy) ? (ddx > 0 ? 'right' : 'left') : (ddy > 0 ? 'down' : 'up');
      const arrow = { left: '←', right: '→', up: '↑', down: '↓' }[dir];
      log('swipe', `Swipe ${dir}`, `key: ${dir} arrow`);
      showHud(0, `${arrow}  ${dir} arrow`, true);
      if (dir === 'left') setTrack(S.track - 1);
      else if (dir === 'right') setTrack(S.track + 1);
      else select((S.sel < 0 ? S.track : S.sel) + (dir === 'down' ? 1 : -1));
    }
    if (volTouched) { volTouched = false; }
    scrollTotal = 0;
  }

  // ------------------------------------------------------------------ hardware buttons
  let repeatT = null, homeT = null;
  function volStep(dir) {
    S.volume = clamp(Math.round((S.volume + dir / 16) * 16) / 16, 0, 1);
    const pct = Math.round(S.volume * 100);
    showHud(S.volume, pct + '%');
    log('vol' + dir, (n) => `Volume ${dir > 0 ? 'up' : 'down'}${n > 1 ? ' ×' + n : ''}`, `media key, system volume ${pct}%`);
    complete('volume');
  }
  const press = {
    trigger: { down: (src) => trigDown(src), up: (src) => trigUp(src) },
    back: {
      down: () => {
        log('esc', 'Escape', 'key: escape');
        showHud(0, 'esc', true);
        if (!ctx.hidden) ctx.hidden = true;
        else if (win.classList.contains('zoomed')) win.classList.remove('zoomed');
        render();
      },
    },
    home: {
      down: () => {
        S.air = !S.air;
        S.snapped = null;
        log('home', S.air ? 'Air mouse on' : 'Air mouse off',
          S.air ? 'fast 68 packets/s stream, touchpad scrolls' : 'lighter 30 packets/s stream, touchpad moves the pointer');
        showHud(0, S.air ? 'Air mouse on' : 'Air mouse off', true);
        status(); render();
        homeT = setTimeout(() => toast('On a real controller, <b>don\'t hold Home</b>. A long press wipes its pairing with your Mac.', 4000, 'warn'), 1800);
      },
      up: () => clearTimeout(homeT),
    },
    up: { down: () => { volStep(1); repeatT = setTimeout(function rep() { volStep(1); repeatT = setTimeout(rep, 110); }, 450); }, up: () => clearTimeout(repeatT) },
    down: { down: () => { volStep(-1); repeatT = setTimeout(function rep() { volStep(-1); repeatT = setTimeout(rep, 110); }, 450); }, up: () => clearTimeout(repeatT) },
  };
  for (const [k, el] of Object.entries(B)) {
    if (k === 'pad') continue;
    const h = press[k];
    el.addEventListener('pointerdown', (e) => {
      e.preventDefault(); e.stopPropagation();
      try { el.setPointerCapture(e.pointerId); } catch {}
      el.classList.add('down');
      h.down('p' + e.pointerId);
      const end = () => {
        el.removeEventListener('pointerup', end); el.removeEventListener('pointercancel', end);
        if (k !== 'trigger') el.classList.remove('down');
        h.up?.('p' + e.pointerId);
      };
      el.addEventListener('pointerup', end); el.addEventListener('pointercancel', end);
    });
    el.addEventListener('keydown', (e) => {
      if ((e.key === 'Enter' || e.key === ' ') && !e.repeat) { e.preventDefault(); e.stopPropagation(); el.classList.add('down'); h.down('k'); }
      else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); }
    });
    el.addEventListener('keyup', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); if (k !== 'trigger') el.classList.remove('down'); h.up?.('k'); }
    });
  }
  B.pad.addEventListener('pointerdown', padStart);
  ctlSvg.addEventListener('pointermove', padMove);
  ctlSvg.addEventListener('pointerup', padEnd);
  ctlSvg.addEventListener('pointercancel', padEnd);
  B.pad.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); rightClick(); } });

  // ------------------------------------------------------------------ mode + magnet controls
  $$('#modeSeg button').forEach((b) => b.addEventListener('click', () => {
    S.mode = b.dataset.mode;
    $$('#modeSeg button').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
    log('mode', `Touchpad mode: ${b.textContent}`, {
      scroll: 'slide to scroll', cursor: 'slide to move the pointer', swipes: 'flick to send arrow keys', volume: 'slide up and down for system volume',
    }[S.mode]);
    status();
  }));
  function magnetLabel() {
    const v = +magnetIn.value;
    S.magnet = v / 100;
    magVal.textContent = v === 0 ? 'off' : v <= 50 ? `subtle, ${v}%` : `snaps, ${v}%`;
    if (v <= 50) S.snapped = null;
    render();
  }
  magnetIn.addEventListener('input', magnetLabel);
  magnetIn.addEventListener('change', () => log('magnet', `Magnet strength ${magnetIn.value}%`, +magnetIn.value > 50 ? 'past the middle: snaps onto buttons' : 'damps motion near buttons'));

  // ------------------------------------------------------------------ keyboard
  const held = new Set();
  let raf = 0, speed = 3;
  function keyLoop() {
    if (!held.size) { raf = 0; speed = 3; return; }
    speed = Math.min(speed + 0.35, 12);
    let dx = 0, dy = 0;
    if (held.has('ArrowLeft')) dx -= speed; if (held.has('ArrowRight')) dx += speed;
    if (held.has('ArrowUp')) dy -= speed; if (held.has('ArrowDown')) dy += speed;
    S.yaw = clamp(S.yaw + dx * 0.25, -25, 25); S.pitch = clamp(S.pitch - dy * 0.25, -22, 22);
    if (S.air) moveBy(dx, dy, 'gyro'); else { render(); maybeAirOffHint(dx, dy); }
    raf = requestAnimationFrame(keyLoop);
  }
  const keyOk = (e) => !e.target.closest('input, button, .seg, [role="button"], a');
  stage.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || !keyOk(e)) return;
    if (e.key.startsWith('Arrow')) { e.preventDefault(); held.add(e.key); if (!raf) raf = requestAnimationFrame(keyLoop); return; }
    if (e.repeat) { if (e.key === ' ') e.preventDefault(); return; }
    const k = e.key.toLowerCase();
    if (k === ' ') { e.preventDefault(); B.trigger.classList.add('down'); trigDown('space'); }
    else if (k === 'h') { B.home.classList.add('down'); press.home.down(); }
    else if (k === 'b' || k === 'escape') { B.back.classList.add('down'); press.back.down(); }
    else if (k === '+' || k === '=') { B.up.classList.add('down'); press.up.down(); }
    else if (k === '-' || k === '_') { B.down.classList.add('down'); press.down.down(); }
    else if (k === 'r') rightClick();
  });
  stage.addEventListener('keyup', (e) => {
    held.delete(e.key);
    const k = e.key.toLowerCase();
    if (k === ' ') { e.preventDefault(); trigUp('space'); }
    else if (k === 'h') { B.home.classList.remove('down'); press.home.up(); }
    else if (k === 'b' || k === 'escape') B.back.classList.remove('down');
    else if (k === '+' || k === '=') { B.up.classList.remove('down'); press.up.up(); }
    else if (k === '-' || k === '_') { B.down.classList.remove('down'); press.down.up(); }
  });
  stage.addEventListener('focusout', (e) => { if (!stage.contains(e.relatedTarget)) { held.clear(); if (S.trig.srcs.has('space')) trigUp('space'); } });

  // ------------------------------------------------------------------ boot
  function tick() {
    const d = new Date();
    $('#clock').textContent = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }
  tick(); setInterval(tick, 30000);
  setTrack(0);
  S.x = W() * 0.62; S.y = H() * 0.5;
  magnetLabel(); renderSteps(); status(); render();
  new ResizeObserver(() => render()).observe(screen);
})();
