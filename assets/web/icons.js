/// Lucide icons, copied in as paths.
///
/// Copied rather than fetched or packaged: the box is often its own access
/// point with no uplink, and the pages here have no build step to run an icon
/// font or a sprite sheet through. One function per icon, the path data
/// verbatim from lucide-icons/lucide, so upgrading one is a copy and not a
/// merge.
///
/// The shared attributes are lucide's own defaults. `currentColor` is what
/// makes an icon obey the skin like any other text: never put a literal colour
/// in here.
import { html } from '/static/preact.js';

const icon = (size, label, children) => html`
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width=${size}
    height=${size}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="2"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden=${label ? 'false' : 'true'}
    role=${label ? 'img' : 'presentation'}
    focusable="false"
  >
    ${label && html`<title>${label}</title>`}
    ${children}
  </svg>
`;

/// lucide: square-pen
export const SquarePen = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
    <path d="M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z" />
  `);

/// lucide: settings
export const Settings = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915" />
    <circle cx="12" cy="12" r="3" />
  `);
