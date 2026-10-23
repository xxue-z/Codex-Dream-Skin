# MP4 动态背景设计草案

状态：**草案，未实现**。本文只定义契约、校验、渲染、性能与发布边界，不包含产品代码。
目标版本：客户端 `v1.6.0`，主题契约 `Skin API 2`。
最后更新：2026-10-23。
相关文档：`docs/compat-profile-design.md`、`docs/theme-management.md`、`AGENTS.md`。

## 0. 结论

可以支持，但不能把 MP4 当成"多一张背景图"塞进现有管线。

需要同时做三件事：

1. **契约升级**：`theme.json` 升到 `schemaVersion: 2`，`manifest.json` 升到 `skinApiVersion: 2`，新增可选能力 `video`；静态海报图仍然是必填项，视频只是叠加层。
2. **有界校验**：新增一个只读 MP4 结构解析器，限制容器、轨道、编码、分辨率、时长、体积和元数据；不引入 ffmpeg，不做转码。
3. **独立传输通道**：视频字节不能拼进 `renderer-inject.js` 的模板字面量，否则会产生 20 MB 级别的 JS 源码。改为在主注入完成后，用一次 `Runtime.callFunctionOn` 把 base64 作为参数传给页面，页面内组装 `Blob` 并播放。

首版建议上限：**H.264 / 8-bit / 无音轨 / 非分片 MP4 / 1920x1080 / 2-20 秒 / 16 MiB**。
静态海报继续沿用现有 10 MiB 图片上限，主题 ZIP 仍控制在现有 32 MiB 归档上限内。

## 1. 现状与约束

| 事实 | 位置 |
| --- | --- |
| `theme.json` 使用严格字段集，`schemaVersion` 只接受 `1` | `runtime/theme-package-validator.mjs` `validateOfficialTheme()` |
| 背景必须恰好是一张 `background.webp` / `background.jpg` / `background.png` | 同上 `BACKGROUND_MEDIA`、`validateManifest()` |
| 单张图片上限 10 MiB，并做扩展名、魔数、解码、尺寸校验 | 同上 `LIMITS.image`、`detectImageMedia()` |
| 图片被转成 `data:image/...;base64,...` 字符串，拼进注入模板的 `__DREAM_SKIN_ART_JSON__` | `windows/scripts/injector.mjs` `loadPayload()`、`macos/scripts/injector.mjs` |
| 渲染层把 data URL 还原成 `Blob` + `URL.createObjectURL`，写入 CSS 变量 `--dream-skin-art` | `runtime/renderer-inject.js` 开头的 `artUrl` 初始化与 `setStyleProperty(root, "--dream-skin-art", ...)` |
| 壁纸由 `main::before` 的 `background-image` 绘制；宽图模式改由 `body` 的 `background-image` 绘制 | `runtime/dream-skin.css` 中 `__DREAM_SELECTOR_SHELL_MAIN__::before` 与 `[data-dream-art-wide="true"] body` 规则 |
| Safe CSS 白名单没有 `animation` / `@keyframes`，只有过渡属性 | `runtime/safe-css-policy.json` |
| ZIP 归档上限 32 MB，已有路径穿越、链接、嵌套归档、压缩炸弹检查 | `macos/scripts/extract-theme-zip-macos.sh`、`windows/scripts/theme-windows.ps1` |

直接后果：

- MP4 不能作为 CSS `background-image` 播放，必须使用 `<video>` 元素或 Canvas，Canvas 会带来逐帧解码和绘制成本，首版不选。
- 现有 data URL 管线技术上可以把一小段视频塞进 `<video src="data:video/mp4;base64,...">`，但视频一旦到 16 MiB，注入脚本会膨胀到 21 MB 以上，且每次页面重载都要重新解析一遍巨大的 JS 字面量，不可接受。
- 现有主题契约是 fail closed 的严格字段集，任何新增字段都会让旧客户端明确拒绝，这是好事：不会出现旧客户端加载到一半、只显示海报却不知道视频被忽略的"半支持"状态。

## 2. 目标与非目标

### 2.1 目标

- 一个主题包可以携带**一段**短视频作为窗口壁纸，静音、循环、自动播放。
- 视频与静态海报使用同一套构图参数：`art.focusX`、`art.focusY`、`art.safeArea`、`art.taskMode`，切换静态/动态时裁切位置不跳变。
- 视频不可用时（编码不支持、自动播放被拒、用户关闭、系统减少动态效果）**无缝回落到海报**，不出现黑屏。
- 旧主题包行为完全不变；旧客户端遇到新主题包时给出明确错误，而不是静默降级。
- 不新增网络请求、不新增监听端口、不引入外部可执行文件。
- 导入失败必须给出稳定错误码和可读文案，日志不泄露本机路径。

### 2.2 非目标

- 不做音轨、音量、播放/暂停控件、进度条、拖动预览。
- 不做多视频、播放列表、按页面切换视频、在线视频 URL。
- 不做 GIF / APNG / 动画 WebP 的正式支持。
- 不做转码、压缩、裁剪、抽帧。作者必须自己提供合规 MP4。
- 不保证 HDR、10-bit、4:4:4、HEVC、AV1；首版只承诺 H.264 8-bit 4:2:0。
- 视频只作用于窗口壁纸与首页 hero 背景，不进入消息卡片、代码块、工具栏等内嵌表面。
- 不改变现有透明度语义：透明度仍然通过表面 alpha 让壁纸透出，不额外给视频加一层淡出。

