// Local default-theme video playlist. This module is Node-only: it scans the
// user's local videos directory, clamps persisted progress, and never reads
// video bytes. The renderer receives disk-backed File objects through CDP.

import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

export const PLAYLIST_STATE_SCHEMA = 1;
export const MAX_PLAYLIST_FILES = 500;
export const MAX_PLAYLIST_FILE_BYTES = 8 * 1024 * 1024 * 1024;
export const MAX_PLAYLIST_POSITION_SECONDS = 24 * 60 * 60;
export const PLAYLIST_EXTENSIONS = new Set([".mp4", ".webm"]);

export const DEFAULT_PLAYLIST_STATE = Object.freeze({
  schemaVersion: PLAYLIST_STATE_SCHEMA,
  index: 0,
  positionSeconds: 0,
  muted: true,
  paused: false,
  softVeil: true,
  updatedAt: "",
});

const UNSAFE_NAME = /[\u0000-\u001f\u007f\u2028\u2029]/u;

export function naturalCompare(left, right) {
  return String(left).localeCompare(String(right), undefined, {
    numeric: true,
    sensitivity: "base",
  });
}

export function playlistExtension(name) {
  return path.extname(String(name)).toLowerCase();
}

export function isPlaylistCandidateName(name) {
  const value = String(name);
  if (!value || value.startsWith(".") || UNSAFE_NAME.test(value)) return false;
  if (path.basename(value) !== value) return false;
  return PLAYLIST_EXTENSIONS.has(playlistExtension(value));
}

export async function scanVideoDirectory(directory, options = {}) {
  const maxFiles = Number.isSafeInteger(options.maxFiles)
    ? Math.max(1, options.maxFiles) : MAX_PLAYLIST_FILES;
  const maxFileBytes = Number.isSafeInteger(options.maxFileBytes)
    ? Math.max(1, options.maxFileBytes) : MAX_PLAYLIST_FILE_BYTES;
  const entries = [];
  const skipped = [];
  let directoryMtimeMs = 0;
  try {
    directoryMtimeMs = (await fs.stat(directory)).mtimeMs;
  } catch (error) {
    if (error.code === "ENOENT") {
      return { entries, skipped, directoryMtimeMs: 0, count: 0 };
    }
    throw error;
  }
  const dirents = await fs.readdir(directory, { withFileTypes: true });
  for (const dirent of dirents) {
    const name = String(dirent.name);
    if (name.startsWith(".")) {
      skipped.push({ name, reason: "hidden" });
      continue;
    }
    if (UNSAFE_NAME.test(name) || path.basename(name) !== name) {
      skipped.push({ name, reason: "unsafe-name" });
      continue;
    }
    if (!dirent.isFile()) {
      skipped.push({ name, reason: dirent.isDirectory() ? "subdirectory" : "not-file" });
      continue;
    }
    if (!isPlaylistCandidateName(name)) {
      skipped.push({ name, reason: "unsupported" });
      continue;
    }
    const candidate = path.join(directory, name);
    let stat;
    try {
      stat = await fs.lstat(candidate);
    } catch {
      skipped.push({ name, reason: "unreadable" });
      continue;
    }
    if (stat.isSymbolicLink()) {
      skipped.push({ name, reason: "link" });
      continue;
    }
    if (!stat.isFile()) {
      skipped.push({ name, reason: "not-file" });
      continue;
    }
    if (stat.size < 1) {
      skipped.push({ name, reason: "empty" });
      continue;
    }
    if (stat.size > maxFileBytes) {
      skipped.push({ name, reason: "too-large" });
      continue;
    }
    entries.push({ name, path: candidate, size: stat.size, mtimeMs: stat.mtimeMs });
  }
  entries.sort((left, right) => naturalCompare(left.name, right.name));
  if (entries.length > maxFiles) {
    for (const extra of entries.slice(maxFiles)) {
      skipped.push({ name: extra.name, reason: "too-many" });
    }
    entries.length = maxFiles;
  }
  return { entries, skipped, directoryMtimeMs, count: entries.length };
}

