// Page chrome: release link, lightbox, copy buttons, hero tilt, packet strip.
(() => {
  'use strict';
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ------------------------------------------------ latest release DMG
  const FALLBACK = 'https://github.com/dennisonbertram/gearvr-controller/releases/latest';
  const fmtMB = (n) => (n / 1048576).toFixed(1) + ' MB';
  fetch('https://api.github.com/repos/dennisonbertram/gearvr-controller/releases/latest', {
    headers: { Accept: 'application/vnd.github+json' },
  })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error('HTTP ' + r.status))))
    .then((rel) => {
      const dmg = (rel.assets || []).find((a) => /\.dmg$/i.test(a.name));
      if (!dmg) throw new Error('no dmg');
      const version = String(rel.tag_name || '').replace(/^v/i, '');
      document.querySelectorAll('.js-download').forEach((a) => {
        a.href = dmg.browser_download_url;
        a.setAttribute('download', '');
      });
      document.querySelectorAll('.js-dl-meta').forEach((el) => {
        el.textContent = `Version ${version}, ${fmtMB(dmg.size)}, macOS 14 or later`;
      });
      document.querySelectorAll('.js-dl-meta-inline').forEach((el) => {
        el.textContent = `(version ${version}, ${fmtMB(dmg.size)})`;
      });
    })
    .catch(() => {
      document.querySelectorAll('.js-download').forEach((a) => { a.href = FALLBACK; });
    });

  // ------------------------------------------------ lightbox
  const dlg = document.getElementById('lightbox');
  const lbImg = document.getElementById('lbImg');
  const lbCap = document.getElementById('lbCap');
  document.querySelectorAll('#shots figure button').forEach((btn) => {
    btn.addEventListener('click', () => {
      const img = btn.querySelector('img');
      lbImg.src = img.currentSrc || img.src;
      lbImg.alt = img.alt;
      lbCap.textContent = btn.parentElement.querySelector('figcaption')?.textContent || '';
      if (typeof dlg.showModal === 'function') dlg.showModal();
      else window.open(img.src, '_blank');
    });
  });
  dlg?.addEventListener('click', (e) => { if (e.target === dlg) dlg.close(); });

  // ------------------------------------------------ copy buttons
  document.querySelectorAll('[data-copy]').forEach((b) => {
    b.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(b.dataset.copy);
        const t = b.textContent;
        b.textContent = 'Copied';
        b.classList.add('ok');
        setTimeout(() => { b.textContent = t; b.classList.remove('ok'); }, 1600);
      } catch { /* clipboard blocked: the commands are visible above */ }
    });
  });

  // ------------------------------------------------ hero icon follows the pointer
  const icon = document.querySelector('.hero-icon');
  const art = document.querySelector('.hero-art');
  if (icon && art && !reduce && matchMedia('(hover: hover)').matches) {
    const hero = document.querySelector('.hero');
    hero.addEventListener('pointermove', (e) => {
      const r = art.getBoundingClientRect();
      const x = (e.clientX - (r.left + r.width / 2)) / innerWidth;
      const y = (e.clientY - (r.top + r.height / 2)) / innerHeight;
      icon.style.transform = `rotateY(${(x * 22).toFixed(2)}deg) rotateX(${(-y * 22).toFixed(2)}deg)`;
    });
    hero.addEventListener('pointerleave', () => { icon.style.transform = ''; });
  }

  // ------------------------------------------------ an example 60-byte packet, coloured by field
  const hex = document.getElementById('hex');
  if (hex) {
    const bytes = new Uint8Array(60);
    const v = new DataView(bytes.buffer);
    let t = 1843210;
    for (let s = 0; s < 3; s++, t += 4850) {
      const o = s * 16;
      v.setUint32(o, t, true);
      [12, -40, 2061].forEach((a, i) => v.setInt16(o + 4 + i * 2, a + s * 3, true));
      [71, -128, 15].forEach((g, i) => v.setInt16(o + 10 + i * 2, g - s * 5, true));
    }
    [-311, 205, -87].forEach((m, i) => v.setInt16(48 + i * 2, m, true));
    const x = 160, y = 220; // finger on the touchpad
    bytes[54] = 0x10 | (x >> 6); bytes[55] = ((x & 0x3f) << 2) | (y >> 8); bytes[56] = y & 0xff;
    bytes[57] = 27; bytes[58] = 0x41; bytes[59] = 84;
    const cls = (i) => i >= 59 ? 'k-bat' : i === 58 ? 'k-btn' : i === 57 ? 'k-tmp' : i >= 54 ? 'k-tch' : i >= 48 ? 'k-mag'
      : (i % 16) < 4 ? 'k-ts' : (i % 16) < 10 ? 'k-acc' : 'k-gyr';
    hex.innerHTML = Array.from(bytes, (b, i) => `<span class="${cls(i)}">${b.toString(16).padStart(2, '0')}</span>`).join('');
  }
})();
