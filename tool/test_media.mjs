// The MP4 codec sniff in assets/web/media.js, against box trees built here.
//
// It is the one piece of that module with somewhere to hide: canvas encoding
// either works or is visibly wrong, but a parser walking a box tree by
// four-character codes can be subtly wrong on somebody's phone and nowhere
// else. The decoy case is the point -- 'hvc1' is a compatible brand on plenty
// of H.264 files, so a sniff that scanned for the string would refuse them.
//
//   node tool/test_media.mjs
//
import { inspectVideo } from '../assets/web/media.js';

const fourcc = (s) => Buffer.from(s, 'latin1');
function box(type, ...payload) {
  const body = Buffer.concat(payload.map(Buffer.from));
  const head = Buffer.alloc(8);
  head.writeUInt32BE(8 + body.length, 0);
  fourcc(type).copy(head, 4);
  return Buffer.concat([head, body]);
}
function bigBox(type, ...payload) {           // 64-bit size form
  const body = Buffer.concat(payload.map(Buffer.from));
  const head = Buffer.alloc(16);
  head.writeUInt32BE(1, 0);
  fourcc(type).copy(head, 4);
  head.writeBigUInt64BE(BigInt(16 + body.length), 8);
  return Buffer.concat([head, body]);
}
const stsd = (codec) => box('stsd',
  Buffer.alloc(4),                 // version + flags
  Buffer.from([0,0,0,1]),          // entry count
  box(codec, Buffer.alloc(70)));   // the sample entry
const movie = (codec, mk = box) => Buffer.concat([
  box('ftyp', fourcc('isom'), Buffer.alloc(4), fourcc('hvc1')),  // decoy brand
  box('free', Buffer.alloc(32)),
  mk('moov', box('trak', box('mdia', box('minf', box('stbl', stsd(codec)))))),
  box('mdat', Buffer.alloc(1024)),
]);

const asFile = (buf, name) => new File([buf], name, { type: 'video/mp4' });

let fails = 0;
const check = async (label, file, want) => {
  const got = await inspectVideo(file);
  const ok = got.ok === want.ok && (want.format === undefined || got.format === want.format);
  if (!ok) { fails++; console.log('FAIL', label, JSON.stringify(got)); }
  else console.log('  ok  ', label);
};

await check('H.264 passes despite an hvc1 brand', asFile(movie('avc1'), 'a.mp4'), { ok: true, format: 'avc1' });
await check('avc3 passes too', asFile(movie('avc3'), 'a.mp4'), { ok: true, format: 'avc3' });
await check('H.265 is refused', asFile(movie('hvc1'), 'a.mp4'), { ok: false });
await check('AV1 is refused', asFile(movie('av01'), 'a.mp4'), { ok: false });
await check('a 64-bit moov still parses', asFile(movie('avc1', bigBox), 'a.mp4'), { ok: true, format: 'avc1' });
await check('.webm is refused on the name alone', asFile(movie('avc1'), 'a.webm'), { ok: false });
await check('garbage is let through rather than guessed at', asFile(Buffer.alloc(64), 'a.mp4'), { ok: true });
console.log(fails ? `\n${fails} FAILED` : '\nall passed');
