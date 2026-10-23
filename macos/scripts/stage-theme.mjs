import fs from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import path from "node:path";
import { decodeAndValidateSafeCss } from "../assets/safe-css-validator.mjs";
import { runtimeThemeContentFingerprint } from "./theme-content-fingerprint.mjs";
import { MAX_VIDEO_BYTES, Mp4ValidationError, readMp4Metadata } from "../assets/mp4-metadata.mjs";

const [sourceDirArg, stageDirArg] = process.argv.slice(2);
if (!sourceDirArg || !stageDirArg) {
  throw new Error("Usage: stage-theme.mjs <source-theme-dir> <stage-dir>");
}

const MAX_CONFIG_BYTES = 1024 * 1024;
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_CSS_BYTES = 256 * 1024;
const OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);

function assertContained(rootPath, candidatePath, label) {
  const relative = path.relative(rootPath, candidatePath);
  if (
    relative === ""
    || (!path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`))
  ) return;
  throw new Error(`${label} must stay inside its theme directory`);
}

function sameStat(left, right) {
  return left.isFile() && right.isFile()
    && left.dev === right.dev
    && left.ino === right.ino
    && left.size === right.size
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs;
}

async function readStableFile(filePath, label, maxBytes) {
  let handle;
  try {
    handle = await fs.open(filePath, OPEN_FLAGS);
  } catch (error) {
    if (error.code === "ELOOP") throw new Error(`${label} must not be a symbolic link`);
    throw error;
  }
  try {
    const before = await handle.stat();
    if (!before.isFile()) throw new Error(`${label} must be a regular file`);
    if (before.size > maxBytes) throw new Error(`${label} is larger than ${maxBytes} bytes`);
    const bytes = await handle.readFile();
    const after = await handle.stat();
    if (!sameStat(before, after)) {
      throw new Error(`${label} changed while it was being staged`);
    }
    if (bytes.length > maxBytes) throw new Error(`${label} is larger than ${maxBytes} bytes`);
    return { bytes, stat: after };
  } finally {
    await handle.close();
  }
}

async function readOptionalStableFile(filePath, label, maxBytes) {
  try {
    return await readStableFile(filePath, label, maxBytes);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function decodeJson(bytes, label) {
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (text.includes("\0")) throw new Error(`${label} contains NUL characters`);
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${label} is not valid JSON`);
  }
}

async function writeExclusive(filePath, bytes) {
  const temporary = `${filePath}.${process.pid}.tmp`;
  try {
    await fs.writeFile(temporary, bytes, { flag: "wx", mode: 0o600 });
    await fs.rename(temporary, filePath);
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
}

async function main() {
  const sourceRoot = await fs.realpath(sourceDirArg);
  const sourceStat = await fs.stat(sourceRoot);
  if (!sourceStat.isDirectory()) throw new Error("Theme source must be a directory");

  const configPath = path.join(sourceRoot, "theme.json");
  const config = await readStableFile(configPath, "Theme config", MAX_CONFIG_BYTES);
  const theme = decodeJson(config.bytes, "Theme config");
  if ((theme?.schemaVersion !== 1 && theme?.schemaVersion !== 2) ||
      typeof theme.image !== "string" || !theme.image) {
    throw new Error("Theme config has an unsupported schema or image field");
  }
  if (theme.schemaVersion === 1 && theme.video !== undefined) {
    throw new Error("Theme config must not declare video with schemaVersion 1");
  }
  let video = null;
  if (theme.schemaVersion === 2 && theme.video !== undefined) {
    if (!theme.video || typeof theme.video !== "object" || Array.isArray(theme.video) ||
        theme.video.file !== "background.mp4") {
      throw new Error("Theme config has an unsupported video field");
    }
    video = await readStableFile(path.join(sourceRoot, "background.mp4"), "Theme video", MAX_VIDEO_BYTES);
    if (video.bytes.length < 1) throw new Error("Theme video is empty");
    try {
      readMp4Metadata(video.bytes);
    } catch (error) {
      if (error instanceof Mp4ValidationError) {
        throw new Error(`Theme video rejected (${error.code}): ${error.message}`);
      }
      throw error;
    }
  }
  if (path.basename(theme.image) !== theme.image) {
    throw new Error("Theme image must stay inside its theme directory");
  }
  if (theme.image === "theme.json") {
    throw new Error("Theme image must not replace theme.json");
  }
  if (/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u.test(theme.image)) {
    throw new Error("Theme image contains control characters");
  }

  const imagePath = path.resolve(sourceRoot, theme.image);
  assertContained(sourceRoot, imagePath, "Theme image");
  const [image, safeCss] = await Promise.all([
    readStableFile(imagePath, "Theme image", MAX_IMAGE_BYTES),
    readOptionalStableFile(path.join(sourceRoot, "theme.css"), "Theme Safe CSS", MAX_CSS_BYTES),
  ]);
  if (image.bytes.length < 1) throw new Error("Theme image is empty");
  if (safeCss) decodeAndValidateSafeCss(safeCss.bytes);

  const stageRoot = await fs.realpath(stageDirArg);
  const stageStat = await fs.stat(stageRoot);
  if (!stageStat.isDirectory()) throw new Error("Theme stage must be a directory");
  assertContained(stageRoot, path.join(stageRoot, "theme.json"), "Staged theme config");
  assertContained(stageRoot, path.join(stageRoot, theme.image), "Staged theme image");

  // Write both files from the already-open, stable descriptors. The caller
  // publishes the image first and theme.json last, so the watcher only ever
  // observes a complete pair; subsequent source edits cannot race the copy.
  await writeExclusive(path.join(stageRoot, theme.image), image.bytes);
  if (safeCss) await writeExclusive(path.join(stageRoot, "theme.css"), safeCss.bytes);
  if (video) await writeExclusive(path.join(stageRoot, "background.mp4"), video.bytes);
  await writeExclusive(path.join(stageRoot, "theme.json"), config.bytes);
  process.stdout.write(JSON.stringify({
    image: theme.image,
    video: video ? "background.mp4" : null,
    contentFingerprint: runtimeThemeContentFingerprint(theme, image.bytes, safeCss?.bytes ?? null, video?.bytes ?? null),
  }));
}

await main();
