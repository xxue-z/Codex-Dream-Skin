import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { validateThemePackage } from "../runtime/theme-package-validator.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "..");
const posterPath = path.join(projectRoot, "macos", "assets", "portal-hero.png");
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const json = (value) => Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");

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
function makeMp4({ width = 1920, height = 1080, seconds = 5, profile = 100 } = {}) {
  const visual = Buffer.alloc(78);
  visual.writeUInt16BE(width, 24);
  visual.writeUInt16BE(height, 26);
  visual.writeUInt16BE(1, 40);
  const avcC = box("avcC", Buffer.from([1, profile, 0, 0x1f, 0xff, 0xe1, 0, 0]));
  const entry = box("avc1", visual, avcC);
  const stsd = fullBox("stsd", 0, 0, u32(1), entry);
  const stbl = box("stbl", stsd);
  const minf = box("minf", stbl);
  const hdlr = fullBox("hdlr", 0, 0, Buffer.alloc(4), fourcc("vide"), Buffer.alloc(12), Buffer.from("video\0"));
  const mdia = box("mdia", hdlr, minf);
  const tkhdPayload = Buffer.alloc(80);
  tkhdPayload.writeUInt32BE(0x00010000, 36);
  tkhdPayload.writeUInt32BE(Math.round(width * 65536), 72);
  tkhdPayload.writeUInt32BE(Math.round(height * 65536), 76);
  const tkhd = fullBox("tkhd", 0, 3, tkhdPayload);
  const trak = box("trak", tkhd, mdia);
  const mvhdPayload = Buffer.alloc(96);
  mvhdPayload.writeUInt32BE(1000, 8);
  mvhdPayload.writeUInt32BE(Math.round(seconds * 1000), 12);
  const mvhd = fullBox("mvhd", 0, 0, mvhdPayload);
  const moov = box("moov", mvhd, trak);
  const ftyp = box("ftyp", fourcc("isom"), u32(0), fourcc("isomiso2avc1mp41"));
  return Buffer.concat([ftyp, moov, box("mdat", Buffer.alloc(32, 0x11))]);
}

const colors = {
  background: "#071116", panel: "#0b1a20", panelAlt: "#10272c", accent: "#7cff46",
  accentAlt: "#b8ff3d", secondary: "#36d7e8", highlight: "#642a8c",
  text: "#e9fff1", muted: "#9ebdb3", line: "rgba(124, 255, 70, .28)",
};

