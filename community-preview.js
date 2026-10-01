/* Demo-only interactions: no wallet, storage, API or financial actions. */
(function () {
  'use strict';
  const title = document.querySelector('[data-pc-typewriter]');
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  if (title && !motion.matches) {
    const original = title.innerHTML;
    title.setAttribute('aria-label', 'Support the businesses you love.');
    const visual = document.createElement('span');
    visual.setAttribute('aria-hidden', 'true');
    visual.innerHTML = original;
    const walker = document.createTreeWalker(visual.querySelector('[data-pc-typewriter-line]'), NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    const letters = [];
    nodes.forEach(node => {
      const fragment = document.createDocumentFragment();
      node.textContent.split(/(\s+)/).forEach(word => {
        if (/^\s+$/.test(word)) { fragment.append(document.createTextNode(word)); return; }
        const wrap = document.createElement('span');
        wrap.className = 'pc-typing-word';
        Array.from(word).forEach(character => {
          const letter = document.createElement('span');
          letter.textContent = character;
          letter.className = 'pc-letter-pending';
          letters.push(letter); wrap.append(letter);
        });
        fragment.append(wrap);
      });
      node.replaceWith(fragment);
    });
    title.replaceChildren(visual);
    let index = 0, timer;
    function finish() { clearTimeout(timer); title.innerHTML = original; title.removeAttribute('aria-label'); motion.removeEventListener('change', finish); }
    function type() {
      if (index) letters[index - 1].classList.remove('pc-letter-current');
      if (index === letters.length) { finish(); return; }
      letters[index].className = 'pc-letter-current'; index++;
      timer = setTimeout(type, 140);
    }
    motion.addEventListener('change', finish);
    type();
  }
  const list = document.getElementById('pc-ranks');
  if (!list) return;
  const samples = [
    {name:'Little Ritual Coffee', ticker:'RITUAL', line:'Coffee & conversation', icon:'☕', growth:128, support:3.4, age:12},
    {name:'Corner Taco Club', ticker:'TACO', line:'The late-night favorite', icon:'🌮', growth:96, support:5.2, age:3},
    {name:'Sunday Flowers', ticker:'BLOOM', line:'Good things growing', icon:'🌼', growth:74, support:1.8, age:1}
  ];
  const descriptions = {
    growth:'Example ranking by new holder wallets this week. Wallets are not necessarily unique people.',
    support:'Example ranking by creator fees paid to businesses this week, in SOL. These are fictional payouts.',
    new:'Example ranking by launch date, newest first. These are fictional launches.'
  };
  document.querySelectorAll('[data-pc-sort]').forEach(button => button.addEventListener('click', () => {
    const sort = button.dataset.pcSort;
    const rows = [...samples].sort((a,b) => sort === 'new' ? a.age-b.age : b[sort]-a[sort]);
    document.querySelectorAll('[data-pc-sort]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.getElementById('pc-metric').textContent = descriptions[sort];
    list.replaceChildren(...rows.map((item, index) => {
      const row = document.createElement('li');
      // All content below is a fixed fictional fixture, never user or API input.
      row.innerHTML = `<span class="pc-position">0${index+1}</span><span class="pc-avatar">${item.icon}</span><span class="pc-business"><b>${item.name}</b><small>$${item.ticker} · ${item.line}</small></span><span class="pc-score"><b>${sort === 'growth' ? '+'+item.growth : sort === 'support' ? item.support.toFixed(1)+' SOL' : item.age+'d ago'}</b><small>${sort === 'growth' ? 'holder wallets' : sort === 'support' ? 'paid to business' : 'example launch'}</small></span>`;
      return row;
    }));
  }));
})();
