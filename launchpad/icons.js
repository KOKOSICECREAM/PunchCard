// PunchCard's own icons and honour marks (no emoji anywhere on the site or in the apps).
// Line icons are 24×24, drawn in the current text colour. Honour marks are a tiny punch card:
// one hole burned through per level; Inferno (the top honour) is all four on a gold card.
const svg = (body, fill = false) => `<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" ${fill ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'}>${body}</svg>`;

export const ICONS = {
  pin: svg('<path d="M12 21s-7-6.2-7-11a7 7 0 0 1 14 0c0 4.8-7 11-7 11Z"/><circle cx="12" cy="10" r="2.5"/>'),
  launch: svg('<rect x="3" y="10" width="18" height="11" rx="2.5"/><circle cx="7" cy="14" r=".6"/><circle cx="7" cy="17.5" r=".6"/><path d="M14 17.5V3m-4 4 4-4 4 4"/>'),
  qr: svg('<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><path d="M14 14h3v3h-3zM21 14v.01M14 21h.01M17 21h4v-3"/>'),
  camera: svg('<path d="M4 8h3l2-3h6l2 3h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1Z"/><circle cx="12" cy="14" r="3.5"/>'),
  ticket: svg('<path d="M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v3a2 2 0 0 0 0 4v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-3a2 2 0 0 0 0-4Z"/><path d="M14.5 5.5v13" stroke-dasharray="1.5 2.5"/>'),
  flame: svg('<path d="M12 2c.6 3.2-1.5 4.6-1.5 7 0 1.4.9 2.3 2 2.3s1.9-.9 1.9-2.3c2.2 1.9 3.6 4.4 3.6 7A6 6 0 0 1 6 16c0-3.1 1.9-5.4 3.5-7.4C11.1 6.6 12.2 4.6 12 2Z"/>', true),
  door: svg('<path d="M14 3h5a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-5"/><path d="M9 17l5-5-5-5M14 12H3"/>'),
};

export const HONOURS = [
  { key: 'inferno', name: 'Inferno', rank: 4, min: 3 },
  { key: 'blaze', name: 'Blaze', rank: 3, min: 2 },
  { key: 'flame', name: 'Flame', rank: 2, min: 1 },
  { key: 'ember', name: 'Ember', rank: 1, min: 0.5 },
];
/** The honour a first buy of `sol` earns (when part of it is burned), or null. */
export const honourFor = (sol) => HONOURS.find((h) => sol >= h.min) || null;
/** Tiny punch card with `rank` holes burned through (gold card for Inferno). */
export const honourMark = (rank, big = false) => `<span class="hmark r${rank}${rank >= 4 ? ' gold' : ''}${big ? ' lg' : ''}" aria-hidden="true"><i></i><i></i><i></i><i></i></span>`;
/** Honour pill: mark + name. Accepts { key, name, rank } from the API or honourFor(). */
export const honourPill = (t) => (t ? `<span class="honour h-${t.key}">${honourMark(t.rank)}${t.name}</span>` : '');
