// Urejanje: the workshop behind the remote.
//
// Everything here writes -- to a page, to settings.json, or to the slot the box
// runs its own software out of -- which is why this half is what the password
// guards and `/` is not.

import { html, render, useEffect, useLayoutEffect, useRef, useState } from '/static/preact.js';
import { api, flipSkin, json, skin } from '/static/common.js';
import { previewHtml } from '/static/markdown.js';

/// How many rows the shelf draws at once; the rest are one search away. A
/// songbook can hold a whole hymnal, and a list of a thousand buttons is slow
/// to build and useless to scroll.
const MOST_ROWS = 120;

/// What the updater in the image concluded, in a sentence. The states are the
/// ones nix/scripts/update_check.sh writes; anything this version has not heard
/// of is shown as it came, rather than swallowed -- a box running an older app
/// than its updater should still say something true.
function updateSays(update) {
  const version = update.available || '';
  switch (update.state) {
    case 'off': return 'Samodejno iskanje posodobitev je izklopljeno.';
    case 'offline': return 'Naprava nima povezave z internetom, zato posodobitev ne more preveriti.';
    case 'current': return 'Nameščena različica ' + (update.running || '') + ' je najnovejša.';
    case 'downloading': return 'Prenašam ' + version + ' …';
    case 'ready': return version + ' je pripravljena za namestitev.';
    case 'failed': return update.error || 'Zadnje preverjanje ni uspelo.';
    default: return update.state;
  }
}

const isMarkdown = (file) => /\.(md|markdown|txt)$/i.test(file.name);
const isImage = (file) => file.type.startsWith('image/');

/// The songbook list. It is the sidebar on a laptop and a modal on a phone,
/// where a permanent list would leave the editor a slot too small to write in.
function PageList({ pages, find, setFind, editing, live, onPick, onCreate }) {
  const needle = find.trim().toLowerCase();
  const matching = needle
    ? pages.filter((page) =>
        String(page.number).startsWith(needle) || page.title.toLowerCase().includes(needle))
    : pages;
  const shown = matching.slice(0, MOST_ROWS);

  return html`
    <div class="shelf-head">
      <input
        class="find" type="text" inputmode="search" placeholder="Poišči stran"
        value=${find} onInput=${(e) => setFind(e.target.value)}
      />
      <button onClick=${onCreate}>Nova stran</button>
    </div>
    <div class="pages">
      ${shown.map((page) => html`
        <button
          class=${'page-row' + (page.number === editing ? ' on' : '')}
          onClick=${() => onPick(page.number)}
        >
          <span class="n">${page.number}</span>
          <span class="t">${page.title}</span>
          <span class="stencil">
            ${page.number === live ? 'na zaslonu' : ''}
            ${page.scale !== 1 ? Math.round(page.scale * 100) + '%' : ''}
          </span>
        </button>`)}
      ${pages.length === 0 &&
        html`<p class="empty-note">Pesmarica je prazna. Začni z <b>Nova stran</b>.</p>`}
      ${matching.length === 0 && pages.length > 0 &&
        html`<p class="empty-note">Nič ne ustreza.</p>`}
      ${matching.length > shown.length &&
        html`<p class="empty-note">Še ${matching.length - shown.length} strani — poišči jih.</p>`}
    </div>`;
}