### 2.3 成功标准

- 同一主题分别用静态海报和视频时，`focusX/focusY/taskMode` 的视觉效果一致，肉眼看不到构图位移。
- 冷启动、切换主题、窗口隐藏/恢复、应用重启四条路径都不黑屏、不重复播放、不泄漏 Blob URL。
- `--check-payload` 在双端都能在不连接 CDP 的情况下完成视频结构校验。
- 旧版 1.5.x 主题在新客户端上逐字节保持原行为。
- 16 MiB 视频在参考机器上的附加上限：首帧 ≤ 1.2 s，页面隐藏后解码停止，可见空闲 CPU ≤ 单核 4%。

## 3. 契约设计

### 3.1 `theme.json` v2

```json
{
  "schemaVersion": 2,
  "id": "studio.example-night",
  "name": "Example Night",
  "image": "background.jpg",
  "video": {
    "file": "background.mp4"
  },
  "art": {
    "focusX": 0.62,
    "focusY": 0.5,
    "safeArea": "left",
    "taskMode": "ambient"
  },
  "colors": {
    "background": "#071116",
    "panel": "#0d1a20",
    "panelAlt": "#12242c",
    "accent": "#5fd0a8",
    "accentAlt": "#9be37a",
    "secondary": "#67b7d8",
    "highlight": "#b39ddb",
    "text": "#eef7f4",
    "muted": "#9db3ad",
    "line": "#2b3f46"
  }
}
```

字段规则：

| 字段 | 必填 | 规则 |
| --- | --- | --- |
| `schemaVersion` | 是 | 必须为 `2`；`1` 仍由旧规则处理 |
| `image` | 是 | 固定为 `background.webp` / `background.jpg` / `background.png`，作为**海报帧** |
| `video` | 否 | 对象，唯一允许字段 `file`；值必须为 `background.mp4` |
| `art` | 否 | 与 v1 相同，同时作用于海报和视频 |
| 其他 v1 字段 | 否 | `name`、`colors`、文案字段、`appearance`、`promoUrl` 保持原语义 |
| 未知字段 | - | 继续拒绝 |

设计取舍：**海报必填**。它承担四个职责：视频加载前的占位、解码失败的回退、减少动态效果时的替代、旧客户端/Studio 的兼容预览。作者应从视频首帧导出海报，避免切换时闪一帧。

不建议增加 `loop`、`muted`、`autoplay`、`objectFit` 等字段。壁纸语义下这些值只有一种合理选择，增加字段只会扩大校验面。未来确有需求时再以可选字段做小版本扩展。

### 3.2 `manifest.json` v2

```json
{
  "packageVersion": 1,
  "skinApiVersion": 2,
  "themeId": "studio.example-night",
  "version": "1.0.0",
  "minClientVersion": "1.6.0",
  "platforms": ["macos", "windows"],
  "capabilities": ["background", "video", "tokens", "safe-css"],
  "publisher": {
    "id": "studio",
    "displayName": "DreamSkin Studio"
  },
  "license": "LicenseRef-Proprietary",
  "files": [
    { "name": "theme.json", "bytes": 1234, "sha256": "..." },
    { "name": "background.jpg", "bytes": 123456, "sha256": "..." },
    { "name": "background.mp4", "bytes": 12345678, "sha256": "..." },
    { "name": "theme.css", "bytes": 2345, "sha256": "..." }
  ],
  "createdAt": "2026-10-23T00:00:00Z"
}
```

规则：

| 项 | 规则 |
| --- | --- |
| `packageVersion` | 仍为 `1`；打包信封没有变化，变化的是 Skin API |
| `skinApiVersion` | `1` 或 `2`；`2` 必须搭配 `theme.json.schemaVersion: 2` |
| `capabilities` | 允许集合扩为 `background`、`video`、`tokens`、`safe-css`；有 `video` 字段时必须声明 `video`，没有时必须不声明 |
| `files` | API 2 允许且只允许零或一个 `background.mp4`；仍要求恰好一张海报图 |
| `minClientVersion` | API 2 主题必须 ≥ `1.6.0`；客户端仍按现有逻辑拒绝过低版本 |
| 哈希 | 视频与其他文件一样校验 `bytes` + `sha256`；导入后再算一次内容指纹 |

### 3.3 ZIP 布局与限额

沿用"扁平根目录 + 固定文件名 + 精确文件集合"的规则：

```
theme.json
theme.css
manifest.json
background.jpg        # 海报，必填
background.mp4        # 可选，最多一个
LICENSE.txt           # 可选
manifest.sig          # 可选
```

| 项 | 上限 |
| --- | --- |
| 归档文件 | 32 MiB（沿用现状） |
| 解压后总量 | 32 MiB（新增显式上限） |
| 条目数 | 8（现有文件集合最多 6 个，留出余量） |
| 海报 | 10 MiB（沿用） |
| 视频 | 16 MiB |
| 视频时长 | 2-20 秒 |
| 视频分辨率 | 640x360 至 1920x1080，像素数 ≤ 2,073,600 |
| 画面宽高比 | 1.2-2.4（横屏壁纸；拒绝竖屏和超宽电影比例） |

海报 10 MiB + 视频 16 MiB + JSON/CSS/许可证合计 < 27 MiB，仍在 32 MiB 归档上限内，不需要为了视频放宽归档上限。

ZIP 内视频允许 store 或 deflate；MP4 本身几乎不可压缩，压缩方法不作为校验条件，但不允许出现第二个 `background.mp4`、大小写变体或路径前缀变体。

