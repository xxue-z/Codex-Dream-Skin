import assert from "node:assert/strict";
import test from "node:test";

import {
  MAX_VIDEO_BYTES,
  Mp4ValidationError,
  readMp4Metadata,
} from "../runtime/mp4-metadata.mjs";

const u32 = (value) => {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value >>> 0);
  return bytes;
};
const u16 = (value) => {
  const bytes = Buffer.alloc(2);
  bytes.writeUInt16BE(value);
  return bytes;
};
const fourcc = (value) => Buffer.from(value, "latin1");

function box(type, ...parts) {
  const payload = Buffer.concat(parts);
  return Buffer.concat([u32(8 + payload.length), fourcc(type), payload]);
}

function fullBox(type, version, flags, ...parts) {
  const head = Buffer.alloc(4);
  head[0] = version;
  head.writeUIntBE(flags, 1, 3);
  return box(type, head, ...parts);
}

function ftyp(brand = "isom") {
  return box("ftyp", fourcc(brand), u32(0), fourcc("isomiso2avc1mp41"));
}

function mvhd(timescale, duration) {
  const payload = Buffer.alloc(96);
  payload.writeUInt32BE(timescale, 8);
  payload.writeUInt32BE(duration, 12);
  payload.writeUInt32BE(0x00010000, 20);
  return fullBox("mvhd", 0, 0, payload);
}

function tkhd(width, height) {
  const payload = Buffer.alloc(80);
  payload.writeUInt32BE(0x00010000, 36);
  payload.writeUInt32BE(Math.round(width * 65536), 72);
  payload.writeUInt32BE(Math.round(height * 65536), 76);
  return fullBox("tkhd", 0, 3, payload);
}

function hdlr(handler) {
  const payload = Buffer.alloc(20);
  payload.write(handler, 4, 4, "latin1");
  payload.write("fixture\0", 12, "latin1");
  return fullBox("hdlr", 0, 0, payload);
}

function avc1(width, height, profile, type = "avc1") {
  const visual = Buffer.alloc(78);
  visual.writeUInt16BE(width, 24);
  visual.writeUInt16BE(height, 26);
  visual.writeUInt16BE(1, 40);
  visual.writeUInt16BE(0x18, 74);
  const avcC = box("avcC", Buffer.from([1, profile, 0, 0x1f, 0xff, 0xe1, 0, 0]));
  return box(type, visual, avcC);
}

function stsd(entry) {
  return fullBox("stsd", 0, 0, u32(1), entry);
}

function trak({ width = 1920, height = 1080, handler = "vide", entry = avc1(width, height, 100) } = {}) {
  const stbl = box("stbl", stsd(entry));
  const minf = box("minf", stbl);
  const mdia = box("mdia", hdlr(handler), minf);
  return box("trak", tkhd(width, height), mdia);
}

function makeMp4({
  width = 1920,
  height = 1080,
  seconds = 5,
  brand = "isom",
  tracks = null,
  order = "normal",
  fragmented = false,
  gps = false,
  filler = 0,
} = {}) {
  const trackList = tracks ?? [{ width, height }];
  const traks = trackList.map((track) => trak({ width, height, ...track }));
  const udta = gps
    ? box("udta", box("\xA9xyz", Buffer.from("+31.0000-122.0000/")))
    : Buffer.alloc(0);
  const moov = box("moov", mvhd(1000, Math.round(seconds * 1000)), ...traks, udta);
  const mdat = box("mdat", Buffer.alloc(32 + filler, 0x11));
  const parts = order === "mdat-first"
    ? [ftyp(brand), mdat, moov]
    : [ftyp(brand), moov, mdat];
  if (fragmented) parts.push(box("moof", Buffer.alloc(0)));
  return Buffer.concat(parts);
}

function expectCode(bytes, code) {
  assert.throws(
    () => readMp4Metadata(bytes),
    (error) => error instanceof Mp4ValidationError && error.code === code,
  );
}

test("accepts a minimal H.264 MP4", () => {
  const metadata = readMp4Metadata(makeMp4());
  assert.equal(metadata.width, 1920);
  assert.equal(metadata.height, 1080);
  assert.equal(metadata.durationMs, 5000);
  assert.equal(metadata.codec, "avc1");
  assert.equal(metadata.profile, 100);
  assert.equal(metadata.brand, "isom");
});

test("rejects QuickTime, non-MP4 and fragmented containers", () => {
  expectCode(makeMp4({ brand: "qt  " }), "video.ftyp");
  expectCode(Buffer.from("not an mp4"), "video.ftyp");
  expectCode(makeMp4({ fragmented: true }), "video.fragmented");
  const mdatFirst = readMp4Metadata(makeMp4({ order: "mdat-first" }));
  assert.equal(mdatFirst.width, 1920);
});

test("rejects audio, extra video and additional non-video tracks", () => {
  expectCode(makeMp4({ tracks: [{ handler: "soun" }] }), "video.audio_track");
  expectCode(makeMp4({ tracks: [{}, {}] }), "video.track_count");
  expectCode(makeMp4({ tracks: [{}, { handler: "soun" }] }), "video.audio_track");
  expectCode(makeMp4({ tracks: [{ handler: "subtit" }] }), "video.extra_track");
});

test("rejects unsupported codecs, profiles and encrypted entries", () => {
  expectCode(makeMp4({ tracks: [{ entry: avc1(1920, 1080, 100, "hev1") }] }), "video.codec");
  expectCode(makeMp4({ tracks: [{ entry: avc1(1920, 1080, 110) }] }), "video.profile");
  expectCode(makeMp4({ tracks: [{ entry: avc1(1920, 1080, 100, "encv") }] }), "video.encrypted");
});

test("rejects dimensions, aspect ratio and duration outside the contract", () => {
  expectCode(makeMp4({ width: 1921 }), "video.dimensions");
  expectCode(makeMp4({ width: 3840, height: 2160 }), "video.dimensions");
  expectCode(makeMp4({ width: 1080, height: 1080 }), "video.aspect");
  expectCode(makeMp4({ seconds: 1.5 }), "video.duration");
  expectCode(makeMp4({ seconds: 20.5 }), "video.duration");
});

test("rejects GPS metadata and oversized payloads", () => {
  expectCode(makeMp4({ gps: true }), "video.metadata_location");
  expectCode(Buffer.alloc(MAX_VIDEO_BYTES + 1), "video.size");
});

test("rejects truncated and malformed boxes", () => {
  const valid = makeMp4();
  expectCode(valid.subarray(0, 20), "video.parse");
  const overflow = Buffer.from(valid);
  overflow.writeUInt32BE(0xffffffff, 0);
  expectCode(overflow, "video.parse");
});

