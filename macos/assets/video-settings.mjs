// Local default-theme video settings. Kept separate from
// video-playlist.json because the injector rewrites playlist state (index,
// position, mute, pause) from a fixed field list, which would erase settings.
// Node-only: the tray/menu layer validates interactive choices, while the
// injector reads this bounded file to resolve the effective folder, detection
// cadence and scrim transparency.

import fs from "node:fs/promises";
import path from "node:path";

export const VIDEO_SETTINGS_SCHEMA = 1;
export const MAX_VIDEO_SETTINGS_BYTES = 64 * 1024;
export const MAX_VIDEO_DIRECTORY_LENGTH = 1024;
export const POLL_INTERVAL_OPTIONS = Object.freeze([1, 2, 5, 10, 30]);
export const DEFAULT_POLL_INTERVAL_SECONDS = 2;
export const DEFAULT_VEIL = 100;

export const DEFAULT_VIDEO_SETTINGS = Object.freeze({
  schemaVersion: VIDEO_SETTINGS_SCHEMA,
  autoDiscover: true,
  pollIntervalSeconds: DEFAULT_POLL_INTERVAL_SECONDS,
  videoDirectory: null,
  veil: DEFAULT_VEIL,
  updatedAt: "",
});

const UNSAFE_PATH = /[\u0000-\u001f\u007f\u2028\u2029]/u;

export function normalizePollInterval(value) {
  return POLL_INTERVAL_OPTIONS.includes(value) ? value : DEFAULT_POLL_INTERVAL_SECONDS;
}

export function normalizeVeil(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return DEFAULT_VEIL;
  return Math.min(100, Math.max(0, Math.round(number)));
}

export function normalizeVideoDirectory(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_VIDEO_DIRECTORY_LENGTH) return null;
  if (UNSAFE_PATH.test(trimmed)) return null;
  // Reject network shares on both platforms: a dead UNC path blocks stat calls
  // and turns the watcher loop into an unbounded hang.
  if (/^[\\/]{2}/u.test(trimmed)) return null;
  if (!path.isAbsolute(trimmed)) return null;
  return trimmed;
}

export function clampVideoSettings(input, options = {}) {
  const source = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  const legacySoftVeil = typeof options.legacySoftVeil === "boolean"
    ? options.legacySoftVeil : undefined;
  const hasVeil = Object.prototype.hasOwnProperty.call(source, "veil");
  const veil = hasVeil
    ? normalizeVeil(source.veil)
    : legacySoftVeil === false ? 0 : DEFAULT_VEIL;
  return {
    schemaVersion: VIDEO_SETTINGS_SCHEMA,
    autoDiscover: typeof source.autoDiscover === "boolean" ? source.autoDiscover : true,
    pollIntervalSeconds: normalizePollInterval(source.pollIntervalSeconds),
    videoDirectory: normalizeVideoDirectory(source.videoDirectory),
    veil,
    updatedAt: typeof source.updatedAt === "string" ? source.updatedAt.slice(0, 40) : "",
  };
}

async function readLegacySoftVeil(playlistStatePath) {
  if (!playlistStatePath) return undefined;
  try {
    const stat = await fs.stat(playlistStatePath);
    if (!stat.isFile() || stat.size > MAX_VIDEO_SETTINGS_BYTES) return undefined;
    const raw = JSON.parse(await fs.readFile(playlistStatePath, "utf8"));
    return typeof raw?.softVeil === "boolean" ? raw.softVeil : undefined;
  } catch {
    return undefined;
  }
}

export async function readVideoSettings(filePath, options = {}) {
  let raw;
  try {
    const stat = await fs.stat(filePath);
    if (!stat.isFile() || stat.size > MAX_VIDEO_SETTINGS_BYTES) throw new Error("invalid");
    raw = JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch {
    const legacySoftVeil = await readLegacySoftVeil(options.playlistStatePath);
    return clampVideoSettings({}, { legacySoftVeil });
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw) ||
      raw.schemaVersion !== VIDEO_SETTINGS_SCHEMA) {
    const legacySoftVeil = await readLegacySoftVeil(options.playlistStatePath);
    return clampVideoSettings({}, { legacySoftVeil });
  }
  return clampVideoSettings(raw);
}

export async function writeVideoSettingsAtomic(filePath, settings) {
  const value = clampVideoSettings({
    ...settings,
    updatedAt: new Date().toISOString(),
  });
  const payload = `${JSON.stringify(value, null, 2)}\n`;
  await fs.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporary = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  try {
    await fs.writeFile(temporary, payload, { mode: 0o600, flag: "wx" });
    await fs.rename(temporary, filePath);
    await fs.chmod(filePath, 0o600).catch(() => {});
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
  return value;
}

export function resolveVideoDirectory(settings, defaultDirectory) {
  const configured = normalizeVideoDirectory(settings?.videoDirectory);
  return configured || defaultDirectory;
}

export function shouldPollPlaylist(settings, nowMs, lastPollMs) {
  if (settings?.autoDiscover === false) return false;
  const intervalMs = normalizePollInterval(settings?.pollIntervalSeconds) * 1000;
  if (!Number.isFinite(lastPollMs) || lastPollMs <= 0) return true;
  return Number(nowMs) - lastPollMs >= intervalMs;
}
