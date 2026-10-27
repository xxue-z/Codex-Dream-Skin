import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import * as macos from "../macos/scripts/injector.mjs";
import * as windows from "../windows/scripts/injector.mjs";
import {
  DEFAULT_VIDEO_SETTINGS,
  MAX_VIDEO_SETTINGS_BYTES,
  clampVideoSettings,
  readVideoSettings,
  resolveVideoDirectory,
  shouldPollPlaylist,
  writeVideoSettingsAtomic,
} from "../runtime/video-settings.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "..");
const poster = path.join(projectRoot, "windows", "assets", "dream-reference.jpg");

async function makeStateRoot() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-video-settings-"));
  await fs.mkdir(path.join(root, "videos"), { recursive: true });
  await fs.writeFile(path.join(root, "videos", "default.mp4"), Buffer.from([1]));
  const custom = path.join(root, "custom-videos");
  await fs.mkdir(custom, { recursive: true });
  await fs.writeFile(path.join(custom, "custom.webm"), Buffer.from([2]));
  return { root, custom, videos: path.join(root, "videos") };
}

async function makeTheme(id = "preset-arina-hashimoto") {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-video-theme-"));
  await fs.copyFile(poster, path.join(dir, "dream-reference.jpg"));
  await fs.writeFile(path.join(dir, "theme.css"), '[data-ds-part="composer"] { border-radius: 24px; }\n');
  const theme = {
    schemaVersion: 1,
    id,
    name: "Test",
    image: "dream-reference.jpg",
    videoPlaylist: { enabled: true },
  };
  await fs.writeFile(path.join(dir, "theme.json"), JSON.stringify(theme, null, 2) + "\n");
  return dir;
}

test("video settings default, clamp and normalize", () => {
  const defaults = clampVideoSettings(null);
  assert.deepEqual(defaults, { ...DEFAULT_VIDEO_SETTINGS, updatedAt: "" });
  assert.equal(defaults.autoDiscover, true);
  assert.equal(defaults.pollIntervalSeconds, 2);
  assert.equal(defaults.videoDirectory, null);
  assert.equal(defaults.veil, 100);

  const clamped = clampVideoSettings({
    schemaVersion: 1,
    autoDiscover: false,
    pollIntervalSeconds: 7,
    videoDirectory: "relative/path",
    veil: 146,
  });
  assert.equal(clamped.autoDiscover, false);
  assert.equal(clamped.pollIntervalSeconds, 2);
  assert.equal(clamped.videoDirectory, null);
  assert.equal(clamped.veil, 100);

  assert.equal(clampVideoSettings({ veil: -9 }).veil, 0);
  assert.equal(clampVideoSettings({ veil: "42.6" }).veil, 43);
  assert.equal(clampVideoSettings({ pollIntervalSeconds: 30 }).pollIntervalSeconds, 30);
  assert.equal(clampVideoSettings({ videoDirectory: "\\\\server\\share" }).videoDirectory, null);
  assert.equal(clampVideoSettings({ videoDirectory: "/Volumes/Videos" }).videoDirectory, "/Volumes/Videos");
});

test("video settings migrate the legacy softVeil flag only when veil is absent", async () => {
  const { root } = await makeStateRoot();
  const playlistPath = path.join(root, "video-playlist.json");
  await fs.writeFile(playlistPath, JSON.stringify({ schemaVersion: 1, softVeil: false }));
  const settingsPath = path.join(root, "video-settings.json");
  const migrated = await readVideoSettings(settingsPath, { playlistStatePath: playlistPath });
  assert.equal(migrated.veil, 0);
  assert.equal(migrated.autoDiscover, true);

  await fs.writeFile(settingsPath, JSON.stringify({
    schemaVersion: 1, autoDiscover: true, pollIntervalSeconds: 5,
    videoDirectory: null, veil: 88, updatedAt: "",
  }));
  const explicit = await readVideoSettings(settingsPath, { playlistStatePath: playlistPath });
  assert.equal(explicit.veil, 88);
  assert.equal(explicit.pollIntervalSeconds, 5);
});