function Manage() {
  const [state, setState] = useState({ pages: [], settings: {}, fonts: [] });
  const [editing, setEditing] = useState(null);
  const [source, setSource] = useState('');
  // The front matter, as fields. The editor never shows the `---` header: a
  // person who can write a hymn should not have to know YAML to give the page
  // a title, and a stray character in that block takes the page off the wall.
  const [front, setFront] = useState(null);
  const [dirty, setDirty] = useState(false);
  const [previewing, setPreviewing] = useState(false);
  const [note, setNote] = useState({ text: 'Izberi stran.', bad: false });
  const [light, setLight] = useState(skin() === 'light');
  const [live, setLive] = useState(null);
  const [find, setFind] = useState('');
  const rev = useRef(-1);
  const ticks = useRef(0);
  const area = useRef(null);
  const settings = useRef(null);
  const pendingSelection = useRef(null);
  const imagePicker = useRef(null);
  const chooser = useRef(null);
  const menu = useRef(null);
  const sheetSettings = useRef(null);
  const network = useRef(null);
  const updates = useRef(null);

  // What wifi.conf on the boot partition says. Fetched when the dialog is
  // opened rather than polled: it changes when somebody changes it, and the
  // remote's poll has to stay small.
  const [net, setNet] = useState(null);
  const [joining, setJoining] = useState({ ssid: '', psk: '', country: '' });

  const say = (text, bad = false) => setNote({ text, bad });
  const s = state.settings;

  /// Everything that writes answers with the whole state, so take the new
  /// revision from it too and do not go back for what we already hold.
  const adopt = (next) => {
    rev.current = next.rev;
    setState(next);
    return next;
  };

  const refresh = async () => adopt(await api('/api/state'));

  // The same cheap poll the remote uses: what is on the screen, and a counter.
  // The songbook itself is fetched again only when that counter moves.
  useEffect(() => {
    const tick = async () => {
      const now = await api('/api/remote');
      setLive(now.current);
      // Once a minute regardless: an update finishing its download is nobody's
      // edit, so the revision does not move for it, and it is the one thing on
      // this page that changes by itself. Fifteen ticks rather than a second
      // timer, and only here -- the remote's poll stays what it was.
      if (now.rev !== rev.current || ++ticks.current % 15 === 0) await refresh();
    };
    tick().catch((e) => say(e.message, true));
    const timer = setInterval(() => { if (!dirty) tick().catch(() => {}); }, 4000);
    return () => clearInterval(timer);
  }, [dirty]);

  // --- Pages --------------------------------------------------------------

  const open = async (number) => {
    if (dirty && !confirm('Neshranjene spremembe. Nadaljujem?')) return;
    try {
      const page = await api('/api/pages/' + number);
      setEditing(number);
      setSource(page.body);
      setFront(page.front);
      setDirty(false);
      say('Naložena stran ' + page.number + ' · ' + page.file);
    } catch (e) { say(e.message, true); }
  };

  const save = async () => {
    if (editing == null) return say('Ni izbrane strani.', true);
    try {
      adopt(await json('/api/pages/' + editing, 'PUT', { front, body: source }));
      setDirty(false);
      say('Shranjeno. Zaslon se osveži sam.');
    } catch (e) { say(e.message, true); }
  };

  const create = async () => {
    const title = prompt('Naslov nove strani:', 'Nova pesem');
    if (title === null) return;
    const number = prompt('Številka strani (prazno = naslednja prosta):', '');
    if (number === null) return;
    try {
      const body = number.trim() ? { title, number: Number(number) } : { title };
      const created = await json('/api/pages', 'POST', body);
      adopt(created);
      await open(created.number);
    } catch (e) { say(e.message, true); }
  };

  const remove = async () => {
    if (editing == null) return;
    if (!confirm('Izbrišem stran ' + editing + '?')) return;
    try {
      adopt(await api('/api/pages/' + editing, { method: 'DELETE' }));
      setEditing(null);
      setSource('');
      setFront(null);
      setDirty(false);
      say('Izbrisano.');
    } catch (e) { say(e.message, true); }
  };

  /// The number is the running order -- there is no separate index to drag, and
  /// the keypad jumps to the number -- so moving a page means filing it under
  /// another one. The title is the `#` heading, which is edited in the text.
  const renumber = async () => {
    if (editing == null) return;
    const wanted = prompt('Nova številka strani ' + editing + ':', String(editing));
    if (wanted === null || !wanted.trim()) return;
    try {
      const moved = await json('/api/pages/' + editing + '/renumber', 'POST', {
        number: Number(wanted),
      });
      adopt(moved);
      setEditing(moved.number);
      say('Stran je zdaj številka ' + moved.number + '.');
    } catch (e) { say(e.message, true); }
  };

  const show = async () => {
    if (editing == null) return;
    try {
      await api('/api/show/' + editing, { method: 'POST' });
      await refresh();
      say('Stran ' + editing + ' je na zaslonu.');
    } catch (e) { say(e.message, true); }
  };

  // --- Settings -----------------------------------------------------------

  const putSettings = async (patch) => {
    try { adopt(await json('/api/settings', 'PUT', patch)); }
    catch (e) { say(e.message, true); }
  };

  // Rotation is handed to flutter-pi at startup, so the box restarts the
  // display to apply it. The screen goes black for a moment; this page is
  // unaffected.
  const putRotation = (degrees) => {
    if (!confirm('Zaslon se bo znova zagnal. Nadaljujem?')) return;
    putSettings({ rotation: Number(degrees) });
  };

  // --- The editor ---------------------------------------------------------
  //
  // Enough markdown to write a hymn without knowing any: emphasis, headings, a
  // blockquote for the refrain, and a blank line between verses.

  /// Runs an edit over the textarea and keeps the caret where the edit left it.
  /// The value is controlled, so the selection has to be restored after the
  /// render rather than inside the handler.
  const edit = (fn) => {
    setPreviewing(false);
    const node = area.current;
    const result = fn(node.value, node.selectionStart, node.selectionEnd);
    pendingSelection.current = [result.start, result.end];
    setSource(result.value);
    setDirty(true);
    say('Neshranjeno …');
  };

  useLayoutEffect(() => {
    const selection = pendingSelection.current;
    if (!selection || !area.current) return;
    pendingSelection.current = null;
    area.current.focus();
    area.current.setSelectionRange(selection[0], selection[1]);
  });

  /// Puts `mark` on both sides of the selection, or takes it off again when it
  /// is already there, so the same button undoes itself.
  const wrap = (mark) => edit((value, start, end) => {
    const before = value.slice(0, start);
    const selected = value.slice(start, end);
    const after = value.slice(end);
    if (before.endsWith(mark) && after.startsWith(mark)) {
      return {
        value: before.slice(0, -mark.length) + selected + after.slice(mark.length),
        start: start - mark.length,
        end: end - mark.length,
      };
    }
    return {
      value: before + mark + selected + mark + after,
      start: start + mark.length,
      end: end + mark.length,
    };
  });

  /// Prefixes every line the selection touches, and removes the prefix when all
  /// of them already carry it.
  const prefixLines = (mark) => edit((value, start, end) => {
    const from = value.lastIndexOf('\n', start - 1) + 1;
    const to = value.indexOf('\n', end);
    const stop = to === -1 ? value.length : to;
    const lines = value.slice(from, stop).split('\n');
    const has = lines.every((line) => line.startsWith(mark));
    const next = lines
      .map((line) => (has ? line.slice(mark.length) : mark + line))
      .join('\n');
    return {
      value: value.slice(0, from) + next + value.slice(stop),
      start: from,
      end: from + next.length,
    };
  });

  /// A blank line is what separates verses on screen, and the thing operators
  /// most often forget.
  const verseBreak = () => edit((value, start) => ({
    value: value.slice(0, start) + '\n\n' + value.slice(start),
    start: start + 2,
    end: start + 2,
  }));

  useEffect(() => {
    const onKey = (e) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      const key = e.key.toLowerCase();
      if (key === 's') { e.preventDefault(); save(); }
      if (key === 'p') { e.preventDefault(); setPreviewing((on) => !on); }
      if (e.target === area.current && key === 'b') { e.preventDefault(); wrap('**'); }
      if (e.target === area.current && key === 'i') { e.preventDefault(); wrap('*'); }
    };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [source, editing]);

  // --- Import and images --------------------------------------------------

  const importMarkdown = async (files) => {
    const wanted = files.filter(isMarkdown);
    if (!wanted.length) return say('Na seznam spusti .md datoteke.', true);
    let last = null;
    for (const file of wanted) {
      try {
        const result = await api('/api/import?name=' + encodeURIComponent(file.name), {
          method: 'POST', body: await file.text(),
        });
        adopt(result);
        last = result.number;
      } catch (e) { say(file.name + ': ' + e.message, true); }
    }
    if (last !== null) {
      say(wanted.length + ' uvoženih strani.');
      await open(last);
    }
  };

  const insertImages = async (files) => {
    const wanted = files.filter(isImage);
    if (!wanted.length) return say('V besedilo spusti slikovne datoteke.', true);
    if (editing == null) return say('Najprej izberi stran.', true);
    for (const file of wanted) {
      try {
        const result = await api('/api/images?name=' + encodeURIComponent(file.name), {
          method: 'POST', body: file,
        });
        edit((value, start) => ({
          value: value.slice(0, start) + '\n' + result.markdown + '\n' + value.slice(start),
          start: start + result.markdown.length + 2,
          end: start + result.markdown.length + 2,
        }));
        say('Slika dodana: ' + result.path + ' — ne pozabi shraniti.');
      } catch (e) { say(file.name + ': ' + e.message, true); }
    }
  };

  // --- Drag and drop ------------------------------------------------------
  // Markdown dropped on the list becomes new pages; images dropped on the
  // editor are uploaded and referenced at the cursor. A drop anywhere else
  // would make the browser navigate to the file, silently losing unsaved work.

  const [dragging, setDragging] = useState(false);
  useEffect(() => {
    const over = (e) => e.preventDefault();
    const enter = (e) => {
      if (e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files')) {
        setDragging(true);
      }
    };
    const leave = (e) => { if (!e.relatedTarget) setDragging(false); };
    const drop = (e) => { e.preventDefault(); setDragging(false); };
    addEventListener('dragover', over);
    addEventListener('dragenter', enter);
    addEventListener('dragleave', leave);
    addEventListener('drop', drop);
    return () => {
      removeEventListener('dragover', over);
      removeEventListener('dragenter', enter);
      removeEventListener('dragleave', leave);
      removeEventListener('drop', drop);
    };
  }, []);

  const dropZone = (handler) => ({
    onDragOver: (e) => { e.preventDefault(); e.currentTarget.classList.add('dropping'); },
    onDragLeave: (e) => e.currentTarget.classList.remove('dropping'),
    onDrop: (e) => {
      e.preventDefault();
      e.stopPropagation();
      e.currentTarget.classList.remove('dropping');
      setDragging(false);
      handler(Array.from(e.dataTransfer ? e.dataTransfer.files : []));
    },
  });

  // --- Render -------------------------------------------------------------

  const openSettings = () => settings.current.showModal();

  // --- The network --------------------------------------------------------
  //
  // The box is an access point of its own unless it is told to join a network.
  // Either way the pages are at the same address on the same port; what changes
  // is which network you have to be on to reach them.

  const openNetwork = async () => {
    network.current.showModal();
    try {
      const now = await json('/api/network');
      setNet(now);
      setJoining({ ssid: now.wifi.ssid || '', psk: '', country: now.wifi.country || '' });
    } catch (e) { say(e.message, true); }
  };

  /// Both directions of the same call: an ssid to join one, an empty one to be
  /// one again. The reply comes back before the radio moves, because on the
  /// access point the radio is carrying this very request.
  const putNetwork = async (patch, warning) => {
    if (!confirm(warning)) return;
    try {
      const now = await json('/api/network', 'PUT', patch);
      setNet(now);
      setJoining({ ...joining, psk: '' });
      say(patch.ssid
        ? 'Naprava se povezuje. Če omrežja ne najde, se čez pol minute vrne na svoje.'
        : 'Naprava postavlja svoje omrežje. Poveži se nanj.');
      network.current.close();
    } catch (e) { say(e.message, true); }
  };

  // --- Updating -----------------------------------------------------------
  //
  // The box does the looking and the fetching by itself, on a timer in the
  // image; what reaches here is one small file it left behind. The only
  // decision left is a human one -- installing takes the screen away for a
  // couple of minutes, and that must not happen in the middle of a service.

  const openUpdates = () => updates.current.showModal();

  const install = async () => {
    const version = (state.update && state.update.available) || 'novo različico';
    if (!confirm('Naprava bo namestila ' + version +
      ' in se znova zagnala. Zaslon bo nekaj minut prazen. Nadaljujem?')) return;
    try {
      await json('/api/update/install', 'POST', {});
      updates.current.close();
      say('Nameščam ' + version + '. Naprava se znova zaganja.');
    } catch (e) { say(e.message, true); }
  };

  /// A front matter field changes in memory and goes to the card with Shrani,
  /// like every other edit on this page -- so a title and a verse are one save,
  /// and closing the dialog is not a write.
  const setField = (patch) => {
    setFront({ ...front, ...patch });
    setDirty(true);
    say('Neshranjeno …');
  };
  const openChooser = () => { setFind(''); chooser.current.showModal(); };
  const flip = () => setLight(flipSkin() === 'light');
  const lock = async () => {
    await fetch('/api/logout', { method: 'POST' });
    location.href = '/';
  };

  /// Runs one of the sheet's actions from the phone menu, which has to get out
  /// of the way first -- two stacked dialogs would leave the operator tapping
  /// Zapri twice, and a confirm() behind a modal is a trap.
  const act = (action) => {
    menu.current.close();
    action();
  };

  // The one thing about an update that belongs in the chrome rather than behind
  // a menu: a release sitting in the free slot, waiting for somebody to say
  // when. Everything else is a line in the dialog.
  const ready = !!(state.update && state.update.state === 'ready');

  const onSheet = state.pages.find((page) => page.number === editing);
  const title = onSheet ? onSheet.title : '';

  const listProps = {
    pages: state.pages,
    find,
    setFind,
    editing,
    live,
    onCreate: create,
    onPick: (number) => {
      if (chooser.current.open) chooser.current.close();
      open(number);
    },
  };

  const tool = (label, title, onClick) =>
    html`<button title=${title} onClick=${onClick}>${label}</button>`;

  return html`
    <header class="top">
      <span class="mark"><b></b><span class="on-desk">Urejanje</span></span>
      <span class="now on-phone">
        ${editing == null
          ? html`<span class="stencil">Ni izbrane strani</span>`
          : html`<span class="n">${editing}</span> ${title}`}
      </span>
      <span class="grow"></span>
      ${ready && html`<button class="quiet on-desk" onClick=${openUpdates}>Posodobitev</button>`}
      <button class="quiet on-desk" onClick=${openSettings}>Nastavitve</button>
      <button class="link on-desk" onClick=${flip}>${light ? 'Temno' : 'Svetlo'}</button>
      <a class="link on-desk" href="/">Daljinec</a>
      ${state.protected && html`<button class="quiet on-desk" onClick=${lock}>Zakleni</button>`}
      <button class="on-phone more" onClick=${() => menu.current.showModal()}
        title="Več">•••</button>
    </header>

    <main class="work">
      <div class="shelf" ...${dropZone(importMarkdown)}>
        <${PageList} ...${listProps} />
      </div>

      <div class="sheet" ...${dropZone((files) =>
        files.some(isMarkdown) && !files.some(isImage)
          ? importMarkdown(files) : insertImages(files))}>
        <div class="sheet-head on-desk">
          <span class="what">
            ${editing == null
              ? html`<span class="stencil">Ni izbrane strani</span>`
              : html`<span class="n">${editing}</span>`}
          </span>
          <span class="grow"></span>
          <button onClick=${() => sheetSettings.current.showModal()}
            disabled=${editing == null}>Nastavitve strani</button>
          <button onClick=${renumber} disabled=${editing == null}
            title="Številka je vrstni red">Preštevilči</button>
          <button onClick=${show} disabled=${editing == null}>Prikaži</button>
          <button class="primary" onClick=${save} disabled=${editing == null}>Shrani</button>
          <button class="danger" onClick=${remove} disabled=${editing == null}>Izbriši</button>
        </div>

        <div class="tools">
          ${tool(html`<b>B</b>`, 'Krepko (⌘B)', () => wrap('**'))}
          ${tool(html`<i>I</i>`, 'Ležeče (⌘I)', () => wrap('*'))}
          <span class="sep"></span>
          ${tool('H1', 'Naslov', () => prefixLines('# '))}
          ${tool('H2', 'Podnaslov', () => prefixLines('## '))}
          ${tool('”', 'Zbor ali refren', () => prefixLines('> '))}
          ${tool('•', 'Seznam', () => prefixLines('- '))}
          <span class="sep"></span>
          ${tool('Kitica', 'Prelom kitice', verseBreak)}
          ${tool('Slika', 'Vstavi sliko', () => imagePicker.current.click())}
        </div>

        ${previewing
          ? html`<div class="preview" dangerouslySetInnerHTML=${{ __html: previewHtml(source) }}></div>`
          : html`<textarea
              ref=${area} spellcheck="false" value=${source}
              placeholder=${'# Naslov pesmi\n\nPrva kitica ...'}
              onInput=${(e) => { setSource(e.target.value); setDirty(true); say('Neshranjeno …'); }}
            ></textarea>`}

        <div class="sheet-foot on-desk">
          <span class=${'say grow' + (note.bad ? ' bad' : '')}>${note.text}</span>
          <button
            class=${previewing ? 'on' : ''}
            title="Predogled (⌘P)"
            onClick=${() => setPreviewing(!previewing)}
          >Predogled</button>
        </div>

        <div class="phone-bar on-phone">
          <button onClick=${openChooser}>Strani</button>
          <span class=${'say grow' + (note.bad ? ' bad' : '')}>${note.text}</span>
          <button class=${previewing ? 'on' : ''} onClick=${() => setPreviewing(!previewing)}
            title="Predogled">Predogled</button>
          <button class="primary" onClick=${save} disabled=${editing == null}>Shrani</button>
        </div>
      </div>
    </main>

    ${dragging && html`<div class="drophint">
      Markdown spusti levo na seznam · sliko spusti desno v besedilo
    </div>`}

    <input ref=${imagePicker} type="file" accept="image/*" multiple hidden
      onChange=${async (e) => { await insertImages(Array.from(e.target.files)); e.target.value = ''; }} />

    <dialog ref=${sheetSettings}>
      <h2>Nastavitve strani ${editing ?? ''}</h2>
      ${front && html`
        <label class="field">
          <span class="stencil">Naslov</span>
          <input type="text" value=${front.title || ''} placeholder=${front.derived}
            onInput=${(e) => setField({ title: e.target.value })} />
          <span class="hint">Prazno: uporabi se naslov iz besedila, torej vrstica z <b>#</b>.</span>
        </label>

        <label class="field">
          <span class="stencil">Povečava — ${Math.round(front.scale * 100)} %</span>
          <input type="range" min="40" max="400" step="5"
            value=${Math.round(front.scale * 100)}
            onInput=${(e) => setField({ scale: Number(e.target.value) / 100 })} />
          <span class="hint">
            Velja samo za to stran. 100 % je toliko, kot znaša povečava cele pesmarice.
          </span>
        </label>

        <label class="field">
          <span class="stencil">Postavitev</span>
          <select value=${front.align} onInput=${(e) => setField({ align: e.target.value })}>
            <option value="start">na vrhu strani</option>
            <option value="center">na sredini</option>
          </select>
        </label>

        <label class="field">
          <span class="stencil">Naslov na zaslonu</span>
          <select
            value=${front.showTitle === null || front.showTitle === undefined ? '' : String(front.showTitle)}
            onInput=${(e) => setField({
              showTitle: e.target.value === '' ? null : e.target.value === 'true',
            })}
          >
            <option value="">kot v nastavitvah zaslona</option>
            <option value="true">pokaži</option>
            <option value="false">skrij</option>
          </select>
        </label>

        ${Object.keys(front.extra || {}).length > 0 && html`<p class="warn">
          Ta stran ima še zapise, ki jih Pesmarica ne uporablja:
          ${' ' + Object.keys(front.extra).join(', ')}. Ostanejo, kakršni so.
        </p>`}

        <p class="hint">Spremembe se zapišejo, ko shraniš stran.</p>`}
      <menu>
        <button class="primary" onClick=${() => sheetSettings.current.close()}>Zapri</button>
      </menu>
    </dialog>

    <dialog class="menu" ref=${menu}>
      <h2>Stran ${editing == null ? '—' : editing}</h2>
      <button onClick=${() => act(() => sheetSettings.current.showModal())}
        disabled=${editing == null}>Nastavitve strani</button>
      <button onClick=${() => act(show)} disabled=${editing == null}>Prikaži na zaslonu</button>
      <button onClick=${() => act(renumber)} disabled=${editing == null}
        title="Številka je vrstni red">Preštevilči</button>
      <button class="danger" onClick=${() => act(remove)} disabled=${editing == null}>Izbriši stran</button>
      <hr />
      <button onClick=${() => act(openSettings)}>Nastavitve zaslona</button>
      <button onClick=${() => act(openNetwork)}>Omrežje</button>
      <button onClick=${() => act(openUpdates)}>
        ${ready ? 'Posodobitev je pripravljena' : 'Posodobitev'}
      </button>
      <button onClick=${() => { flip(); menu.current.close(); }}>
        ${light ? 'Temna barvna shema' : 'Svetla barvna shema'}
      </button>
      <a class="row-link" href="/">Nazaj na daljinec</a>
      ${state.protected && html`<button onClick=${() => act(lock)}>Zakleni urejanje</button>`}
      <menu><button class="primary" onClick=${() => menu.current.close()}>Zapri</button></menu>
    </dialog>

    <dialog class="finder" ref=${chooser}>
      <${PageList} ...${listProps} />
      <menu><button onClick=${() => chooser.current.close()}>Zapri</button></menu>
    </dialog>

    <dialog ref=${settings}>
      <h2>Nastavitve zaslona</h2>
      <label class="field">
        <span class="stencil">Barve</span>
        <select value=${s.theme || 'dark'} onChange=${(e) => putSettings({ theme: e.target.value })}>
          <option value="dark">belo na črnem</option>
          <option value="light">črno na belem</option>
        </select>
      </label>
      <label class="field">
        <span class="stencil">Pisava</span>
        <select value=${s.font || 'inter'} onChange=${(e) => putSettings({ font: e.target.value })}>
          ${(state.fonts || []).map((f) => html`<option value=${f.id}>${f.label}</option>`)}
        </select>
      </label>
      <label class="field">
        <span class="stencil">Povečava</span>
        <input type="number" min="0.4" max="4" step="0.05" value=${s.baseScale ?? 1}
          onChange=${(e) => putSettings({ baseScale: Number(e.target.value) })} />
      </label>
      <label class="field">
        <span class="stencil">Zasuk</span>
        <select value=${String(s.rotation ?? 0)} onChange=${(e) => putRotation(e.target.value)}>
          ${[0, 90, 180, 270].map((d) => html`<option value=${String(d)}>${d}°</option>`)}
        </select>
      </label>
      <label class="field inline">
        <input type="checkbox" checked=${s.showTitle !== false}
          onChange=${(e) => putSettings({ showTitle: e.target.checked })} />
        <span>Naslovi na zaslonu</span>
      </label>

      <p class="warn">Zasuk znova zažene zaslon.</p>
      <menu>
        <button class="primary" onClick=${() => settings.current.close()}>Zapri</button>
      </menu>
    </dialog>

    <dialog ref=${network}>
      <h2>Omrežje</h2>
      ${net && !net.available && html`
        <p class="hint">
          Ta naprava nima zagonskega razdelka, zato omrežja od tu ni mogoče
          nastaviti. To velja za razvojni računalnik, ne za zaslon.
        </p>`}
      ${net && net.available && html`
        <p class="hint">
          Brez imena omrežja naprava postavi svoje, na katero se povežeš s
          telefonom. Z imenom se poveže na obstoječe omrežje in je dosegljiva na
          <code>pesmarica.local</code>.
        </p>
        ${net.status && html`<p class="hint">Zadnjič: ${net.status}</p>`}
        <label class="field">
          <span class="stencil">Ime omrežja</span>
          <input type="text" maxlength="32" placeholder="brez imena: svoje omrežje"
            value=${joining.ssid}
            onInput=${(e) => setJoining({ ...joining, ssid: e.target.value })} />
        </label>
        <label class="field">
          <span class="stencil">Geslo</span>
          <input type="password" autocomplete="off"
            placeholder=${net.wifi.hasPassphrase ? 'shranjeno — pusti prazno' : 'brez gesla: odprto omrežje'}
            value=${joining.psk}
            onInput=${(e) => setJoining({ ...joining, psk: e.target.value })} />
        </label>
        <label class="field">
          <span class="stencil">Država</span>
          <input type="text" maxlength="2" placeholder="SI" value=${joining.country}
            onInput=${(e) => setJoining({ ...joining, country: e.target.value.toUpperCase() })} />
        </label>
        <p class="warn">
          Naprava se bo za nekaj trenutkov umaknila z omrežja. Če se na izbrano
          omrežje ne poveže, čez pol minute spet postavi svoje — brez posega.
        </p>`}
      <menu>
        ${net && net.available && html`
          <button class="danger"
            onClick=${() => putNetwork({ ssid: '' }, 'Naprava bo postavila svoje omrežje. Nadaljujem?')}>
            Svoje omrežje
          </button>
          <button class="primary" disabled=${!joining.ssid.trim()}
            onClick=${() => putNetwork(
              joining.psk
                ? { ssid: joining.ssid, psk: joining.psk, country: joining.country }
                : { ssid: joining.ssid, country: joining.country },
              'Naprava se bo povezala na "' + joining.ssid + '". Nadaljujem?')}>
            Poveži
          </button>`}
        <button onClick=${() => network.current.close()}>Zapri</button>
      </menu>
    </dialog>

    <dialog ref=${updates}>
      <h2>Posodobitev</h2>
      ${!state.update && html`
        <p class="hint">
          Ta naprava se ne posodablja sama. To velja za razvojni računalnik, ne
          za zaslon.
        </p>`}
      ${state.update && html`
        <p class="hint">${updateSays(state.update)}</p>
        ${state.update.checked &&
          html`<p class="hint">Nazadnje preverjeno: ${state.update.checked}</p>`}
        <label class="field inline">
          <input type="checkbox" checked=${s.autoUpdate === true}
            onChange=${(e) => putSettings({ autoUpdate: e.target.checked })} />
          <span>Sama poišči in prenesi novo različico</span>
        </label>
        <p class="hint">
          Naprava prenese novo različico v prosti razdelek na kartici in počaka.
          Nameščena ni nikoli sama — to je ta gumb.
        </p>
        ${ready && html`
          <p class="warn">
            Med nameščanjem se naprava znova zažene in zaslon je nekaj minut
            prazen. Prejšnja različica ostane na kartici.
          </p>`}`}
      <menu>
        ${ready && html`<button class="primary" onClick=${install}>Namesti</button>`}
        <button onClick=${() => updates.current.close()}>Zapri</button>
      </menu>
    </dialog>`;
}

render(html`<${Manage} />`, document.getElementById('app'));