export function playlistFingerprint(entries) {
  const hash = createHash("sha256");
  hash.update("dreamskin-video-playlist/1\0");
  for (const entry of entries) {
    hash.update(`${entry.name}\0${entry.size}\0${Math.round(entry.mtimeMs)}\n`);
  }
  return hash.digest("hex");
}

function finiteInteger(value, fallback) {
  return Number.isSafeInteger(value) ? value : fallback;
}

function clampedNumber(value, min, max, fallback) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

export function clampPlaylistState(input, count) {
  const total = Number.isSafeInteger(count) ? Math.max(0, count) : 0;
  const source = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  const index = total > 0
    ? Math.min(total - 1, Math.max(0, finiteInteger(source.index, 0)))
    : 0;
  return {
    schemaVersion: PLAYLIST_STATE_SCHEMA,
    index,
    positionSeconds: clampedNumber(
      source.positionSeconds, 0, MAX_PLAYLIST_POSITION_SECONDS, 0,
    ),
    muted: typeof source.muted === "boolean" ? source.muted : true,
    paused: typeof source.paused === "boolean" ? source.paused : false,
    softVeil: typeof source.softVeil === "boolean" ? source.softVeil : true,
    updatedAt: typeof source.updatedAt === "string" ? source.updatedAt.slice(0, 40) : "",
  };
}

export async function readPlaylistState(filePath, count = 0) {
  let raw;
  try {
    raw = JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT" || error instanceof SyntaxError) {
      return clampPlaylistState(DEFAULT_PLAYLIST_STATE, count);
    }
    throw error;
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw) ||
      raw.schemaVersion !== PLAYLIST_STATE_SCHEMA) {
    return clampPlaylistState(DEFAULT_PLAYLIST_STATE, count);
  }
  return clampPlaylistState(raw, count);
}

export async function writePlaylistStateAtomic(filePath, state) {
  const source = state && typeof state === "object" && !Array.isArray(state) ? state : {};
  const payload = `${JSON.stringify({
    schemaVersion: PLAYLIST_STATE_SCHEMA,
    index: Math.max(0, finiteInteger(source.index, 0)),
    positionSeconds: clampedNumber(source.positionSeconds, 0, MAX_PLAYLIST_POSITION_SECONDS, 0),
    muted: typeof source.muted === "boolean" ? source.muted : true,
    paused: typeof source.paused === "boolean" ? source.paused : false,
    softVeil: typeof source.softVeil === "boolean" ? source.softVeil : true,
    updatedAt: typeof source.updatedAt === "string" ? source.updatedAt.slice(0, 40) : "",
  }, null, 2)}\n`;
  await fs.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  try {
    await fs.writeFile(temporary, payload, { mode: 0o600, flag: "wx" });
    await fs.rename(temporary, filePath);
    await fs.chmod(filePath, 0o600).catch(() => {});
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
}

export function playlistDisplayName(entry) {
  return entry && typeof entry.name === "string" ? entry.name : "";
}

export function playlistSummary(scan, state, options = {}) {
  const numericVeil = Number(options.veil);
  const veil = Number.isFinite(numericVeil)
    ? Math.min(100, Math.max(0, Math.round(numericVeil))) : 100;
  return {
    count: scan?.count ?? 0,
    fingerprint: playlistFingerprint(scan?.entries ?? []),
    skipped: (scan?.skipped ?? []).slice(0, 20).map((item) => ({
      name: String(item.name).slice(0, 200),
      reason: String(item.reason),
    })),
    index: state?.index ?? 0,
    positionSeconds: state?.positionSeconds ?? 0,
    muted: state?.muted !== false,
    paused: state?.paused === true,
    // softVeil stays for state-file compatibility with 1.6.x clients; the
    // renderer now consumes the numeric veil from video-settings.json.
    softVeil: state?.softVeil !== false,
    veil,
  };
}
