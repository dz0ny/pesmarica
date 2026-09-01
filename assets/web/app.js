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