### 3.4 兼容矩阵

| 主题包 | 1.5.x 客户端 | 1.6.x 客户端 |
| --- | --- | --- |
| API 1 + 静态图 | 正常 | 正常，行为不变 |
| API 2 + 静态图（无 `video`） | 拒绝：不支持的 Skin API 2 | 正常 |
| API 2 + 视频 | 拒绝：不支持的 Skin API 2 | 播放；失败时回落海报 |
| API 2 + `minClientVersion` 高于当前 | 拒绝 | 拒绝并提示升级 |

补充：

- API 2 不要求主题必须有视频；作者可以先升级契约、继续发静态主题。
- 社区站点、Studio 和服务端校验必须与客户端同步升级。站点未升级前，API 2 包应在上传阶段被拒绝，而不是让用户下载后在客户端失败。
- Studio 可以提供"导出 1.5 兼容包"：丢弃视频、保留海报、输出 API 1。这是可选功能，不进入首版门槛。

## 4. MP4 校验规范

### 4.1 允许的容器与编码

| 维度 | 允许 | 拒绝 |
| --- | --- | --- |
| 容器 | ISO BMFF / MP4（`ftyp` 主品牌 `isom`、`mp42`、`M4V `） | QuickTime `qt  `、HEIF、WebM、裸 H.264 流 |
| 分片 | 单文件、非分片、`moov` 在 `mdat` 之前（faststart） | `moof` / `mfra` / 分片 MP4 |
| 轨道 | 恰好 1 条 `vide` 轨 | 0 条或多条视频轨；任何 `soun` / `subtit` / `text` / `meta` 轨 |
| 样本格式 | `avc1` | `avc3`、`hev1`、`hvc1`、`vp09`、`av01`、`encv` |
| Profile | H.264 Baseline / Main / High（`profile_idc` 66 / 77 / 100） | High 10、High 4:2:2、High 4:4:4 等 10-bit / 高位深 |
| 像素格式 | 8-bit 4:2:0 | 10-bit、4:2:2、4:4:4 |
| 音频 | 无音轨 | 任意音轨（包括静音音轨） |
| 元数据 | 普通 `udta` / `ilst` 允许 | 含 GPS 的 `©xyz` / `©loc` |

"无音轨"是硬性要求：静音自动播放是浏览器的稳定路径，带音轨会触发自动播放策略，也会让用户在换肤时意外听到声音。

### 4.2 有界解析器

新增 `runtime/mp4-metadata.mjs`，只做结构解析，不解码：

1. 读取文件头，校验 `ftyp`，记录主品牌与兼容品牌。
2. 遍历顶层 box，最多 4096 个，深度最多 4 层；每个 box 的 `size` 必须在文件范围内，拒绝 64 位长度溢出。
3. 要求 `moov` 在前 2 MiB 内完整出现；超出即拒绝。这个上限足以覆盖 1080p/20 秒的正常 faststart 文件，同时把解析成本钉死。
4. 解析 `mvhd` 的 `timescale` / `duration`，计算总时长。
5. 解析每条 `trak` 的 `tkhd`（按 version 0/1 处理偏移）、`mdia/hdlr` 的 handler、`mdia/minf/stbl/stsd` 的样本格式。
6. 对 `avc1` 读取 `avcC` 的 `profile_idc`、`profile_compatibility`、`level_idc`，拒绝高位深 profile。
7. 用 `tkhd` 宽高和 `stsd` 视频样本入口宽高交叉校验，任何不一致或为 0 都拒绝。
8. 扫描 `udta` 下的 GPS box；命中即拒绝。
9. 输出一份不可变元数据：`{ width, height, durationMs, codec, profile, tracks, brand }`，供校验器、导入器和诊断使用。

安全约束：

- 所有读取都有边界检查，不按 box 声明的长度预分配内存。
- 只读前 2 MiB，绝不把 16 MiB 文件整体读进解析器。
- 不调用系统播放器、不调用 ffprobe、不执行文件内任何字符串。
- 解析器只返回错误码，不把文件路径、原始字节或元数据字符串写进日志。

### 4.3 稳定错误码

| 错误码 | 含义 |
| --- | --- |
| `video.missing` | `theme.json` 声明了视频但文件不存在 |
| `video.unexpected` | 文件存在但 `theme.json` 未声明，或出现在 API 1 包里 |
| `video.size` | 超过 16 MiB |
| `video.ftyp` | 不是允许的 MP4 品牌 |
| `video.fragmented` | 分片 MP4 |
| `video.moov` | `moov` 缺失、位置过深或在 2 MiB 之外 |
| `video.track_count` | 视频轨数量不为 1 |
| `video.audio_track` | 存在音轨 |
| `video.extra_track` | 存在字幕、文本或数据轨 |
| `video.codec` | 样本格式不是 `avc1` |
| `video.profile` | 非 8-bit Baseline/Main/High |
| `video.dimensions` | 宽高为 0、超过 1920x1080 或像素数超限 |
| `video.aspect` | 宽高比不在 1.2-2.4 |
| `video.duration` | 不在 2-20 秒 |
| `video.encrypted` | 加密样本入口 |
| `video.metadata_location` | 含 GPS 元数据 |
| `video.hash_mismatch` | 清单哈希不符 |
| `video.parse` | 其他结构性错误（截断、box 越界等） |

错误码对外稳定，可本地化文案；诊断日志只记录错误码、文件大小和阶段。

