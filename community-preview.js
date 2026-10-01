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
      if (index === letters.length) { finish(); return; }
      letters[index].classList.remove('pc-letter-pending'); index++;
      timer = setTimeout(type, 140);
    }
    motion.addEventListener('change', finish);
    type();
  }
})();
