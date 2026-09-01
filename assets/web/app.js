const $ = (id) => document.getElementById(id);
let state = { pages: [], settings: {}, fonts: [], current: null };
let editing = null;
let dirty = false;

// Auth is a cookie set at login, so requests carry it on their own. A 401
// means the cookie expired or the password changed: go back to the login page
// rather than filling the screen with failures.
function api(path, options = {}) {
  return fetch(path, options).then(async (r) => {
    if (r.status === 401) {
      location.href = '/login?next=' + encodeURIComponent(location.pathname);
      throw new Error('Prijava je potekla.');
    }
    if (!r.ok) throw new Error(await readError(r));
    return r.status === 204 ? null : r.json();
  });
}

// Errors arrive either as a JSON {error} or as plain text; the operator should
// see the sentence either way, never the envelope around it.
async function readError(response) {
  const text = (await response.text()).trim();
  try {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed.error === 'string') return parsed.error;
  } catch (_) { /* plain text */ }
  return text || response.statusText;
}

function say(message, isError) {
  $('status').textContent = message;
  $('status').className = isError ? 'error' : '';
}


function renderList() {
  const list = $('list');
  list.replaceChildren(...state.pages.map((page) => {
    const row = document.createElement('button');
    row.className = 'row'
      + (page.number === editing ? ' active' : '')
      + (page.number === state.current ? ' live' : '');
    row.innerHTML = '<span class="num"></span><span class="title"></span><span class="meta"></span>';
    row.children[0].textContent = page.number;
    row.children[1].textContent = page.title;
    row.children[2].textContent =
      page.scale !== 1 ? Math.round(page.scale * 100) + '%' : '';
    row.onclick = () => open(page.number);
    return row;
  }));
  $('live').textContent = state.current == null ? 'zaslon prazen' : 'na zaslonu: ' + state.current;
}

function renderSettings() {
  const s = state.settings;
  $('theme').value = s.theme || 'dark';
  $('baseScale').value = s.baseScale ?? 1;
  $('showTitle').checked = s.showTitle !== false;
  if ($('font').options.length !== state.fonts.length) {
    $('font').replaceChildren(...state.fonts.map((f) => new Option(f.label, f.id)));
  }
  $('font').value = s.font || 'inter';
  $('rotation').value = String(s.rotation ?? 0);
}

async function refresh() {
  state = await api('/api/state');
  $('logout').hidden = !state.protected;
  renderList();
  renderSettings();
}

$('logout').onclick = async () => {
  await fetch('/api/logout', { method: 'POST' });
  location.href = '/login';
};

async function open(number) {
  if (dirty && !confirm('Neshranjene spremembe. Nadaljujem?')) return;
  const page = await api('/api/pages/' + number);
  editing = number;
  dirty = false;
  $('source').value = page.source;
  if (previewing) renderPreview();
  $('editing').textContent = page.number + ' · ' + page.file;
  say('Naloženo.');
  renderList();
}

async function save() {
  if (editing == null) return say('Ni izbrane strani.', true);
  try {
    state = await api('/api/pages/' + editing, { method: 'PUT', body: $('source').value });
    dirty = false;
    renderList();
    say('Shranjeno. Zaslon se osveži sam.');
  } catch (e) { say(e.message, true); }
}

$('save').onclick = save;
$('source').oninput = () => { dirty = true; say('Neshranjeno …'); };
document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'p') { e.preventDefault(); setPreview(!previewing); }
});

$('new').onclick = async () => {
  const title = prompt('Naslov nove strani:', 'Nova pesem');
  if (title === null) return;
  const number = prompt('Številka strani (prazno = naslednja prosta):', '');
  if (number === null) return;
  try {
    const body = { title };
    if (number.trim()) body.number = Number(number);
    const created = await api('/api/pages', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    await refresh();
    await open(created.number);
  } catch (e) { say(e.message, true); }
};

$('delete').onclick = async () => {
  if (editing == null) return;
  if (!confirm('Izbrišem stran ' + editing + '?')) return;
  state = await api('/api/pages/' + editing, { method: 'DELETE' });
  editing = null;
  $('source').value = '';
  $('editing').textContent = '—';
  dirty = false;
  renderList();
  say('Izbrisano.');
};

$('show').onclick = async () => {
  if (editing == null) return;
  state = await api('/api/show/' + editing, { method: 'POST' });
  renderList();
};
$('prev').onclick = async () => { state = await api('/api/prev', { method: 'POST' }); renderList(); };
$('next').onclick = async () => { state = await api('/api/next', { method: 'POST' }); renderList(); };

async function putSettings(patch) {
  state = await api('/api/settings', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(patch),
  });
  renderList();
  renderSettings();
}
$('theme').onchange = (e) => putSettings({ theme: e.target.value });
$('font').onchange = (e) => putSettings({ font: e.target.value });
$('baseScale').onchange = (e) => putSettings({ baseScale: Number(e.target.value) });
// Rotation is handed to flutter-pi at startup, so the box restarts the display
// to apply it. The screen goes black for a moment; this page is unaffected.
$('rotation').onchange = (e) => {
  if (!confirm('Zaslon se bo znova zagnal. Nadaljujem?')) {
    e.target.value = String(state.settings.rotation ?? 0);
    return;
  }
  putSettings({ rotation: Number(e.target.value) });
};
$('showTitle').onchange = (e) => putSettings({ showTitle: e.target.checked });

