/// Turning what somebody drops on the editor into what the screen can show.
///
/// The conversion happens here, in the browser, and not on the box. The phone
/// or laptop doing the uploading has orders of magnitude more to spend on it
/// than a Zero 2 W, the box is often its own access point with no uplink to
/// fetch a tool from, and every byte of a decoder we did not install is a byte
/// of card we did not spend. It also means a picture reaches the card already
/// the size the panel wants, so the display is not re-decoding twelve
/// megapixels every time somebody turns to that page.

/// The longest edge a page image needs. A 4K panel is 3840 across, and an
/// image page is drawn `contain`ed, so nothing above this can ever be seen --
/// it is only decode time on the box and space on the card.
const MAX_EDGE = 3840;

/// JPEG quality for photographs. Above this the file grows faster than the
/// picture improves, and the card is the scarce thing.
const JPEG_QUALITY = 0.85;

/// What the box plays, kept in step with SongPage.videoExtensions.
const VIDEO_NAME = /\.(m4v|mov|mp4)$/i;

export const isVideoFile = (file) =>
  file.type.startsWith('video/') || VIDEO_NAME.test(file.name);

export const isImageFile = (file) =>
  file.type.startsWith('image/') && !isVideoFile(file);

/// PNG keeps its format, everything else becomes JPEG. A PNG is the one thing
/// somebody is likely to have picked *because* it has transparency, and
/// flattening it onto a canvas would fill that with black on a light page.
const targetType = (file) =>
  /^image\/png$/i.test(file.type) ? 'image/png' : 'image/jpeg';

const renamed = (name, type) =>
  name.replace(/\.[^.]*$/, '') + (type === 'image/png' ? '.png' : '.jpg');

/// Decode with the browser, scale if it is bigger than the panel can show, and
/// re-encode. The decode is what makes this worth doing at all: it takes
/// whatever the browser can read -- HEIC off an iPhone, AVIF, WebP, a TIFF --
/// and hands the box a format it certainly has a decoder for.
export async function convertImage(file) {
  const type = targetType(file);
  const bitmap = await createImageBitmap(file);
  try {
    const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));

    // OffscreenCanvas where there is one, a plain canvas where there is not:
    // Safari only grew it in 16.4, and the phone in somebody's pocket is
    // exactly the machine this has to work on.
    const blob = await encode(bitmap, width, height, type);

    // Re-encoding is not always a saving: a small PNG of flat colour can come
    // out bigger than it went in. Keep whichever is smaller, as long as the
    // original was a format the box can read and did not need scaling.
    if (scale === 1 && blob.size >= file.size && /^image\/(png|jpeg)$/i.test(file.type)) {
      return { blob: file, name: file.name, converted: false };
    }
    return { blob, name: renamed(file.name, type), converted: true };
  } finally {
    bitmap.close();
  }
}

function encode(bitmap, width, height, type) {
  if (typeof OffscreenCanvas !== 'undefined') {
    const canvas = new OffscreenCanvas(width, height);
    canvas.getContext('2d').drawImage(bitmap, 0, 0, width, height);
    return canvas.convertToBlob({ type, quality: JPEG_QUALITY });
  }
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  canvas.getContext('2d').drawImage(bitmap, 0, 0, width, height);
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error('Pretvorba slike ni uspela.'))),
      type,
      JPEG_QUALITY,
    );
  });
}

/// The four-character code of the first video sample entry in an MP4, which is
/// how the file says which codec it carries: avc1 or avc3 for H.264, hvc1 or
/// hev1 for H.265, av01, vp09.
///
/// Read by walking the box tree rather than by scanning for the string,
/// because 'hvc1' appears in the compatible-brands list of plenty of files
/// that are not H.265 at all, and refusing one of those would be worse than
/// the problem this solves.
async function sampleFormat(file) {
  // Only moov is read. It sits at the front of a file written for streaming
  // and at the back otherwise, so the top level is walked by its headers --
  // sixteen bytes at a time -- and nothing but that one box is ever pulled
  // into memory. A clip off a phone can be half a gigabyte, and reading it
  // whole to learn four characters is how a browser tab dies.
  const header = async (at) => {
    const head = new DataView(await file.slice(at, at + 16).arrayBuffer());
    if (head.byteLength < 8) return null;
    let size = head.getUint32(0);
    let length = 8;
    if (size === 1) {
      if (head.byteLength < 16) return null;
      size = Number(head.getBigUint64(8));
      length = 16;
    } else if (size === 0) {
      size = file.size - at;
    }
    const type = String.fromCharCode(head.getUint8(4), head.getUint8(5), head.getUint8(6), head.getUint8(7));
    return size >= length ? { size, type, length } : null;
  };

  let at = 0;
  while (at < file.size) {
    const box = await header(at);
    if (box === null) return null;
    if (box.type === 'moov') {
      const moov = new DataView(await file.slice(at + box.length, at + box.size).arrayBuffer());
      return findSampleFormat(moov, 0, moov.byteLength);
    }
    at += box.size;
  }
  return null;
}

/// Walks moov's children down to stsd, whose first sample entry names the
/// codec. By the box tree rather than by scanning for the string: 'hvc1'
/// appears in the compatible-brands list of plenty of files that are not
/// H.265 at all, and refusing one of those would be worse than the problem
/// this solves.
function findSampleFormat(view, start, end) {
  const fourcc = (at) =>
    String.fromCharCode(view.getUint8(at), view.getUint8(at + 1), view.getUint8(at + 2), view.getUint8(at + 3));

  // The boxes on the way down. Everything else is skipped whole.
  const containers = new Set(['trak', 'mdia', 'minf', 'stbl']);

  let at = start;
  while (at + 8 <= end) {
    let size = view.getUint32(at);
    const type = fourcc(at + 4);
    let length = 8;
    if (size === 1) {
      size = Number(view.getBigUint64(at + 8));
      length = 16;
    } else if (size === 0) {
      size = end - at;
    }
    if (size < length || at + size > end) return null;

    if (type === 'stsd') {
      // version and flags, then the entry count, then the first sample entry:
      // its own size, then the four characters that are the answer.
      return fourcc(at + length + 4 + 4 + 4);
    }
    if (containers.has(type)) {
      const found = findSampleFormat(view, at + length, at + size);
      if (found) return found;
    }
    at += size;
  }
  return null;
}

const H264 = new Set(['avc1', 'avc3']);

/// What to do with a video somebody dropped: send it as it is, or say why not.
///
/// Nothing is transcoded. WebCodecs can decode H.265 where the browser has a
/// decoder, but writing the result back out as an MP4 needs a muxer, which is
/// a library this repo would have to vendor and a page that would sit grinding
/// for minutes on a phone. Telling somebody the one ffmpeg line that fixes it
/// is smaller, faster and does not lie about how long it will take.
export async function inspectVideo(file) {
  if (!VIDEO_NAME.test(file.name)) {
    return { ok: false, why: 'Zaslon predvaja le .mp4, .m4v in .mov.' };
  }
  let format = null;
  try {
    format = await sampleFormat(file);
  } catch (e) {
    // An unreadable box tree is not proof of anything; let the box try.
    return { ok: true, format: null };
  }
  if (format && !H264.has(format)) {
    return {
      ok: false,
      why:
        'Zaslon predvaja le H.264, ta posnetek je ' + format + '. Pretvori ga: ' +
        'ffmpeg -i vhod -c:v libx264 -profile:v high -pix_fmt yuv420p izhod.mp4',
    };
  }
  return { ok: true, format };
}
