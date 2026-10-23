// Canonical bounded MP4 metadata reader. It never decodes media and never
// allocates based on untrusted box sizes; it only walks the ISO BMFF boxes
// needed to enforce the Dream Skin dynamic background contract.

export const MAX_VIDEO_BYTES = 16 * 1024 * 1024;
export const MAX_VIDEO_WIDTH = 1920;
export const MAX_VIDEO_HEIGHT = 1080;
export const MAX_VIDEO_PIXELS = 1920 * 1080;
export const MIN_VIDEO_DURATION_MS = 2000;
export const MAX_VIDEO_DURATION_MS = 20000;
export const MIN_VIDEO_ASPECT = 1.2;
export const MAX_VIDEO_ASPECT = 2.4;

const MAX_BOX_COUNT = 4096;
const MAX_BOX_DEPTH = 8;
const MAX_MOOV_BYTES = 2 * 1024 * 1024;
const TOP_LEVEL_BRANDS = new Set(["isom", "mp42", "M4V "]);
const ALLOWED_PROFILES = new Set([66, 77, 100]);

export class Mp4ValidationError extends Error {
  constructor(code, message) {
    super(message || code);
    this.name = "Mp4ValidationError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new Mp4ValidationError(code, message);
}

function u16(bytes, offset) {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function u32(bytes, offset) {
  return (
    bytes[offset] * 0x1000000 +
    (bytes[offset + 1] << 16) +
    (bytes[offset + 2] << 8) +
    bytes[offset + 3]
  ) >>> 0;
}

function u64(bytes, offset) {
  const value =
    BigInt(u32(bytes, offset)) * 0x100000000n +
    BigInt(u32(bytes, offset + 4));
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) fail("video.parse", "box size exceeds the safe integer range");
  return Number(value);
}

function fourcc(bytes, offset) {
  return String.fromCharCode(
    bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
  );
}

function readBoxHeader(bytes, offset, end, counts) {
  if (offset + 8 > end) fail("video.parse", "truncated box header");
  counts.boxes += 1;
  if (counts.boxes > MAX_BOX_COUNT) fail("video.parse", "too many MP4 boxes");

  const declaredSize = u32(bytes, offset);
  const type = fourcc(bytes, offset + 4);
  let headerSize = 8;
  let size = declaredSize;
  if (declaredSize === 1) {
    if (offset + 16 > end) fail("video.parse", "truncated 64-bit box header");
    size = u64(bytes, offset + 8);
    headerSize = 16;
  } else if (declaredSize === 0) {
    size = end - offset;
  }

  if (size < headerSize || offset + size > end) fail("video.parse", "box size exceeds its parent");
  return { offset, size, headerSize, type, end: offset + size };
}

function children(bytes, parent, depth, counts) {
  if (depth > MAX_BOX_DEPTH) fail("video.parse", "MP4 box nesting is too deep");
  const result = [];
  let offset = parent.offset + parent.headerSize;
  while (offset < parent.end) {
    const child = readBoxHeader(bytes, offset, parent.end, counts);
    result.push(child);
    offset = child.end;
  }
  if (offset !== parent.end) fail("video.parse", "MP4 box payload is not aligned");
  return result;
}

function findChild(bytes, parent, type, depth, counts) {
  return children(bytes, parent, depth, counts).find((child) => child.type === type) ?? null;
}

function parseFtyp(bytes, box) {
  if (box.size < 16) fail("video.ftyp", "ftyp box is too small");
  const major = fourcc(bytes, box.offset + 8);
  if (!TOP_LEVEL_BRANDS.has(major)) fail("video.ftyp", "unsupported MP4 major brand");
  return major;
}

function parseMvhd(bytes, box) {
  if (box.size < 32) fail("video.moov", "mvhd box is too small");
  const version = bytes[box.offset + 8];
  let timescale;
  let duration;
  if (version === 1) {
    if (box.size < 44) fail("video.moov", "mvhd v1 box is too small");
    timescale = u32(bytes, box.offset + 28);
    duration = u64(bytes, box.offset + 32);
  } else if (version === 0) {
    timescale = u32(bytes, box.offset + 20);
    duration = u32(bytes, box.offset + 24);
  } else {
    fail("video.moov", "unsupported mvhd version");
  }
  if (timescale < 1) fail("video.moov", "mvhd timescale is zero");
  if (duration < 1 || duration === 0xffffffff) fail("video.duration", "mvhd duration is missing");
  return { durationMs: Math.round((duration / timescale) * 1000) };
}

function parseTkhd(bytes, box) {
  if (box.size < 92) fail("video.dimensions", "tkhd box is too small");
  const version = bytes[box.offset + 8];
  const widthOffset = version === 1 ? 96 : 84;
  if (box.size < widthOffset + 8) fail("video.dimensions", "tkhd dimensions are missing");
  return {
    width: u32(bytes, box.offset + widthOffset) / 65536,
    height: u32(bytes, box.offset + widthOffset + 4) / 65536,
  };
}

function parseHdlr(bytes, box) {
  if (box.size < 24) fail("video.track_count", "hdlr box is too small");
  return fourcc(bytes, box.offset + 16);
}

function parseStsdEntry(bytes, box, counts) {
  if (box.size < 24) fail("video.codec", "stsd box is too small");
  const entryCount = u32(bytes, box.offset + 12);
  if (entryCount !== 1) fail("video.codec", "stsd must contain exactly one sample entry");
  const entry = readBoxHeader(bytes, box.offset + 16, box.end, counts);
  if (entry.type === "encv") fail("video.encrypted", "encrypted video sample entry");
  if (entry.type !== "avc1") fail("video.codec", "only avc1 sample entries are supported");
  if (entry.size < 94) fail("video.codec", "avc1 sample entry is too small");

  const width = u16(bytes, entry.offset + 32);
  const height = u16(bytes, entry.offset + 34);
  let offset = entry.offset + 86;
  let profile = null;
  while (offset < entry.end) {
    const child = readBoxHeader(bytes, offset, entry.end, counts);
    if (child.type === "avcC") {
      if (child.size < 12) fail("video.profile", "avcC box is too small");
      profile = bytes[child.offset + 9];
      break;
    }
    offset = child.end;
  }
  if (profile === null) fail("video.codec", "avcC configuration is missing");
  if (!ALLOWED_PROFILES.has(profile)) fail("video.profile", "only 8-bit Baseline, Main and High profiles are supported");
  return { width, height, profile };
}

function parseTrack(bytes, trak, counts) {
  const trackChildren = children(bytes, trak, 2, counts);
  const tkhdBox = trackChildren.find((child) => child.type === "tkhd");
  const mdiaBox = trackChildren.find((child) => child.type === "mdia");
  if (!tkhdBox || !mdiaBox) fail("video.parse", "trak is missing tkhd or mdia");
  const tkhd = parseTkhd(bytes, tkhdBox);

  const mdiaChildren = children(bytes, mdiaBox, 3, counts);
  const hdlrBox = mdiaChildren.find((child) => child.type === "hdlr");
  const minfBox = mdiaChildren.find((child) => child.type === "minf");
  if (!hdlrBox || !minfBox) fail("video.parse", "mdia is missing hdlr or minf");
  const handler = parseHdlr(bytes, hdlrBox);
  if (handler === "soun") fail("video.audio_track", "audio tracks are not supported");
  if (handler !== "vide") fail("video.extra_track", "only one video track is supported");

  const minfChildren = children(bytes, minfBox, 4, counts);
  const stblBox = minfChildren.find((child) => child.type === "stbl");
  if (!stblBox) fail("video.parse", "minf is missing stbl");
  const stblChildren = children(bytes, stblBox, 5, counts);
  const stsdBox = stblChildren.find((child) => child.type === "stsd");
  if (!stsdBox) fail("video.codec", "stbl is missing stsd");

  const sample = parseStsdEntry(bytes, stsdBox, counts);
  const tkhdWidth = Math.round(tkhd.width);
  const tkhdHeight = Math.round(tkhd.height);
  if (tkhdWidth < 1 || tkhdHeight < 1 || sample.width < 1 || sample.height < 1) {
    fail("video.dimensions", "video dimensions are missing");
  }
  if (Math.abs(tkhdWidth - sample.width) > 1 || Math.abs(tkhdHeight - sample.height) > 1) {
    fail("video.dimensions", "tkhd and sample dimensions disagree");
  }
  return {
    width: tkhdWidth,
    height: tkhdHeight,
    profile: sample.profile,
  };
}

function hasLocationMetadata(bytes, moov, counts) {
  for (const child of children(bytes, moov, 1, counts)) {
    if (child.type !== "udta") continue;
    for (const entry of children(bytes, child, 2, counts)) {
      if (entry.type === "\xa9xyz" || entry.type === "\xa9loc") return true;
    }
  }
  return false;
}

export function readMp4Metadata(bytes) {
  if (!(bytes instanceof Uint8Array)) fail("video.parse", "video bytes must be a Uint8Array");
  if (bytes.length < 1 || bytes.length > MAX_VIDEO_BYTES) {
    fail("video.size", `video must be between 1 byte and ${MAX_VIDEO_BYTES} bytes`);
  }
  if (bytes.length < 16) fail("video.ftyp", "MP4 is too small to contain an ftyp box");

  const counts = { boxes: 0 };
  const root = { offset: 0, size: bytes.length, headerSize: 0, end: bytes.length };
  const topLevel = children(bytes, root, 0, counts);
  if (!topLevel.length || topLevel[0].type !== "ftyp") fail("video.ftyp", "MP4 must start with ftyp");
  const brand = parseFtyp(bytes, topLevel[0]);

  if (topLevel.some((box) => box.type === "moof" || box.type === "mfra")) {
    fail("video.fragmented", "fragmented MP4 is not supported");
  }
  const moov = topLevel.find((box) => box.type === "moov");
  const mdat = topLevel.find((box) => box.type === "mdat");
  if (!moov || !mdat) fail("video.moov", "MP4 must contain moov and mdat");
  // The whole clip is delivered as a Blob, so faststart is not required for
  // playback. Bound the metadata box itself instead of its absolute offset.
  if (moov.size > MAX_MOOV_BYTES) {
    fail("video.moov", "moov must be no larger than 2 MiB");
  }

  const moovChildren = children(bytes, moov, 1, counts);
  const mvhdBox = moovChildren.find((box) => box.type === "mvhd");
  if (!mvhdBox) fail("video.moov", "moov is missing mvhd");
  const { durationMs } = parseMvhd(bytes, mvhdBox);
  if (durationMs < MIN_VIDEO_DURATION_MS || durationMs > MAX_VIDEO_DURATION_MS) {
    fail("video.duration", "video duration must be between 2 and 20 seconds");
  }

  if (hasLocationMetadata(bytes, moov, counts)) {
    fail("video.metadata_location", "GPS metadata is not allowed");
  }

  const tracks = moovChildren.filter((box) => box.type === "trak");
  if (tracks.length === 0) fail("video.track_count", "MP4 must contain one video track");
  const parsedTracks = tracks.map((trak) => parseTrack(bytes, trak, counts));
  if (parsedTracks.length !== 1) fail("video.track_count", "MP4 must contain exactly one video track");
  const track = parsedTracks[0];

  if (track.width < 640 || track.width > MAX_VIDEO_WIDTH ||
      track.height < 360 || track.height > MAX_VIDEO_HEIGHT ||
      track.width * track.height > MAX_VIDEO_PIXELS) {
    fail("video.dimensions", "video must be within 640x360 and 1920x1080");
  }
  const aspect = track.width / track.height;
  if (!Number.isFinite(aspect) || aspect < MIN_VIDEO_ASPECT || aspect > MAX_VIDEO_ASPECT) {
    fail("video.aspect", "video aspect ratio must be between 1.2 and 2.4");
  }

  return {
    width: track.width,
    height: track.height,
    durationMs,
    codec: "avc1",
    profile: track.profile,
    tracks: 1,
    brand,
  };
}