async function makePack({
  name,
  skinApiVersion = 2,
  schemaVersion = 2,
  includeVideo = true,
  capabilities = null,
  minClientVersion = "1.6.0",
  mutateTheme = null,
  mutateManifest = null,
} = {}) {
  const source = path.join(await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-video-contract-")), name);
  await fs.mkdir(source);
  const poster = await fs.readFile(posterPath);
  const video = makeMp4();
  const theme = {
    schemaVersion,
    id: "studio.video-contract",
    name: "Video Contract",
    image: "background.png",
    art: { focusX: 0.6, focusY: 0.5, safeArea: "left", taskMode: "ambient" },
    colors,
  };
  if (includeVideo) theme.video = { file: "background.mp4" };
  mutateTheme?.(theme);
  const themeData = json(theme);
  const files = [
    { path: "theme.json", mediaType: "application/json", bytes: themeData.length, sha256: digest(themeData) },
    { path: "background.png", mediaType: "image/png", bytes: poster.length, sha256: digest(poster) },
  ];
  if (includeVideo) {
    files.push({ path: "background.mp4", mediaType: "video/mp4", bytes: video.length, sha256: digest(video) });
  }
  const css = Buffer.from('[data-ds-part="composer"] { background-color: var(--ds-theme-color-panel); }\n');
  files.push({ path: "theme.css", mediaType: "text/css", bytes: css.length, sha256: digest(css) });
  const manifest = {
    packageVersion: 1,
    skinApiVersion,
    themeId: "studio.video-contract",
    version: "1.0.0",
    minClientVersion,
    platforms: ["macos", "windows"],
    capabilities: capabilities ?? ["background", "tokens", "safe-css", ...(includeVideo ? ["video"] : [])],
    publisher: { id: "studio", displayName: "Studio" },
    license: "CC0-1.0",
    provenance: { aiGenerated: false, summary: "Video contract test package." },
    files,
    createdAt: "2026-10-23T00:00:00Z",
  };
  mutateManifest?.(manifest);
  await fs.writeFile(path.join(source, "theme.json"), themeData);
  await fs.writeFile(path.join(source, "background.png"), poster);
  if (includeVideo) await fs.writeFile(path.join(source, "background.mp4"), video);
  await fs.writeFile(path.join(source, "theme.css"), css);
  await fs.writeFile(path.join(source, "manifest.json"), json(manifest));
  return source;
}

async function validate(source, { clientVersion = "1.6.0", platform = "macos" } = {}) {
  const stage = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-video-stage-"));
  return {
    result: await validateThemePackage({ source, stage, platform, clientVersion }),
    stage,
  };
}

test("API 2 accepts a video package and reports metadata", async () => {
  const source = await makePack({ name: "valid-video" });
  const { result, stage } = await validate(source);
  assert.equal(result.format, "official");
  assert.equal(result.video, "background.mp4");
  assert.equal(result.videoMetadata.width, 1920);
  assert.equal(result.videoMetadata.durationMs, 5000);
  assert.deepEqual((await fs.readdir(stage)).sort(), [
    "background.mp4", "background.png", "manifest.json", "theme.css", "theme.json",
  ]);
});

test("API 2 remains valid without a video", async () => {
  const source = await makePack({ name: "valid-static", includeVideo: false });
  const { result } = await validate(source);
  assert.equal(result.video, null);
  assert.equal(result.videoMetadata, null);
});

test("API 1 packages cannot ship a video file", async () => {
  const source = await makePack({
    name: "api1-video",
    skinApiVersion: 1,
    schemaVersion: 1,
    includeVideo: true,
    minClientVersion: "1.3.0",
  });
  await assert.rejects(() => validate(source), /Skin API 1/);
});

test("API 2 requires schemaVersion 2", async () => {
  const source = await makePack({ name: "api2-schema1", schemaVersion: 1 });
  await assert.rejects(() => validate(source), /schemaVersion 2/);
});

test("video capability and file must agree with theme.json", async () => {
  const noCapability = await makePack({
    name: "missing-capability",
    capabilities: ["background", "tokens", "safe-css"],
  });
  await assert.rejects(() => validate(noCapability), /video capability/);

  const undeclared = await makePack({ name: "undeclared-video" });
  const themePath = path.join(undeclared, "theme.json");
  const theme = JSON.parse(await fs.readFile(themePath, "utf8"));
  delete theme.video;
  const themeData = json(theme);
  await fs.writeFile(themePath, themeData);
  const manifestPath = path.join(undeclared, "manifest.json");
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const themeEntry = manifest.files.find((file) => file.path === "theme.json");
  themeEntry.bytes = themeData.length;
  themeEntry.sha256 = digest(themeData);
  await fs.writeFile(manifestPath, json(manifest));
  await assert.rejects(() => validate(undeclared), /video capability|background\.mp4/);
});

test("a declared video must exist", async () => {
  const source = await makePack({ name: "missing-video-file" });
  await fs.rm(path.join(source, "background.mp4"));
  await assert.rejects(() => validate(source), /exactly match manifest\.files|missing file|background\.mp4/);
});
test("API 2 requires a client that supports the new contract", async () => {
  const source = await makePack({ name: "old-client" });
  await assert.rejects(() => validate(source, { clientVersion: "1.5.21" }), /minClientVersion|requires/);
  const lowMinimum = await makePack({ name: "low-minimum", minClientVersion: "1.5.21" });
  await assert.rejects(() => validate(lowMinimum), /minClientVersion|1\.6\.0/);
});

test("hash and byte mismatches are rejected", async () => {
  const source = await makePack({ name: "bad-hash" });
  const manifestPath = path.join(source, "manifest.json");
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  manifest.files.find((file) => file.path === "background.mp4").sha256 = "0".repeat(64);
  await fs.writeFile(manifestPath, json(manifest));
  await assert.rejects(() => validate(source), /SHA-256/);
});
