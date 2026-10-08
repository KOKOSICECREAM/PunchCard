// Shared PunchCard-branded QR code (needs qrcode-generator loaded as the global `qrcode`).
// PunchCard-branded QR: softly rounded modules in ink, corner eyes in PunchCard red and green, and the
// PunchCard logo in the middle. Error correction H keeps it scannable with the logo covering the centre.
const logo = new Promise((res) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => res(null); i.src = '/brand/punchcard.svg'; });
export async function qrImg(text, px = 720) {
  const q = qrcode(0, 'H'); q.addData(text); q.make();
  const n = q.getModuleCount(), quiet = 3, cell = Math.floor(px / (n + quiet * 2)), size = cell * (n + quiet * 2), o = quiet * cell;
  const c = document.createElement('canvas'); c.width = c.height = size;
  const g = c.getContext('2d');
  const INK = '#1c1812', RED = '#a83a20', GREEN = '#3d5a4a';
  g.fillStyle = '#ffffff'; g.fillRect(0, 0, size, size);
  const rr = (x, y, w, h, r) => { // roundRect is missing on iOS 15 and older: draw the corners by hand there
    g.beginPath();
    if (g.roundRect) g.roundRect(x, y, w, h, r);
    else { r = Math.min(r, w / 2, h / 2); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r); g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath(); }
    g.fill();
  };
  const inEye = (r, k) => (r < 7 && k < 7) || (r < 7 && k >= n - 7) || (r >= n - 7 && k < 7);
  const mid = n / 2, hole = Math.ceil(n * 0.24) / 2; // centre area kept clear for the logo
  g.fillStyle = INK;
  for (let r = 0; r < n; r++) for (let k = 0; k < n; k++) {
    if (!q.isDark(r, k) || inEye(r, k)) continue;
    if (Math.abs(r + 0.5 - mid) < hole && Math.abs(k + 0.5 - mid) < hole) continue;
    rr(o + k * cell, o + r * cell, cell, cell, cell * 0.25); // softly rounded; rounder modules stop scanning reliably (tested)
  }
  for (const [r, k] of [[0, 0], [0, n - 7], [n - 7, 0]]) { // corner eyes
    const x = o + k * cell, y = o + r * cell;
    g.fillStyle = RED; rr(x, y, 7 * cell, 7 * cell, cell * 2);
    g.fillStyle = '#ffffff'; rr(x + cell, y + cell, 5 * cell, 5 * cell, cell * 1.4);
    g.fillStyle = GREEN; rr(x + 2 * cell, y + 2 * cell, 3 * cell, 3 * cell, cell);
  }
  const img = await logo, box = hole * 2 * cell, bx = o + mid * cell - box / 2;
  g.fillStyle = '#ffffff'; rr(bx, bx, box, box, cell * 1.5);
  if (img) g.drawImage(img, bx + cell * 0.6, bx + cell * 0.6, box - cell * 1.2, box - cell * 1.2);
  return c.toDataURL('image/png');
}
