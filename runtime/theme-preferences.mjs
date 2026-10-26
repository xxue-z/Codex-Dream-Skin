import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export function themePreferencesPath(platform = process.platform, env = process.env, home = os.homedir()) {
  const stateRoot = platform === "win32"
    ? path.join(env.LOCALAPPDATA || path.join(home, "AppData", "Local"), "CodexDreamSkin")
    : path.join(home, "Library", "Application Support", "CodexDreamSkinStudio");
  return path.join(stateRoot, "theme-preferences.json");
}

export function themeVideoPreferencesPath(preferencesPath = themePreferencesPath()) {
  return path.join(path.dirname(preferencesPath), "theme-video-preferences.json");
}

const MAX_BYTES = 256 * 1024;
const warned = new Set();

async function readJsonPreferences(filePath, warn) {
  let handle;
  try {
    handle = await fs.open(filePath, "r");
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > MAX_BYTES) throw new Error("invalid preferences");
    const bytes = Buffer.alloc(MAX_BYTES + 1);
    let length = 0;
    while (length < bytes.length) {
      const result = await handle.read(bytes, length, bytes.length - length, null);
      if (!result.bytesRead) break;
      length += result.bytesRead;
    }
    if (length > MAX_BYTES) throw new Error("invalid preferences");
    const data = JSON.parse(bytes.subarray(0, length).toString("utf8"));
    if (data?.schemaVersion !== 1) throw new Error("invalid preferences");
    warned.delete(filePath);
    return data;
  } catch (error) {
    if (error.code !== "ENOENT" && !warned.has(filePath)) {
      warned.add(filePath);
      warn("[dream-skin] Local theme preferences unavailable or invalid; using theme defaults.");
    }
    return null;
  } finally {
    await handle?.close();
  }
}

export async function readThemeTransparency(themeId, {
  preferencesPath = themePreferencesPath(),
  warn = (message) => console.error(message),
} = {}) {
  const data = await readJsonPreferences(preferencesPath, warn);
  if (!data || !data.themes || typeof data.themes !== "object" || Array.isArray(data.themes) ||
    !Object.hasOwn(data.themes, themeId)) return undefined;
  const value = data.themes[themeId]?.transparency;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 100) {
    return undefined;
  }
  return value;
}

export async function readThemeVideoPreference(themeId, {
  preferencesPath = themePreferencesPath(),
  warn = (message) => console.error(message),
} = {}) {
  const data = await readJsonPreferences(themeVideoPreferencesPath(preferencesPath), warn);
  if (!data) return { enabled: true, paused: false, muted: true };
  const entry = data.themes && typeof data.themes === "object" && !Array.isArray(data.themes)
    ? data.themes[themeId] : null;
  return {
    enabled: typeof data.videoBackground === "boolean" ? data.videoBackground : true,
    paused: entry?.paused === true,
    muted: typeof entry?.muted === "boolean" ? entry.muted : true,
  };
}