// --- Drag and drop -------------------------------------------------------
// Markdown dropped on the list becomes new pages; images dropped on the
// editor are uploaded and referenced at the cursor. Nothing else is accepted,
// so a stray screenshot on the wrong half is a no-op rather than a surprise.

const isMarkdown = (file) => /\.(md|markdown|txt)$/i.test(file.name);
const isImage = (file) => file.type.startsWith('image/');

async function importMarkdownFiles(files) {
  const wanted = files.filter(isMarkdown);
  if (!wanted.length) return say('Na seznam spusti .md datoteke.', true);
  let last = null;
  for (const file of wanted) {
    try {
      const result = await api('/api/import?name=' + encodeURIComponent(file.name), {
        method: 'POST', body: await file.text(),
      });
      state = result;
      last = result.number;
    } catch (e) { say(file.name + ': ' + e.message, true); }
  }
  renderList();
  if (last !== null) {
    say(wanted.length + ' uvoženih strani.');
    await open(last);
  }
}

// --- Editing tools ---------------------------------------------------------
//
// Enough markdown to write a hymn without knowing any: emphasis, headings, a
// blockquote for the refrain, and a blank line between verses. Written by hand
// rather than with an editor library, because the box is offline and a build
// step for this page is one more thing to be broken on a Sunday morning.

function edit(fn) {
  // A tool used while the preview is up would change text nobody can see.
  if (previewing) setPreview(false);
  const area = $('source');
  const start = area.selectionStart;
  const end = area.selectionEnd;
  fn(area, start, end);
  dirty = true;
  say('Neshranjeno …');
  area.focus();
}

/// Puts `mark` on both sides of the selection, or takes it off again when it is
/// already there, so the same button undoes itself.
function wrap(mark) {
  edit((area, start, end) => {
    const selected = area.value.slice(start, end);
    const before = area.value.slice(0, start);
    const after = area.value.slice(end);
    const already = before.endsWith(mark) && after.startsWith(mark);

    if (already) {
      area.value = before.slice(0, -mark.length) + selected + after.slice(mark.length);
      area.setSelectionRange(start - mark.length, end - mark.length);
    } else {
      area.value = before + mark + selected + mark + after;
      area.setSelectionRange(start + mark.length, end + mark.length);
    }
  });
}

/// Prefixes every line the selection touches, and removes the prefix when all
/// of them already carry it.
function prefixLines(mark) {
  edit((area, start, end) => {
    const from = area.value.lastIndexOf('\n', start - 1) + 1;
    const to = area.value.indexOf('\n', end);
    const stop = to === -1 ? area.value.length : to;
    const lines = area.value.slice(from, stop).split('\n');
    const has = lines.every((line) => line.startsWith(mark));
    const next = lines
      .map((line) => (has ? line.slice(mark.length) : mark + line))
      .join('\n');
    area.value = area.value.slice(0, from) + next + area.value.slice(stop);
    area.setSelectionRange(from, from + next.length);
  });
}

/// A blank line is what separates verses on screen, and the thing operators
/// most often forget.
function verseBreak() {
  edit((area, start) => {
    area.value = area.value.slice(0, start) + '\n\n' + area.value.slice(start);
    area.setSelectionRange(start + 2, start + 2);
  });
}

for (const button of document.querySelectorAll('#tools [data-wrap]')) {
  button.onclick = () => wrap(button.dataset.wrap);
}
for (const button of document.querySelectorAll('#tools [data-line]')) {
  button.onclick = () => prefixLines(button.dataset.line);
}
$('verse').onclick = verseBreak;

// Drag and drop is not obvious, and is awkward from a phone.
$('pickImage').onclick = () => $('imageFile').click();
$('imageFile').onchange = async (e) => {
  await insertImages(Array.from(e.target.files));
  e.target.value = '';
};

$('source').addEventListener('keydown', (e) => {
  if (!(e.metaKey || e.ctrlKey)) return;
  const key = e.key.toLowerCase();
  if (key === 'b') { e.preventDefault(); wrap('**'); }
  if (key === 'i') { e.preventDefault(); wrap('*'); }
});

