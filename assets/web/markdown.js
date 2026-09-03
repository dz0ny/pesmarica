// The preview renderer.
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

/// The containers the box can play, kept in step with SongPage.videoExtensions.
const VIDEO = /\.(m4v|mov|mp4)$/i;

/// Emphasis, code and images, applied to already-escaped text. Images are
/// rewritten to the /media route the box serves them from; anything that is not
/// a plain relative file name is left as text rather than turned into a tag.
///
/// Video is written as an image and comes out as a <video>: muted and looping,
/// as the display plays it, so the editor shows what the screen will do. It is
/// not autoplayed here -- an editor that starts playing at you while you type
/// is its own kind of wrong, and the screen is where it matters.
function inline(text) {
  return text
    .replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (whole, alt, src) => {
      const name = src.replace(/^images\//, '');
      if (!/^[A-Za-z0-9._-]+$/.test(name)) return whole;
      const url = '/media/' + encodeURIComponent(name);
      if (VIDEO.test(name)) {
        return '<video src="' + url + '" controls muted loop playsinline></video>';
      }
      return '<img src="' + url + '" alt="' + alt + '">';
    })
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
}

export function renderMarkdown(source) {
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

/// The body as the screen lays it out: the title lives in the front matter and
/// is drawn by the chrome, not by the page body.
export function previewHtml(source) {
  const body = source.replace(/^---\n[\s\S]*?\n---\n?/, '');
  return body.trim() ? renderMarkdown(body) : '<p class="none">Prazna stran.</p>';
}
