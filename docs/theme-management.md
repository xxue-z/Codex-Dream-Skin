# 本机主题管理 / Local theme management

## 使用入口

- macOS：菜单栏 → **主题**。背景透明度滑块和“跟随主题”作用于当前主题；**删除已保存主题…**列出本机主题。
- Windows：桌面／开始菜单 → **Codex Dream Skin**，或双击托盘图标。原生窗口提供当前主题透明度和已保存主题删除；切换、导入主题仍使用现有托盘。

透明度范围为 0–100%；0% 不透明，100% 全透明。只改变主题背景，文字和图标不随之变淡。优先级为用户按主题保存的设置 → 作者明确的 alpha → 默认 30%。点“跟随主题”清除当前主题的用户覆盖。主题包不会被改写。
Windows 托盘的“已保存主题”统一为平铺列表，直接点击主题名称即应用，不再为动态主题展开子菜单；勾选式“静音”和“暂停”统一放在顶层“动态主题”菜单，作用于当前活动主题。播放列表主题使用 `video-playlist.json`，Skin API 2 主题使用按主题保存的 `theme-video-preferences.json`，不会改写主题包或透明度偏好。MP4 默认静音；暂停会冻结当前帧，取消静音和恢复播放需要由托盘动作显式触发。

删除需确认主题名称，之后将该主题的本机保存目录移到系统废纸篓／回收站。正在使用的主题需先切换；导入或切换进行中时暂不删除。原始 ZIP、当前主题快照、恢复备份和社区发布记录保留。透明度偏好也保留，以便重新导入或恢复主题时继续使用。

## 默认主题：本地视频与海报

内置默认主题（`videoPlaylist.enabled = true`）在本机固定目录读取视频：

- Windows：`%LOCALAPPDATA%\CodexDreamSkin\videos\`
- macOS：`~/Library/Application Support/CodexDreamSkinStudio/videos/`

按文件名自然顺序循环、硬切、默认静音，并记住当前段与播放位置。视频通过 CDP 隐藏文件输入得到磁盘背书的 `File`，再转成 `blob:` URL；不读取进内存、不上传、不新增监听端口。

所有已保存主题都在“已保存主题”里平铺展示，直接点击主题名称即应用。托盘/菜单栏另有顶层 **动态主题**，集中提供当前活动动态主题的静音/暂停、当前文件夹、自动发现新视频、检测间隔（1/2/5/10/30 秒）、更改视频文件夹、恢复默认文件夹、遮罩透明度滑块，以及更换海报…、恢复默认海报、打开视频文件夹、重新扫描视频。当前主题不是动态主题时，静音/暂停显示为不可用。海报覆盖路径为 `...\poster.jpeg`，替换后 1–2 秒内热重载；无效文件保留上一张，删除后回退内置海报。

视频设置保存在独立的 `video-settings.json`（`schemaVersion: 1`），不会改写主题包或 `video-playlist.json`。自动发现关闭后只在点击“重新扫描视频”时刷新；自定义文件夹必须存在、不是网络路径且不含链接，切换后立即生效并从头播放。遮罩透明度 0% 对应原“强遮罩”、100% 对应原“软遮罩”，因此升级后默认视觉不变。


## English

On macOS, open the menu bar **Theme** menu for background transparency and
**Delete saved theme…**. On Windows, open **Codex Dream Skin** from the desktop or Start Menu, or double-click
the tray icon. The existing tray still handles imports and theme
switching.

Transparency ranges from 0% (opaque) to 100% (transparent). Per-theme local
settings take priority over authored alpha; otherwise the default is 30%.
**Follow theme** clears the current theme's override. Text, icons and source
packages remain unchanged.

The Windows tray lists every saved theme directly under **Saved themes**; clicking a theme name applies it, with no per-theme submenu. The checkable **Mute** and **Pause** items now live in the top-level **Dynamic themes** menu and act on the active theme. The playlist theme uses `video-playlist.json`, while Skin API 2 themes use their per-theme `theme-video-preferences.json`; neither rewrites the theme package or transparency preferences. MP4s start muted; pausing freezes the current frame, while unmuting and resuming playback require an explicit tray action.

Deleting requires confirmation and moves only the selected saved theme directory
to Trash or Recycle Bin. Switch away from the current theme before deleting it.
Source ZIPs, active snapshots, recovery backups, community publications and
per-theme preferences are retained. Restore the directory from Trash or Recycle
Bin to undo deletion.

## Default theme: local playlist and poster

The bundled default theme (`videoPlaylist.enabled = true`) reads videos from a fixed local folder:

- Windows: `%LOCALAPPDATA%\CodexDreamSkin\videos\`
- macOS: `~/Library/Application Support/CodexDreamSkinStudio/videos/`

Files play in natural filename order, loop with hard cuts, start muted, and resume from the last position. The renderer receives disk-backed `File` objects through a hidden CDP file input and turns them into `blob:` URLs; nothing is read into memory, uploaded, or exposed on a listening port.

Every saved theme is a direct, clickable item under Saved themes. A separate top-level **Dynamic themes** menu holds Mute/Pause for the active dynamic theme, the current folder, auto-detect, the 1/2/5/10/30-second check interval, change/restore videos folder, the scrim transparency slider, and Change poster…, Restore default poster, Open videos folder and Rescan videos. Mute/Pause are disabled when the active theme has no dynamic background. Replace `.../poster.jpeg` to hot-reload the poster within 1–2 seconds; invalid files keep the last good poster and deleting the override restores the bundled one.

Video settings live in `video-settings.json` (`schemaVersion: 1`) and never rewrite the theme package or `video-playlist.json`. With auto-detect off, files are picked up only by Rescan videos. A custom folder must exist, must not be a network path, and must not contain links; switching applies immediately and restarts the playlist from the first file. 0% scrim matches the former strong anchors and 100% the former soft anchors, so an upgrade keeps the current look.


## Candidate acceptance / 候选版本验收

Use the candidate commit's CI Setup/DMG artifacts. Confirm the installed app and
engine come from the same candidate; a matching version number alone is not enough.

1. Launch the Windows desktop and Start Menu shortcuts, then double-click the tray.
   All must open the same native manager; repeated clicks restore its existing window.
   Confirm no PowerShell theme-selection window appears. Verify it opens without an installed
   .NET runtime. Check Chinese/English, keyboard focus and 100%/150% display scaling.
2. With Codex visible, drag transparency to 0%, a middle value, and 100%; verify
   only backgrounds change. Switch away and back, restart the manager, and verify
   the per-theme setting remains. Use Follow theme on authored-alpha and legacy
   themes; expect the authored value or 30%, respectively.
3. Import a disposable test theme. Cancel deletion: files and list entry remain.
   Confirm deletion: it disappears from saved themes and appears in the OS Trash
   or Recycle Bin. Restore it and reopen the menu/window: it is available again.
4. Try deleting the current theme, including when it becomes current while the
   confirmation is open. It must remain. Check concurrent import/switch handling
   and that a failed recycle operation does not report success.
5. Verify the original ZIP, active theme, recovery files and unrelated saved
   themes remain. On Windows, verify the installed shortcut after an upgrade and
   that normal uninstall still retains saved themes.

Windows core and native integration commands are in
[the native manager README](../windows/theme-manager/README.md). The normal macOS
Swift test target includes deletion cases; CI also builds both platform artifacts.
