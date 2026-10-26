import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import * as macos from "../macos/scripts/injector.mjs";
import * as windows from "../windows/scripts/injector.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "..");
const posterPath = path.join(projectRoot, "macos", "assets", "portal-hero.png");

const u32 = (value) => {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value >>> 0);
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
function makeMp4() {
  const visual = Buffer.alloc(78);
  visual.writeUInt16BE(1920, 24);
  visual.writeUInt16BE(1080, 26);
  visual.writeUInt16BE(1, 40);
  const entry = box("avc1", visual, box("avcC", Buffer.from([1, 100, 0, 0x1f, 0xff, 0xe1, 0, 0])));
  const stsd = fullBox("stsd", 0, 0, u32(1), entry);
  const hdlr = fullBox("hdlr", 0, 0, Buffer.alloc(4), fourcc("vide"), Buffer.alloc(12), Buffer.from("video\0"));
  const minf = box("minf", box("stbl", stsd));
  const mdia = box("mdia", hdlr, minf);
  const tkhdPayload = Buffer.alloc(80);
  tkhdPayload.writeUInt32BE(Math.round(1920 * 65536), 72);
  tkhdPayload.writeUInt32BE(Math.round(1080 * 65536), 76);
  const trak = box("trak", fullBox("tkhd", 0, 3, tkhdPayload), mdia);
  const mvhdPayload = Buffer.alloc(96);
  mvhdPayload.writeUInt32BE(1000, 8);
  mvhdPayload.writeUInt32BE(5000, 12);
  const moov = box("moov", fullBox("mvhd", 0, 0, mvhdPayload), trak);
  return Buffer.concat([
    box("ftyp", fourcc("isom"), u32(0), fourcc("isomiso2avc1mp41")),
    moov,
    box("mdat", Buffer.alloc(32, 0x11)),
  ]);
}

async function makeTheme({ schemaVersion = 2, video = true } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-video-runtime-"));
  await fs.copyFile(posterPath, path.join(dir, "background.png"));
  await fs.writeFile(path.join(dir, "theme.css"),
    '[data-ds-part="composer"] { background-color: var(--ds-theme-color-panel); }\n');
  const theme = {
    schemaVersion,
    id: "runtime.video",
    name: "Runtime Video",
    image: "background.png",
  };
  if (video) theme.video = { file: "background.mp4" };
  await fs.writeFile(path.join(dir, "theme.json"), `${JSON.stringify(theme, null, 2)}\n`);
  if (video) await fs.writeFile(path.join(dir, "background.mp4"), makeMp4());
  return dir;
}

test("both platforms load and hash a schemaVersion 2 video theme", async () => {
  const dir = await makeTheme();
  const preferencesPath = path.join(dir, "preferences.json");
  await fs.writeFile(preferencesPath, JSON.stringify({ schemaVersion: 1, themes: {} }));
  try {
    for (const [name, api] of [["macOS", macos], ["Windows", windows]]) {
      const preferenceOptions = { preferencesPath };
      const loaded = await api.loadTheme(dir, preferenceOptions);
      assert.equal(loaded.theme.schemaVersion, 2, `${name} schema`);
      assert.equal(loaded.videoBytes.length, makeMp4().length, `${name} video bytes`);
      assert.equal(loaded.videoMetadata.width, 1920, `${name} width`);
      const payload = name === "macOS"
        ? await api.loadPayload(dir, preferenceOptions)
        : await api.loadPayload(dir, loaded);
      assert.equal(payload.videoMeta.mime, "video/mp4", `${name} mime`);
      assert.match(payload.videoMeta.key, /^[0-9a-f]{20}$/, `${name} video key`);
      assert.match(payload.payload, new RegExp(`"key":"${payload.videoMeta.key}"`), `${name} payload meta`);
      assert.doesNotMatch(payload.payload, /__DREAM_SKIN_[A-Z0-9_]+_JSON__/, `${name} placeholders`);
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("video preference disables playback without dropping the video contract", async () => {
  const dir = await makeTheme();
  const preferencesPath = path.join(dir, "preferences.json");
  await fs.writeFile(path.join(dir, "theme-video-preferences.json"), JSON.stringify({
    schemaVersion: 1,
    videoBackground: false,
    themes: { "runtime.video": { paused: true, muted: false } },
  }));
  try {
    for (const api of [macos, windows]) {
      const loaded = await api.loadTheme(dir, { preferencesPath });
      assert.equal(loaded.theme.videoEnabled, false);
      assert.equal(loaded.theme.videoPaused, true);
      assert.equal(loaded.theme.videoMuted, false);
      assert.ok(loaded.videoBytes.length > 0);
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("invalid MP4 and legacy-video combinations fail closed", async () => {
  const dir = await makeTheme();
  try {
    const videoPath = path.join(dir, "background.mp4");
    const broken = Buffer.from(await fs.readFile(videoPath));
    broken.writeUInt32BE(0xffffffff, 0);
    await fs.writeFile(videoPath, broken);
    for (const api of [macos, windows]) {
      await assert.rejects(() => api.loadTheme(dir), /Theme video rejected \(video\./);
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }

  const legacy = await makeTheme({ schemaVersion: 1, video: true });
  try {
    for (const api of [macos, windows]) {
      await assert.rejects(() => api.loadTheme(legacy), /video|schemaVersion/);
    }
  } finally {
    await fs.rm(legacy, { recursive: true, force: true });
  }
});


