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
const posterA = path.join(projectRoot, "windows", "assets", "dream-reference.jpg");
const posterB = path.join(projectRoot, "docs", "images", "presets", "arina-hashimoto-light.jpg");

async function makeTheme({ playlist = true, id = "preset-arina-hashimoto" } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-default-theme-"));
  await fs.copyFile(posterA, path.join(dir, "dream-reference.jpg"));
  await fs.writeFile(path.join(dir, "theme.css"), '[data-ds-part="composer"] { border-radius: 24px; }\n');
  const theme = { schemaVersion: 1, id, name: "Test", image: "dream-reference.jpg" };
  if (playlist) theme.videoPlaylist = { enabled: true };
  await fs.writeFile(path.join(dir, "theme.json"), JSON.stringify(theme, null, 2) + "\n");
  const videos = path.join(dir, "videos");
  await fs.mkdir(videos);
  await fs.writeFile(path.join(videos, "2.webm"), Buffer.from([1]));
  await fs.writeFile(path.join(videos, "10.mp4"), Buffer.from([1]));
  await fs.writeFile(path.join(videos, "1.mp4"), Buffer.from([1]));
  await fs.writeFile(path.join(videos, "ignored.txt"), Buffer.from([1]));
  return { dir, videos, posterPath: path.join(dir, "override.jpeg") };
}

test("both injectors expose the default-theme playlist in payload checks", async () => {
  const winFixture = await makeTheme({ id: "preset-arina-hashimoto" });
  const macFixture = await makeTheme({ id: "preset-gothic-void-crusade" });
  for (const [name, api, fixture] of [
    ["windows", windows, winFixture],
    ["macos", macos, macFixture],
  ]) {
    const options = { videoDir: fixture.videos, posterPath: fixture.posterPath };
    const loaded = api === windows
      ? await windows.loadPayload(fixture.dir, null, options)
      : await macos.loadPayload(fixture.dir, {}, options);
    assert.equal(loaded.theme.videoPlaylist.enabled, true, name);
    assert.equal(loaded.playlist.scan.count, 3, name);
    assert.deepEqual(loaded.playlist.scan.entries.map((entry) => entry.name),
      ["1.mp4", "2.webm", "10.mp4"], name);
    assert.equal(loaded.posterOverride, false, name);
  }
});

test("a valid local poster override wins for playlist themes", async () => {
  const winFixture = await makeTheme({ id: "preset-arina-hashimoto" });
  const macFixture = await makeTheme({ id: "preset-gothic-void-crusade" });
  await fs.copyFile(posterB, winFixture.posterPath);
  await fs.copyFile(posterB, macFixture.posterPath);
  for (const [name, api, fixture] of [
    ["windows", windows, winFixture],
    ["macos", macos, macFixture],
  ]) {
    const baseLoaded = api === windows
      ? await windows.loadPayload(fixture.dir, null, { videoDir: fixture.videos })
      : await macos.loadPayload(fixture.dir, {}, { videoDir: fixture.videos });
    const loaded = api === windows
      ? await windows.loadPayload(fixture.dir, null, { videoDir: fixture.videos, posterPath: fixture.posterPath })
      : await macos.loadPayload(fixture.dir, {}, { videoDir: fixture.videos, posterPath: fixture.posterPath });
    assert.equal(loaded.posterOverride, true, name);
    if (typeof loaded.imageBytes === "number") {
      assert.notEqual(loaded.imageBytes, baseLoaded.imageBytes, name);
    } else {
      assert.notEqual(loaded.theme.artKey, baseLoaded.theme.artKey, name);
    }
  }
});

test("non-playlist themes ignore the local video folder", async () => {
  const fixture = await makeTheme({ playlist: false });
  const loaded = await windows.loadPayload(fixture.dir, null, {
    videoDir: fixture.videos, posterPath: fixture.posterPath,
  });
  assert.equal(loaded.playlist, null);
  assert.equal(loaded.theme.videoPlaylist, undefined);
});
