// Renders preview.png: the three menu bar glyphs on light and dark menu bars at 2x and 1x.
// NODE_PATH=$(npm root -g) node render_preview.js
const { chromium } = require('playwright');
const fs = require('fs');
const st = ['idle', 'dictating', 'meeting'];
const g = (s, ink, px) => fs.readFileSync(`${s}.svg`, 'utf8').replace('<svg ', `<svg width="${px}" height="${px}" `).replace(/#000"/g, `${ink}"`).replace(/fill="#000"/g, `fill="${ink}"`);
const bar = (bg, ink, px) => `<div style="background:${bg};height:24px;display:flex;align-items:center;gap:14px;padding:0 12px;font:13px -apple-system,Helvetica;color:${ink}">
  <span style="opacity:.85">Wi-Fi</span>${st.map(s => `<span style="display:flex;align-items:center;gap:6px">${g(s, ink, px)}<span style="font-size:10px;opacity:.6">${s}</span></span>`).join('')}<span style="opacity:.85">Tue 9:41</span></div>`;
(async () => {
  for (const scale of [2, 1]) {
    const b = await chromium.launch();
    const p = await b.newPage({ viewport: { width: 420, height: 200 }, deviceScaleFactor: scale });
    await p.setContent(`<html><body style="margin:0;background:#fff">
      ${bar('#ececec', '#1d1d1f', 18)}<div style="height:8px"></div>${bar('#2a2a2c', '#f5f5f3', 18)}
      <div style="display:flex;gap:24px;padding:16px">${st.map(s => g(s, '#1d1d1f', 96)).join('')}</div></body></html>`);
    await p.screenshot({ path: `preview@${scale}x.png`, fullPage: true });
    await b.close();
  }
})();