### 4.4 推荐编码参数

给作者和 Studio 的推荐命令（不作为客户端依赖）：

```bash
ffmpeg -i input.mov \
  -an \
  -vf "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,fps=30" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -crf 23 -maxrate 6M -bufsize 12M \
  -movflags +faststart -t 20 \
  background.mp4
```

要求：

- `-an` 去掉音轨。
- `-pix_fmt yuv420p` 保证 8-bit 4:2:0。
- `-movflags +faststart` 把 `moov` 放到文件头。
- 20 秒、6 Mbps 上限，16 MiB 内基本能保证画质。
- 海报从首帧导出，分辨率与视频一致，保持同一构图。

## 5. 运行时渲染

### 5.1 传输通道

**决策：主注入脚本只携带海报，视频走独立的 `Runtime.callFunctionOn` 调用。**

流程：

1. 注入器在 Node 侧读取 `background.mp4`，计算 `videoKey = sha256(bytes).slice(0, 20)`。
2. 主 payload 与现在一致，只替换 CSS、主题 JSON、海报 data URL；新增 `__DREAM_SKIN_VIDEO_META_JSON__`，只放 `{ key, mime, bytes }`，不放字节。
3. 主注入完成后，注入器拿到 `window` 的 `objectId`，调用：

   ```js
   Runtime.callFunctionOn({
     objectId,
     functionDeclaration: "function (base64, meta) { return window.__dreamSkinAttachVideo(base64, meta); }",
     arguments: [{ value: base64 }, { value: meta }],
     awaitPromise: true,
     returnByValue: true
   })
   ```

   视频字节作为 JSON 参数传输，不参与 JS 源码解析，也不受模板占位符替换影响。

4. 页面内 `__dreamSkinAttachVideo()`：

   - 如果 `state.videoKey === meta.key` 且节点仍存在，直接返回 `{ reused: true }`，避免重载时重启播放。
   - `atob` 分块转 `Uint8Array`，或 `fetch(dataUrl)` 异步转 `Blob`；优先 `fetch`，避免主线程长时间 `atob`。
   - `URL.createObjectURL(blob)`，创建 `<video>`，等待 `loadeddata` / `readyState >= 2`。
   - 成功后淡入，撤销旧 URL，写入 `state.videoKey`。
   - 失败返回 `{ fallback: true, code }`，保留海报。

5. `--check-payload` 只做结构校验，不连接 CDP、不发送字节。

**为什么要拆开**：把 16 MiB 视频 base64 拼进模板，会生成 21 MB 以上的 JS 源码。V8 需要解析这个字面量，PowerShell 侧虽然只读摘要，但 `--watch` 每次重注入都要重复付出解析成本。`callFunctionOn` 的参数是 CDP 消息里的 JSON 字符串，成本主要在传输和 `atob`，可控且可测量。

**分块阈值**：如果 Phase 0 测得 16 MiB 单次调用 p95 > 800 ms，或 CDP 消息在某个平台被截断，则改为 4 MiB 一块的 `__dreamSkinAppendVideoChunk()` 追加，最后统一组装。分块是性能回退方案，不进入首版默认路径。

**不选本机 HTTP 服务**：localhost 媒体服务能支持 Range、降低内存，但会给一个换肤工具新增入站监听面和端口管理问题。首版不引入；如果未来要支持 1080p/60 秒级别，再单独评估。

### 5.2 图层挂载

视频必须复用海报的几何语义，而不是另起一套布局。

**挂载点选择**。每个 document 同时只存在一个视频节点；首页与任务页互斥，路由切换时移动或重建节点：

| 场景 | 挂载点 | 现有海报来源 |
| --- | --- | --- |
| 任务页，非宽图 | `main` 表面内 | `main::before` |
| 首页，非宽图 | 首页 hero 卡内 | hero 卡的 `background-image` |
| 任意页面，宽图 | `body` 固定层 | `body` 背景 + hero 卡背景 |

**任务页，非宽图**：

- 在主表面元素（`data-ds-part="main"` 的容器）内插入一个 `div[data-ds-video-layer]`，作为第一个子节点。
- 该容器：`position: absolute; inset: 0; z-index: -1; overflow: hidden; pointer-events: none;`。
- 主表面本身已经 `position: relative; isolation: isolate; overflow: hidden`，因此负 z-index 子层会画在表面背景之上、正文内容之下，不需要改正文层级。
- `video`：`width: 100%; height: 100%; object-fit: cover; object-position: var(--ds-art-position);`。
- 需要缩放时，在外层容器上用 `transform: scale(var(--ds-theme-image-zoom, 1))`，与静态图的 `background-size: cover` 视觉对齐。

**首页，非宽图**：

- 首页 hero 卡目前直接设置 `background-image: var(--dream-skin-art)`，且卡片本身是 `overflow: visible`。
- 在 hero 卡内插入 `div[data-ds-video-layer]`：`position: absolute; inset: 0; z-index: 0; overflow: hidden; border-radius: inherit; pointer-events: none;`。
- 不要直接把 hero 卡改成 `overflow: hidden`，否则可能裁掉角标或浮层；用内层裁切。
- 卡片内正文已有自己的层级规则，保持不变；视频层位于卡片底色与正文之间。
- 同时把 hero 卡的 `background-image` 设为 `none`，保留 `background-color` 作为兜底。

**任意页面，宽图**：

