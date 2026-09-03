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

/// lucide: bold
export const Bold = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M6 12h9a4 4 0 0 1 0 8H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h7a4 4 0 0 1 0 8" />
  `);

/// lucide: chevron-left
export const ChevronLeft = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="m15 18-6-6 6-6" />
  `);

/// lucide: chevron-right
export const ChevronRight = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="m9 18 6-6-6-6" />
  `);

/// lucide: delete
export const Delete = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M10 5a2 2 0 0 0-1.344.519l-6.328 5.74a1 1 0 0 0 0 1.481l6.328 5.741A2 2 0 0 0 10 19h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2z" />
    <path d="m12 9 6 6" />
    <path d="m18 9-6 6" />
  `);

/// lucide: eye
export const Eye = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0" />
    <circle cx="12" cy="12" r="3" />
  `);

/// lucide: file-plus
export const FilePlus = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z" />
    <path d="M14 2v5a1 1 0 0 0 1 1h5" />
    <path d="M9 15h6" />
    <path d="M12 18v-6" />
  `);

/// lucide: hash
export const Hash = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <line x1="4" x2="20" y1="9" y2="9" />
    <line x1="4" x2="20" y1="15" y2="15" />
    <line x1="10" x2="8" y1="3" y2="21" />
    <line x1="16" x2="14" y1="3" y2="21" />
  `);

/// lucide: heading-1
export const Heading1 = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M4 12h8" />
    <path d="M4 18V6" />
    <path d="M12 18V6" />
    <path d="m17 12 3-2v8" />
  `);

/// lucide: heading-2
export const Heading2 = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M4 12h8" />
    <path d="M4 18V6" />
    <path d="M12 18V6" />
    <path d="M21 18h-4c0-4 4-3 4-6 0-1.5-2-2.5-4-1" />
  `);

/// lucide: image
export const Image = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <rect width="18" height="18" x="3" y="3" rx="2" ry="2" />
    <circle cx="9" cy="9" r="2" />
    <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" />
  `);

/// lucide: italic
export const Italic = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <line x1="19" x2="10" y1="4" y2="4" />
    <line x1="14" x2="5" y1="20" y2="20" />
    <line x1="15" x2="9" y1="4" y2="20" />
  `);

/// lucide: list
export const List = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M3 5h.01" />
    <path d="M3 12h.01" />
    <path d="M3 19h.01" />
    <path d="M8 5h13" />
    <path d="M8 12h13" />
    <path d="M8 19h13" />
  `);

/// lucide: lock
export const Lock = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <rect width="18" height="11" x="3" y="11" rx="2" ry="2" />
    <path d="M7 11V7a5 5 0 0 1 10 0v4" />
  `);

/// lucide: minus
export const Minus = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M5 12h14" />
  `);

/// lucide: monitor-play
export const MonitorPlay = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M15.033 9.44a.647.647 0 0 1 0 1.12l-4.065 2.352a.645.645 0 0 1-.968-.56V7.648a.645.645 0 0 1 .967-.56z" />
    <path d="M12 17v4" />
    <path d="M8 21h8" />
    <rect x="2" y="3" width="20" height="14" rx="2" />
  `);

/// lucide: moon
export const Moon = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401" />
  `);

/// lucide: pilcrow
export const Pilcrow = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M13 4v16" />
    <path d="M17 4v16" />
    <path d="M19 4H9.5a4.5 4.5 0 0 0 0 9H13" />
  `);

/// lucide: plus
export const Plus = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M5 12h14" />
    <path d="M12 5v14" />
  `);

/// lucide: quote
export const Quote = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M16 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z" />
    <path d="M5 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z" />
  `);

/// lucide: save
export const Save = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" />
    <path d="M17 21v-7a1 1 0 0 0-1-1H8a1 1 0 0 0-1 1v7" />
    <path d="M7 3v4a1 1 0 0 0 1 1h7" />
  `);

/// lucide: search
export const Search = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="m21 21-4.34-4.34" />
    <circle cx="11" cy="11" r="8" />
  `);

/// lucide: settings
export const Settings = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915" />
    <circle cx="12" cy="12" r="3" />
  `);

/// lucide: sliders-horizontal
export const Sliders = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M10 5H3" />
    <path d="M12 19H3" />
    <path d="M14 3v4" />
    <path d="M16 17v4" />
    <path d="M21 12h-9" />
    <path d="M21 19h-5" />
    <path d="M21 5h-7" />
    <path d="M8 10v4" />
    <path d="M8 12H3" />
  `);

/// lucide: smartphone
export const Smartphone = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <rect width="14" height="20" x="5" y="2" rx="2" ry="2" />
    <path d="M12 18h.01" />
  `);

/// lucide: square-pen
export const SquarePen = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
    <path d="M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z" />
  `);

/// lucide: sun
export const Sun = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2" />
    <path d="M12 20v2" />
    <path d="m4.93 4.93 1.41 1.41" />
    <path d="m17.66 17.66 1.41 1.41" />
    <path d="M2 12h2" />
    <path d="M20 12h2" />
    <path d="m6.34 17.66-1.41 1.41" />
    <path d="m19.07 4.93-1.41 1.41" />
  `);

/// lucide: trash-2
export const Trash = ({ size = 20, label = null }) =>
  icon(size, label, html`
    <path d="M10 11v6" />
    <path d="M14 11v6" />
    <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
    <path d="M3 6h18" />
    <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
  `);
