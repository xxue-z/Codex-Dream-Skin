import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  DEFAULT_PLAYLIST_STATE,
  clampPlaylistState,
  naturalCompare,
  playlistFingerprint,
  readPlaylistState,
  scanVideoDirectory,
  writePlaylistStateAtomic,
} from "../runtime/video-playlist.mjs";

async function tempDir(prefix) {
  return fs.mkdtemp(path.join(os.tmpdir(), prefix));
}

test("natural sort orders 2 before 10", () => {
  assert.deepEqual(["10.mp4", "2.mp4", "1.mp4"].sort(naturalCompare), ["1.mp4", "2.mp4", "10.mp4"]);
});

test("scan keeps supported direct files, sorts them, and reports skips", async () => {
  const dir = await tempDir("dreamskin-playlist-scan-");
  await fs.writeFile(path.join(dir, "10.mp4"), Buffer.from([1]));
  await fs.writeFile(path.join(dir, "2.webm"), Buffer.from([1]));
  await fs.writeFile(path.join(dir, "1.mp4"), Buffer.from([1]));
  await fs.writeFile(path.join(dir, ".hidden.mp4"), Buffer.from([1]));
  await fs.writeFile(path.join(dir, "note.txt"), Buffer.from([1]));
  await fs.writeFile(path.join(dir, "empty.mp4"), Buffer.alloc(0));
  await fs.mkdir(path.join(dir, "subdir"));
  await fs.writeFile(path.join(dir, "subdir", "3.mp4"), Buffer.from([1]));
  await fs.writeFile(path.join(dir, "big.mp4"), Buffer.alloc(8, 1));
  const scan = await scanVideoDirectory(dir, { maxFileBytes: 4 });
  assert.deepEqual(scan.entries.map((entry) => entry.name), ["1.mp4", "2.webm", "10.mp4"]);
  assert.equal(scan.count, 3);
  const reasons = new Map(scan.skipped.map((item) => [item.name, item.reason]));
  assert.equal(reasons.get(".hidden.mp4"), "hidden");
  assert.equal(reasons.get("note.txt"), "unsupported");
  assert.equal(reasons.get("empty.mp4"), "empty");
  assert.equal(reasons.get("subdir"), "subdirectory");
  assert.equal(reasons.get("big.mp4"), "too-large");
});

test("scan caps the number of files", async () => {
  const dir = await tempDir("dreamskin-playlist-cap-");
  for (const name of ["1.mp4", "2.mp4", "3.mp4"]) {
    await fs.writeFile(path.join(dir, name), Buffer.from([1]));
  }
  const scan = await scanVideoDirectory(dir, { maxFiles: 2 });
  assert.deepEqual(scan.entries.map((entry) => entry.name), ["1.mp4", "2.mp4"]);
  assert.ok(scan.skipped.some((item) => item.name === "3.mp4" && item.reason === "too-many"));
});

test("missing directory is an empty playlist", async () => {
  const scan = await scanVideoDirectory(path.join(os.tmpdir(), "dreamskin-missing-" + Date.now()));
  assert.equal(scan.count, 0);
  assert.deepEqual(scan.entries, []);
});

test("playlist fingerprint changes with name, size or mtime", () => {
  const base = [{ name: "a.mp4", size: 1, mtimeMs: 100 }];
  const same = [{ name: "a.mp4", size: 1, mtimeMs: 100 }];
  const renamed = [{ name: "b.mp4", size: 1, mtimeMs: 100 }];
  const resized = [{ name: "a.mp4", size: 2, mtimeMs: 100 }];
  const touched = [{ name: "a.mp4", size: 1, mtimeMs: 101 }];
  assert.equal(playlistFingerprint(base), playlistFingerprint(same));
  assert.notEqual(playlistFingerprint(base), playlistFingerprint(renamed));
  assert.notEqual(playlistFingerprint(base), playlistFingerprint(resized));
  assert.notEqual(playlistFingerprint(base), playlistFingerprint(touched));
});

test("state clamps index and position and defaults invalid input", () => {
  assert.deepEqual(clampPlaylistState(DEFAULT_PLAYLIST_STATE, 0), {
    schemaVersion: 1, index: 0, positionSeconds: 0,
    muted: true, paused: false, softVeil: true, updatedAt: "",
  });
  const clamped = clampPlaylistState({ index: 99, positionSeconds: -4, muted: false, paused: true, softVeil: false }, 3);
  assert.equal(clamped.index, 2);
  assert.equal(clamped.positionSeconds, 0);
  assert.equal(clamped.muted, false);
  assert.equal(clamped.paused, true);
  assert.equal(clamped.softVeil, false);
});

test("state round-trips atomically and corrupt files fall back", async () => {
  const dir = await tempDir("dreamskin-playlist-state-");
  const file = path.join(dir, "video-playlist.json");
  await writePlaylistStateAtomic(file, { index: 1, positionSeconds: 12.5, muted: false });
  const loaded = await readPlaylistState(file, 3);
  assert.equal(loaded.index, 1);
  assert.equal(loaded.positionSeconds, 12.5);
  assert.equal(loaded.muted, false);
  await fs.writeFile(file, "{not json");
  const fallback = await readPlaylistState(file, 3);
  assert.equal(fallback.index, 0);
  assert.equal(fallback.muted, true);
});