- 在 `body` 下插入固定层：`position: fixed; inset: 0; z-index: -1; pointer-events: none;`。
- 同时把 `body` 的 `background-image` 设为 `none`，保留 `background-color` 作为兜底。
- 首页 hero 卡的 `background-image` 也要让位；卡片 `background-color` 需要变为透明或半透明，让固定视频层透出。
- 侧栏与主表面的半透明渐变规则保持不变；视频只替换"壁纸"这一层。
- 这是视觉差异最大的分支，Phase 0 必须用真实首页、任务页和超宽屏做截图对比，确认卡片边框、圆角和文字可读性。

**遮罩与海报**：

- `main::before` 继续负责 `--ds-task-fade`、`--ds-task-shade` 等可读性遮罩。
- 视频就绪前，`main::before` 保留海报层；视频 `loadeddata` 后给 `html` 加 `data-dream-video="ready"`，CSS 只移除海报那一层，遮罩保留。
- 视频失败或暂停时移除 `data-dream-video`，海报立即回来。
- 视频层不接收指针事件，`aria-hidden="true"`，不进入 Tab 顺序。

**taskMode**：

- `off`：任务页不显示视频与海报（现有 `main::before` 已经是 `content: none`）；首页 hero 仍按现有规则显示，视频照常播放，因为 `taskMode` 只约束任务页。
- `ambient` / `full`：按现有规则显示；视频层跟随同一属性。
- 首页与任务页切换时，先暂停并移除当前挂载点，再在新挂载点重建；不要在两个路由同时保留视频节点，避免重复解码。
- 如果 `art` 层被 CSS 隐藏，视频层必须使用同一条件隐藏并暂停，不能只在视觉上盖住。

**亮暗模式**：

- 海报层在暗色下 `opacity: .78`，亮色下 `.72`。视频层必须使用同一个计算后的不透明度变量，避免切换静态/动态时亮度跳变。
- 建议抽出 `--ds-art-layer-opacity`，海报和视频共用；不要复制两份魔数。

### 5.3 播放生命周期

创建属性：

```html
<video
  muted
  playsinline
  loop
  autoplay
  preload="auto"
  disablepictureinpicture
  disableremoteplayback
  aria-hidden="true"
></video>
```

- **自动播放**：静音 + `playsinline` 是 Chromium 的稳定自动播放路径。`play()` 返回的 Promise 必须捕获；被拒绝就回落海报，不重试轰炸。
- **可见性**：`document.visibilityState === "hidden"` 时 `pause()`；恢复可见且用户开启时再 `play()`。窗口失焦但可见不暂停。
- **减少动态效果**：`matchMedia("(prefers-reduced-motion: reduce)")` 命中时不创建视频，只显示海报。监听变化，用户中途切换系统设置时同步。
- **用户开关**：主题偏好新增全局 `videoBackground`（默认 `true`）。关闭时不创建视频，海报照常显示。
- **主题切换 / 重注入**：`cleanup()` 必须先 `pause()`、清 `src`、`load()`、移除节点、`URL.revokeObjectURL()`，再注入新主题。
- **错误**：`error` 事件只记一次稳定错误码（如 `video.decode`），移除视频节点，保留海报；不上报路径、不弹窗。
- **多窗口**：每个 CDP target 各自挂载；通常只有一个窗口。若检测到超过 3 个可见窗口，后续优化可以让非焦点窗口暂停，首版不做。

### 5.4 降级顺序

1. 用户关闭动态背景 → 海报。
2. 系统减少动态效果 → 海报。
3. 任务模式 `off` → 无壁纸。
4. 视频结构校验失败 → 导入阶段拒绝，不进入主题库。
5. 运行时解码失败 / 自动播放被拒 / CSP 拒绝 → 海报 + 一条诊断计数。
6. 视频尚未加载完成 → 海报。

任何情况下都不能出现黑屏、空白壁纸或控制台未捕获异常。

## 6. 安全与隐私