test("video settings reject corrupt and oversized files by falling back to defaults", async () => {
  const { root } = await makeStateRoot();
  const settingsPath = path.join(root, "video-settings.json");
  await fs.writeFile(settingsPath, "{");
  assert.equal((await readVideoSettings(settingsPath)).veil, 100);
  await fs.writeFile(settingsPath, "x".repeat(MAX_VIDEO_SETTINGS_BYTES + 1));
  assert.equal((await readVideoSettings(settingsPath)).autoDiscover, true);
  await fs.writeFile(settingsPath, JSON.stringify({ schemaVersion: 2, veil: 1 }));
  assert.equal((await readVideoSettings(settingsPath)).veil, 100);
});

test("video settings write atomically with normalized values", async () => {
  const { root, custom } = await makeStateRoot();
  const settingsPath = path.join(root, "video-settings.json");
  const saved = await writeVideoSettingsAtomic(settingsPath, {
    autoDiscover: false,
    pollIntervalSeconds: 10,
    videoDirectory: custom,
    veil: 33,
  });
  assert.equal(saved.veil, 33);
  assert.equal(saved.pollIntervalSeconds, 10);
  assert.equal(saved.videoDirectory, custom);
  assert.ok(saved.updatedAt);
  const raw = JSON.parse(await fs.readFile(settingsPath, "utf8"));
  assert.equal(raw.schemaVersion, 1);
  assert.equal(raw.videoDirectory, custom);
  const roundTrip = await readVideoSettings(settingsPath);
  assert.equal(roundTrip.autoDiscover, false);
  assert.equal(roundTrip.veil, 33);
});

test("playlist polling honours autoDiscover and the configured interval", () => {
  assert.equal(shouldPollPlaylist({ autoDiscover: false, pollIntervalSeconds: 1 }, 100000, 0), false);
  assert.equal(shouldPollPlaylist({ autoDiscover: true, pollIntervalSeconds: 5 }, 100000, 0), true);
  assert.equal(shouldPollPlaylist({ autoDiscover: true, pollIntervalSeconds: 5 }, 100000, 96001), false);
  assert.equal(shouldPollPlaylist({ autoDiscover: true, pollIntervalSeconds: 5 }, 100000, 95000), true);
  assert.equal(resolveVideoDirectory({ videoDirectory: null }, "/default"), "/default");
  assert.equal(resolveVideoDirectory({ videoDirectory: "/custom" }, "/default"), "/custom");
});

test("both injectors use video-settings.json for the folder and veil", async () => {
  const state = await makeStateRoot();
  const winTheme = await makeTheme("preset-arina-hashimoto");
  const macTheme = await makeTheme("preset-gothic-void-crusade");
  await writeVideoSettingsAtomic(path.join(state.root, "video-settings.json"), {
    autoDiscover: false,
    pollIntervalSeconds: 30,
    videoDirectory: state.custom,
    veil: 12,
  });
  const options = { videoDir: state.videos, posterPath: path.join(state.root, "poster.jpeg") };
  const win = await windows.loadPayload(winTheme, null, options);
  const mac = await macos.loadPayload(macTheme, {}, options);
  for (const [name, loaded] of [["windows", win], ["macos", mac]]) {
    assert.equal(loaded.playlist.scan.count, 1, name);
    assert.deepEqual(loaded.playlist.scan.entries.map((entry) => entry.name), ["custom.webm"], name);
    assert.equal(loaded.playlist.summary.veil, 12, name);
    assert.equal(loaded.theme.videoPlaylist.enabled, true, name);
  }
});

test("an explicit video directory wins over video-settings.json", async () => {
  const state = await makeStateRoot();
  const theme = await makeTheme();
  await writeVideoSettingsAtomic(path.join(state.root, "video-settings.json"), {
    autoDiscover: true,
    pollIntervalSeconds: 2,
    videoDirectory: state.custom,
    veil: 50,
  });
  const options = {
    videoDir: state.videos,
    videoDirExplicit: true,
    posterPath: path.join(state.root, "poster.jpeg"),
  };
  const loaded = await windows.loadPayload(theme, null, options);
  assert.deepEqual(loaded.playlist.scan.entries.map((entry) => entry.name), ["default.mp4"]);
  assert.equal(loaded.playlist.summary.veil, 50);
});