// --- Preview ---------------------------------------------------------------
//
// A small renderer rather than a markdown library, for the same reason there is
// no build step: the box is offline and this page has to keep working when
// nothing can be fetched. It covers what a songbook page uses and nothing else.
//
// It follows the display, which breaks on single newlines (softLineBreak in
// page_view.dart) because a songbook is written in lines and has to read as
// lines. If that ever changes there, change it here too or the preview lies.

function escapeHtml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/// Emphasis, code and images, applied to already-escaped text. Images are
/// rewritten to the /media route the box serves them from; anything that is not
/// a plain relative file name is left as text rather than turned into a tag.
function inline(text) {
  return text
    .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (whole, alt, src) => {
      const name = src.replace(/^images\//, '');
      if (!/^[A-Za-z0-9._-]+$/.test(name)) return whole;
      return '<img src="/media/' + encodeURIComponent(name) + '" alt="' + alt + '">';
    })
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
}

function renderMarkdown(source) {
  const blocks = escapeHtml(source).split(/\n\s*\n/);
  const html = [];

  for (const raw of blocks) {
    const block = raw.replace(/^\n+|\n+$/g, '');
    if (!block.trim()) continue;
    const lines = block.split('\n');

    const heading = block.match(/^(#{1,3})\s+(.*)$/);
    if (heading && lines.length === 1) {
      const level = heading[1].length;
      html.push('<h' + level + '>' + inline(heading[2]) + '</h' + level + '>');
      continue;
    }

    if (lines.every((line) => /^\s*[-*]\s+/.test(line))) {
      const items = lines.map((line) => '<li>' + inline(line.replace(/^\s*[-*]\s+/, '')) + '</li>');
      html.push('<ul>' + items.join('') + '</ul>');
      continue;
    }

    if (lines.every((line) => /^\s*&gt;\s?/.test(line))) {
      const text = lines.map((line) => line.replace(/^\s*&gt;\s?/, '')).join(' ');
      html.push('<blockquote>' + inline(text) + '</blockquote>');
      continue;
    }

    // Every line breaks, exactly as the display treats them.
    html.push('<p>' + inline(lines.join('<br>')) + '</p>');
  }

  return html.join('\n');
}

let previewing = false;

function renderPreview() {
  const source = $('source').value;
  // The title lives in the front matter and is drawn by the chrome, not by the
  // page body, so the preview shows the body the same way the screen does.
  const body = source.replace(/^---\n[\s\S]*?\n---\n?/, '');
  $('preview').innerHTML = body.trim()
    ? renderMarkdown(body)
    : '<p class="empty">Prazna stran.</p>';
}

function setPreview(on) {
  previewing = on;
  $('preview').hidden = !on;
  $('source').hidden = on;
  $('togglePreview').classList.toggle('on', on);
  if (on) renderPreview();
}

$('togglePreview').onclick = () => setPreview(!previewing);

async function insertImages(files) {
  const wanted = files.filter(isImage);
  if (!wanted.length) return say('V besedilo spusti slikovne datoteke.', true);
  if (editing == null) return say('Najprej izberi stran.', true);
  const area = $('source');
  for (const file of wanted) {
    try {
      const result = await api('/api/images?name=' + encodeURIComponent(file.name), {
        method: 'POST', body: file,
      });
      const at = area.selectionStart ?? area.value.length;
      area.value = area.value.slice(0, at) + '\n' + result.markdown + '\n' + area.value.slice(at);
      dirty = true;
      say('Slika dodana: ' + result.path + ' — ne pozabi shraniti.');
    } catch (e) { say(file.name + ': ' + e.message, true); }
  }
}

// A drop anywhere in the window would otherwise make the browser navigate to
// the file, silently losing unsaved edits.
let dragDepth = 0;
window.addEventListener('dragenter', (e) => {
  if (!e.dataTransfer || !Array.from(e.dataTransfer.types).includes('Files')) return;
  if (++dragDepth === 1) document.body.classList.add('dragging');
});
window.addEventListener('dragleave', () => {
  if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove('dragging'); }
});
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', (e) => {
  e.preventDefault();
  dragDepth = 0;
  document.body.classList.remove('dragging');
});

function dropZone(element, handler) {
  element.addEventListener('dragover', (e) => {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
    element.classList.add('dropping');
  });
  element.addEventListener('dragleave', () => element.classList.remove('dropping'));
  element.addEventListener('drop', (e) => {
    e.preventDefault();
    e.stopPropagation();
    element.classList.remove('dropping');
    document.body.classList.remove('dragging');
    dragDepth = 0;
    handler(Array.from(e.dataTransfer ? e.dataTransfer.files : []));
  });
}

dropZone($('list'), importMarkdownFiles);
dropZone($('editor'), (files) =>
  files.some(isMarkdown) && !files.some(isImage)
    ? importMarkdownFiles(files)
    : insertImages(files));

refresh().catch((e) => say(e.message, true));
setInterval(() => { if (!dirty) refresh().catch(() => {}); }, 4000);