- **不新增网络面**：视频只从本机主题目录读取，经 base64 → Blob 进入渲染进程，不发请求、不开端口、不引用远程 URL。
- **不新增可执行面**：不调用 ffmpeg/ffprobe，不执行文件内容；MP4 只被当作字节和 box 结构。
- **不泄露路径**：页面只看到 `blob:` URL；错误码和日志不包含主题目录、用户名或文件路径。
- **不削弱 CSP**：如果 Codex 渲染进程的 CSP 不允许 `media-src blob:`，功能直接回落海报，不为播放视频去改 CSP 或注入 `--disable-web-security`。
- **不自动播放声音**：硬性拒绝音轨，`muted` 只是第二道保险。
- **不提供控件**：无 `controls`、无画中画、无远程播放，避免视频层拦截交互或被投屏。
- **路径与链接**：视频文件继续走现有的 realpath 包含检查、拒绝符号链接/junction/reparse point；硬链接按现有策略处理。
- **压缩炸弹**：归档大小、解压总量、条目数、重复路径、嵌套归档继续 fail closed；视频不能成为绕过入口。
- **模板注入**：视频字节不进入 JS 源码；主题 JSON 仍用 `JSON.stringify` + 函数替换，避免 `$&`/`$`` 类替换攻击。
- **元数据**：拒绝 GPS box；其余编码器字符串不展示、不执行。若未来需要彻底剥离元数据，应在服务端/Studio 预处理阶段做，客户端不做重写。

## 7. 性能预算

参考机器：一台 2023 年前后的 Windows 11 轻薄本 + 一台 Apple Silicon Mac；具体型号在 Phase 0 记录。

| 指标 | 预算 | 测量方式 |
| --- | --- | --- |
| MP4 结构校验 | p95 ≤ 150 ms（16 MiB） | Node 基准脚本，冷启动 20 次取 p95 |
| 主 payload 体积 | 与现状同量级（海报 base64 + 模板） | `--check-payload` 输出字节数 |
| 视频附加传输 | p95 ≤ 800 ms（16 MiB） | `Runtime.callFunctionOn` 前后时间差 |
| 海报首帧 | 相对现状不回退超过 5% | `Performance.getMetrics` / 人工录屏 |
| 视频首帧 | p95 ≤ 1.2 s | 从 attach 到 `loadeddata` |
| 页面隐藏后 | 解码暂停，CPU ≈ 0 | 任务管理器 / Activity Monitor |
| 可见空闲 | ≤ 单核 4%（1080p30） | 60 秒采样 |
| 渲染进程增量内存 | ≤ 150 MiB | DevTools Memory / `Performance.getMetrics` |
| 主题切换清理 | ≤ 100 ms | 从 cleanup 到新海报可见 |

如果 16 MiB 在低端机上超出预算，优先降级顺序：

1. 把上限降到 12 MiB（不改契约）。
2. 启用分块传输。
3. 再评估 localhost Range 服务，而不是放宽内存预算。

## 8. 改造清单

| 文件 / 区域 | 改动 |
| --- | --- |
| `runtime/theme-package-validator.mjs` | 接受 `skinApiVersion 1/2`；API 2 接受 `schemaVersion 2`；注册 `background.mp4`；校验能力与文件集合；调用 MP4 解析器 |
| `runtime/mp4-metadata.mjs`（新增） | 有界 MP4 box 解析、轨道/编码/尺寸/时长/GPS 检查、稳定错误码 |
| `runtime/mp4-metadata.test.mjs`（新增） | 结构解析单测；合成 box 树；边界与攻击样本 |
| `runtime/renderer-inject.js` | `__dreamSkinAttachVideo`、挂载点选择、播放生命周期、清理、诊断计数 |
| `runtime/dream-skin.css` | 视频层、海报/遮罩切换、亮暗透明度、`prefers-reduced-motion`、宽图 body 模式 |
| `runtime/theme-preferences.mjs` | 全局 `videoBackground` 与可选 per-theme `videoPaused`；保持 `schemaVersion 1`，未知字段兼容 |
| `windows/scripts/injector.mjs` | 读取视频、`videoKey`、revision 纳入视频哈希、`callFunctionOn` attach、`--check-payload` |
| `macos/scripts/injector.mjs` | 同上，保持双端逻辑一致 |
| `windows/scripts/theme-windows.ps1` | 导入校验、错误码文案、内容指纹、动态背景开关 UI |
| `windows/scripts/common-windows.ps1` | 主题元数据/路径检查扩展到视频文件 |
| `macos/scripts/import-theme-zip-macos.sh` | 允许 `background.mp4`、解压总量与条目上限 |
| `macos/scripts/extract-theme-zip-macos.sh` | 视频条目、大小写变体、重复路径、链接检查 |
| `macos/scripts/theme-config.mjs` / 菜单栏 | 动态背景开关、错误提示 |
| `tools/sync-runtime-assets.mjs` | 把新的 `mp4-metadata.mjs` 同步到双端 `assets/` |
| `tools/renderer-runtime.test.mjs` | 挂载、播放、暂停、清理、降级、宽图模式测试 |
| `macos/tests/theme-package-validator.test.mjs` | v1/v2 契约、错误码、边界用例 |
| `macos/tests/theme-import-publish.test.mjs` | 导入、指纹、重复导入、发布前置校验 |
| `windows/tests/theme-schema-contract.test.mjs` | 双端 schema 断言同步 |
| `windows/tests/payload-template-integrity.test.mjs` + macOS 同名测试 | 新增占位符、视频不进入模板、revision 包含视频哈希 |
| `README.md` / `README.zh-CN.md` / `AGENTS.md` | 主题契约、ZIP 说明、动态背景限制、编码建议 |
| `docs/releases/v1.6.0.md` / `-en.md` | 发布说明 |
| 六个版本位置 | `macos/VERSION`、`windows/VERSION`、`macos/package.json`、`macos/scripts/common-macos.sh`、`macos/scripts/injector.mjs`、`windows/scripts/injector.mjs` |

外部依赖（不在本仓库）：

- `dreamskin-cc` 服务端：统一校验器升级到 API 2，上传/审核/下载链路支持 16 MiB 视频。
- Studio：视频上传、结构预检、海报抽帧提示、API 2 导出、可选的 API 1 兼容导出。
- Gallery：卡片预览、视频体积/时长提示、CDN 缓存策略。

## 9. 测试矩阵

### 9.1 契约与解析器

必须覆盖：

1. API 1 旧主题：逐字节行为不变。
2. API 2 静态主题（无视频）：通过。
3. API 2 视频主题：双端通过。
4. `schemaVersion 2` 但缺 `video`：通过。
5. 声明视频但文件缺失 / 文件存在但未声明。
6. 两个视频、大小写变体、带路径前缀的重复条目。
7. API 1 包内出现 `background.mp4`。
8. 能力集合与视频不一致（有视频不声明、无视频声明）。
9. `bytes` / `sha256` 不符。
10. 16 MiB 边界：恰好通过，+1 字节拒绝。
11. 空文件、截断文件、随机字节改成 `.mp4`。
12. `ftyp` 错误、QuickTime、WebM、裸流。
13. `moov` 在 `mdat` 之后、`moov` 超出前 2 MiB、分片 `moof`。
14. box 长度溢出、嵌套过深、box 数量超限。
15. 0/2 条视频轨、音轨、字幕轨、数据轨。
16. `avc3` / `hev1` / `hvc1` / `vp09` / `av01` / `encv`。
17. High 10 / 4:2:2 / 4:4:4。
18. 分辨率 1920x1080 通过；1921 宽、3840x2160、0x0 拒绝。
19. 宽高比 1.2 / 2.4 通过；1.19 / 2.41 拒绝。
20. 时长 2.0 / 20.0 秒通过；1.99 / 20.01 秒拒绝。
21. GPS `©xyz` / `©loc` 拒绝。
22. ZIP 路径穿越、符号链接、junction、嵌套归档、压缩炸弹、重复导入、ID 冲突。
23. `minClientVersion` 低于 1.6.0 的 API 2 包拒绝。
24. 发布链路：站点/服务端未升级时 API 2 上传被明确拒绝。

测试数据策略：

- 单元测试用合成 box 树构造合法/非法结构，不提交大文件。
- 仓库只放一个 < 200 KB 的真实 H.264 短片，用于端到端播放 smoke；放 `tests/fixtures/` 并在 `.gitattributes` 标记二进制。
- 16 MiB 边界用稀疏文件或运行时生成，不入库。

### 9.2 渲染与生命周期

- 首次 attach 创建一个视频；相同 `videoKey` 二次 attach 复用，不重建、不重启。
- 不同 `videoKey` 替换时旧节点移除、旧 Blob URL 撤销。
- `loadeddata` 后海报层移除；`error` 后海报保留、视频移除。
- `prefers-reduced-motion` 命中：不创建视频；运行时切换：暂停/恢复正确。
- 偏好 `videoBackground: false`：不创建视频。
- `visibilitychange` hidden：暂停；visible：恢复（且只恢复一次）。
- `cleanup()`：无残留节点、无残留监听器、无未撤销 URL。
- 任务页非宽图挂到主表面，首页非宽图挂到 hero 卡，宽图挂到 `body`；三种挂载都不拦截点击。
- 路由从首页切到任务页（及反向）时只保留一个视频节点，旧节点已暂停并移除。
- `taskMode: off` 任务页不挂载；首页仍播放；`ambient` / `full` 正确显示。
- 亮暗模式透明度一致，静态/动态切换无亮度跳变。

### 9.3 双端与真实冒烟

- Windows 11 + macOS 14/15，各自使用候选安装包。
- 原生文件选择器导入 API 2 ZIP；切换主题；重启应用；隐藏/恢复窗口。
- 透明度 0% / 50% / 100%；亮/暗；首页/任务页；16:9 / 16:10 / 4:3 / 超宽。
- 用系统音量混合器/音频指示确认没有音频设备被激活。
- 任务管理器/Activity Monitor 采样 CPU、GPU、内存。
- 故意提供客户端不支持的编码，确认回落海报且只提示一次。
- 确认旧 API 1 主题、旧偏好文件、旧恢复备份不受影响。

## 10. 发布与灰度

- 目标版本 **v1.6.0**；按 `AGENTS.md` 同步六处版本号，并更新绑定当前版本的断言。
- 发布说明按 `docs/releases/README.md` 提供中文 `v1.6.0.md` 与完整英文 `v1.6.0-en.md`，顶部互链。
- 顺序建议：
  1. 客户端 1.6.0 先支持导入本地 API 2 包（社区站点仍拒绝 API 2 上传）。
  2. 服务端与 Studio 升级校验和导出。
  3. Gallery 开放 API 2 主题。
- 回滚：若出现系统性播放问题，发布 1.6.1 默认关闭视频挂载（`videoBackground` 默认 `false`），保留契约和已导入主题；不要回退已公开的 tag 或 Release。
- 远程 kill switch：如果 `docs/compat-profile-design.md` 的兼容档案先落地，可增加 `features.videoBackground: false`，让客户端不重装即可停播。首版不依赖它。

## 11. 风险与开放问题

| 风险 / 问题 | 影响 | 处理 |
| --- | --- | --- |
| Codex 渲染进程 CSP 不允许 `media-src blob:` | 视频无法播放 | Phase 0 在真实窗口用 1 秒测试片验证；失败则本方案不成立，改为仅海报或重新评估 |
| Codex 使用的 Electron 构建不含 H.264 解码 | 视频无法播放 | Phase 0 用真实 H.264 测试片验证；失败则改评估 VP9/AV1 或放弃 |
| 21 MB base64 单次 CDP 调用在低端机过慢 | 切换卡顿 | 分块传输；仍不达标则降到 12 MiB |
| 宽图模式挂载点与现有 `body` 背景规则冲突 | 构图错位/被遮挡 | Phase 0 在超宽屏抓真实 DOM；以 `data-dream-art-wide` 为唯一分支条件 |
| 多窗口重复解码 | CPU/GPU 翻倍 | 首版接受；记录窗口数，后续按焦点暂停 |
| 服务端/Studio 未同步 | 用户上传失败或格式不一致 | API 2 上传在服务端显式拒绝，先发客户端再开 Gallery |
| 用户误以为支持任意 MP4 | 导入失败体验差 | 导入错误文案给出编码建议；README/Studio 提供 ffmpeg 命令 |
| 旧客户端用户拿到 API 2 包 | 无法使用 | `minClientVersion` + 明确错误；Studio 可选导出 API 1 兼容包 |

Phase 0 必须先回答的三个问题：

1. `media-src blob:` 是否允许？
2. H.264 是否能解码？
3. 16 MiB 单次 `callFunctionOn` 在 Windows PowerShell 管理器与 macOS 菜单栏进程中是否稳定？

任何一个为否，都先调整方案，再写产品代码。

## 12. 实施拆分

| 阶段 | 内容 | 产出 | 规模 |
| --- | --- | --- | --- |
| P0 | 真实窗口探针：CSP、H.264、自动播放、挂载点、传输耗时 | `docs/mp4-video-background-spike.md` + 数据 | S |
| P1 | 契约、MP4 解析器、校验器、错误码、单测 | `runtime/mp4-metadata.mjs` + validator | M |
| P2 | 渲染层：attach、挂载、生命周期、CSS、运行时测试 | `renderer-inject.js` + `dream-skin.css` | M |
| P3 | Windows 导入、偏好、托盘开关、错误文案 | PowerShell + Node 测试 | M |
| P4 | macOS 导入、菜单栏开关、错误文案 | shell + Node/Swift 测试 | M |
| P5 | 文档、README、AGENTS 契约、发布说明 | 文档 | S |
| P6 | Studio/服务端/Gallery（外部仓库） | 服务端校验 + 导出 | M |
| P7 | v1.6.0 发布、双端冒烟、资产核对 | Release | S |

每个 PR 只改自己的写入范围；P1 合并前不接 UI，P2 合并前不出现在用户可见入口。P3/P4 必须复用同一份 `runtime/mp4-metadata.mjs`，禁止双端各写一套解析器。

## 13. 决策记录

| 编号 | 决策 | 理由 |
| --- | --- | --- |
| D1 | 只支持 H.264 8-bit 无音轨 MP4 | 兼容性最好、校验面最小、无自动播放声音问题 |
| D2 | 海报必填，视频可选 | 统一回退、加载占位、减少动态效果、旧生态预览 |
| D3 | Skin API 2，不兼容旧客户端 | 严格字段集下无法"半支持"；明确拒绝优于静默忽略 |
| D4 | 视频不走模板字面量，走 `callFunctionOn` 参数 | 避免 20 MB 级 JS 源码解析，降低重注入成本 |
| D5 | 首版不引入 localhost 媒体服务 | 不新增入站监听面；16 MiB 以内现有通道可控 |
| D6 | 视频层跟随海报的挂载分支与构图变量 | 静态/动态切换不跳变，减少 CSS 分叉 |
| D7 | 静音、循环、无控件、隐藏即暂停 | 壁纸语义；省电；不拦截交互 |
| D8 | 客户端不转码、不抽帧 | 不引入 ffmpeg 依赖与供应链风险；作者/Studio 预处理 |

## 附录 A：合法包最小示例

```
example-night/
  theme.json
  theme.css
  background.jpg
  background.mp4
  manifest.json
