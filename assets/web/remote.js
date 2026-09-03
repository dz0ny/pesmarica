// The remote.
//
// This is the page almost everyone who touches Pesmarica will ever see, and it
// needs no password: whoever is in the room is already looking at the words on
// the wall, and the person who happens to be free to drive the screen is
// usually not the person who knows the password. Editing is what the password
// is for; see _isOpen in admin_server.dart.
//
// It does one thing -- put a page on the screen -- in the two ways an operator
// already knows: type the number and press Enter, or step back and forward.
// The zoom beside them is the same kind of thing: it changes what the room is
// looking at and writes nothing, which is why it may live on the open page.
// The songbook index is a page too long to sit under the keypad, so it opens
// over the top when somebody knows the song by its first line instead.

import { html, render, useEffect, useRef, useState } from '/static/preact.js';
import { SquarePen } from '/static/icons.js';
import { api, flipSkin, skin } from '/static/common.js';

const POLL = 3000;
const MAX_DIGITS = 5;

/// How many rows the index will draw at once. A songbook of a thousand pages
/// is a thousand buttons on a phone, and nobody scrolls to row 700 -- they
/// type. The rest are one search away, and the list says how many it is not
/// showing rather than pretending it showed everything.
const MOST_ROWS = 120;

function Remote() {
  const [now, setNow] = useState({ current: null, rev: -1, zoom: 1 });
  const [pages, setPages] = useState([]);
  const [typed, setTyped] = useState('');
  const [find, setFind] = useState('');
  const [note, setNote] = useState({ text: '', bad: false });
  const [light, setLight] = useState(skin() === 'light');
  const [online, setOnline] = useState(true);
  const finder = useRef(null);
  const search = useRef(null);

  const say = (text, bad = false) => setNote({ text, bad });

  // The poll is a few bytes: what is on the screen, and a counter. The page
  // list is fetched again only when that counter moves, which on a box holding
  // a whole hymnal is the difference between idling and shipping the songbook
  // to every phone in the room every three seconds.
  const listRev = useRef(-1);
  const load = async () => {
    try {
      const next = await api('/api/remote');
      setNow(next);
      setOnline(true);
      setNote((n) => (n.bad ? { text: '', bad: false } : n));
      if (next.rev !== listRev.current) {
        const index = await api('/api/songbook');
        listRev.current = index.rev;
        setPages(index.pages);
      }
    } catch (_) {
      setOnline(false);
      say('Zaslon se ne odziva.', true);
    }
  };

  // The screen can also be driven from the keypad wired to the box, so this
  // page has to keep up with a number somebody else put on the wall.
  useEffect(() => {
    load();
    const timer = setInterval(load, POLL);
    return () => clearInterval(timer);
  }, []);

  const drive = async (call) => {
    try {
      const next = await api(call, { method: 'POST' });
      setNow(next);
      say(next.ok === false ? 'Te strani ni v pesmarici.' : '', next.ok === false);
    } catch (e) {
      say(e.message, true);
    }
  };

  const show = (number) => {
    setTyped('');
    if (finder.current.open) finder.current.close();
    return drive('/api/show/' + number);
  };

  const type = (digit) => {
    if (typed.length >= MAX_DIGITS) return;
    setTyped(typed + digit);
    say('');
  };
  const rub = () => setTyped(typed.slice(0, -1));
  const commit = () => { if (typed) show(Number(typed)); };

  // A laptop on the access point is a remote too, and its keyboard should do
  // what the keypad wired to the box does.
  useEffect(() => {
    const onKey = (e) => {
      if (e.target.matches('input, textarea') || e.metaKey || e.ctrlKey || e.altKey) return;
      if (/^[0-9]$/.test(e.key)) { e.preventDefault(); type(e.key); }
      else if (e.key === 'Enter') { e.preventDefault(); typed ? commit() : drive('/api/next'); }
      else if (e.key === 'Backspace') { e.preventDefault(); typed ? rub() : drive('/api/prev'); }
      else if (e.key === 'ArrowRight' || e.key === 'ArrowDown') drive('/api/next');
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') drive('/api/prev');
      else if (e.key === '+' || e.key === '=') drive('/api/zoom/in');
      else if (e.key === '-') drive('/api/zoom/out');
      else if (e.key === 'Escape') setTyped('');
    };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [typed]);

  const browse = () => {
    setFind('');
    finder.current.showModal();
    search.current.focus();
  };

  // The zoom is a nudge on top of whatever size the page is written at, and it
  // is deliberately shown as one: it is not stored anywhere, it goes away when
  // the page changes, and the size kept in the songbook is edited at /manage.
  const nudged = Math.round(((now.zoom ?? 1) - 1) * 100);

  const live = pages.find((page) => page.number === now.current);
  const needle = find.trim().toLowerCase();
  const matching = needle
    ? pages.filter((page) =>
        String(page.number).startsWith(needle) || page.title.toLowerCase().includes(needle))
    : pages;
  const shown = matching.slice(0, MOST_ROWS);
  const hidden = matching.length - shown.length;

  return html`
    <header class="top">
      <span class="mark">
        <b class=${online ? '' : 'off'} title=${online ? 'Zaslon odgovarja' : 'Ni povezave'}></b>
        Pesmarica
      </span>
      <span class="grow"></span>
      <button class="link" onClick=${() => setLight(flipSkin() === 'light')}>
        ${light ? 'Temno' : 'Svetlo'}
      </button>
      <a
        class="link icon-link"
        href=${'/manage' + (now.current == null ? '' : '#' + now.current)}
        title="Uredi to stran"
      ><${SquarePen} label="Uredi to stran" /></a>
    </header>

    <main class="remote">
      <section class="board-card">
        <span class="stencil">${typed ? 'Vtipkana številka' : 'Na zaslonu'}</span>
        <div class="readout">
          ${typed
            ? html`<span class="number pending">${typed}<i class="caret"></i></span>`
            : html`<span
                class=${'number slid' + (now.current == null ? ' empty' : '')}
                key=${now.current}
              >${now.current == null ? '—' : now.current}</span>`}
        </div>
        <p class=${'now-title' + (typed || !live ? ' none' : '')}>
          ${typed ? 'Pritisni Pokaži' : live ? live.title : 'Zaslon je prazen'}
        </p>
      </section>

      <div class="step">
        <button onClick=${() => drive('/api/prev')}>◀ Nazaj</button>
        <button onClick=${() => drive('/api/next')}>Naprej ▶</button>
      </div>

      <div class="zoom">
        <button class="key" title="Pomanjšaj" onClick=${() => drive('/api/zoom/out')}>−</button>
        <button
          class="key act" disabled=${nudged === 0}
          title="Nazaj na velikost strani" onClick=${() => drive('/api/zoom/reset')}
        >${nudged === 0 ? 'Velikost' : (nudged > 0 ? '+' : '−') + Math.abs(nudged) + ' %'}</button>
        <button class="key" title="Povečaj" onClick=${() => drive('/api/zoom/in')}>+</button>
      </div>

      <div class="pad">
        ${[1, 2, 3, 4, 5, 6, 7, 8, 9].map(
          (d) => html`<button class="key" onClick=${() => type(String(d))}>${d}</button>`)}
        <button class="key act" disabled=${!typed} onClick=${rub}>Briši</button>
        <button class="key" onClick=${() => type('0')}>0</button>
        <button class="key act go" disabled=${!typed} onClick=${commit}>Pokaži</button>
      </div>

      <button class="browse" onClick=${browse}>Poišči po naslovu</button>

      <p class=${'note' + (note.bad ? ' bad' : '')}>${note.text}</p>
    </main>

    <dialog class="finder" ref=${finder}>
      <div class="finder-head">
        <input
          ref=${search} class="find" type="text" inputmode="search"
          placeholder="Naslov ali številka" value=${find}
          onInput=${(e) => setFind(e.target.value)}
        />
        <button class="link" onClick=${() => finder.current.close()}>Zapri</button>
      </div>
      <div class="pages">
        ${shown.length === 0
          ? html`<p class="empty-note">
              ${pages.length ? 'Nič ne ustreza.' : 'Pesmarica je prazna.'}
            </p>`
          : shown.map((page) => html`
              <button
                class=${'page-row' + (page.number === now.current ? ' on' : '')}
                onClick=${() => show(page.number)}
              >
                <span class="n">${page.number}</span>
                <span class="t">${page.title}</span>
              </button>`)}
        ${hidden > 0 && html`<p class="empty-note">
          Še ${hidden} strani — natipkaj več črk ali številko.
        </p>`}
      </div>
    </dialog>`;
}

render(html`<${Remote} />`, document.getElementById('app'));
