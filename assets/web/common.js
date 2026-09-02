// Talking to the box. Shared by the remote and the management page.

/// Errors arrive either as a JSON {error} or as plain text; the operator should
/// see the sentence either way, never the envelope around it.
async function readError(response) {
  const text = (await response.text()).trim();
  try {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed.error === 'string') return parsed.error;
  } catch (_) { /* plain text */ }
  return text || response.statusText;
}

/// A 401 means this call needed the password and did not have it. The remote
/// never makes such a call, so only the management page can land here, and the
/// honest answer is to send it back to the unlock screen.
export function api(path, options = {}) {
  return fetch(path, options).then(async (r) => {
    if (r.status === 401) {
      location.href = '/login?next=' + encodeURIComponent(location.pathname);
      throw new Error('Geslo je poteklo.');
    }
    if (!r.ok) throw new Error(await readError(r));
    return r.status === 204 ? null : r.json();
  });
}

export function json(path, method, body) {
  return api(path, {
    method,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

// --- Skin ----------------------------------------------------------------
//
// Dark for a hall with the lights down, light for the same hall at nine in the
// morning. The first answer comes from the phone's own setting; after that the
// operator's choice sticks to the device. The attribute is set by an inline
// script in each page so the stylesheet never paints the wrong skin first.

const SKIN = 'pesmarica-skin';

export const skin = () => document.documentElement.dataset.skin === 'light' ? 'light' : 'dark';

export function applySkin(name) {
  document.documentElement.dataset.skin = name;
  const meta = document.querySelector('meta[name=theme-color]');
  if (meta) meta.content = name === 'light' ? '#fbf8f1' : '#1e1a15';
  return name;
}

export function flipSkin() {
  const next = skin() === 'light' ? 'dark' : 'light';
  try { localStorage.setItem(SKIN, next); } catch (_) { /* private mode */ }
  return applySkin(next);
}

applySkin(skin());