```

`theme.json`：

```json
{
  "schemaVersion": 2,
  "id": "studio.example-night",
  "name": "Example Night",
  "image": "background.jpg",
  "video": { "file": "background.mp4" }
}
```

`theme.css` 仍必须非空，并通过 `dreamskin-safe-css/1`。视频不改变 Safe CSS 的部件、状态、变量和属性白名单。

## 附录 B：解析器伪代码

```text
parseMp4(bytes):
  require bytes.length in [1, 16 MiB]
  require ftyp at offset 0; brand in {isom, mp42, M4V }
  scan top-level boxes up to 2 MiB:
    reject moof/mfra
    record moov, mdat order
  require moov before mdat and moov fully inside 2 MiB
  read mvhd -> timescale, duration
  for each trak:
    read tkhd -> width, height (version-aware offsets)
    read hdlr -> handler
    if handler != vide: reject (audio/subtitle/data)
    read stsd -> sample entry
    require sample entry == avc1
    read avcC -> profile_idc in {66, 77, 100}
  require exactly one vide track
  require 640<=w<=1920, 360<=h<=1080, w*h<=2073600
  require 1.2 <= w/h <= 2.4
  require 2s <= duration <= 20s
  reject GPS boxes in udta
  return { width, height, durationMs, codec: "avc1", profile }
```

## 附录 C：Phase 0 探针清单

在真实 Codex 窗口执行，不写入产品代码：

1. 读取页面 CSP（meta 或响应头），确认 `media-src` 是否包含 `blob:`。
2. 用 1 秒 H.264 测试片创建 `Blob` + `<video muted autoplay loop playsinline>`，确认 `canplay` 与 `play()` 成功。
3. 用 16 MiB 测试片走一次 `Runtime.callFunctionOn`，记录传输耗时、页面内存、首帧时间。
4. 分别验证非宽图主表面与宽图 `body` 两个挂载点的层级、裁切、遮罩和点击穿透。
5. 隐藏窗口 30 秒，确认 `visibilitychange` 触发暂停且 CPU 回落。
6. 打开系统"减少动态效果"，确认 `prefers-reduced-motion` 命中并只显示海报。
7. 记录 Windows 11 与 macOS 的机器型号、Codex 版本、Electron 版本、GPU。

探针结果写回本文档的"风险与开放问题"或单独 `docs/mp4-video-background-spike.md`，再决定是否进入 P1。


