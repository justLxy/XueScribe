# 雪笺 XueScribe

> Turn speech into text, quietly.

实时英文语音字幕与中文翻译工具。默认使用本地 Nemotron，也可选 AssemblyAI 云端实时识别；中文翻译始终使用本地 Hy-MT2。

## 核心功能

捕获英文语音（麦克风或 Mac 系统音频）→ 实时识别为英文字幕 → 智能断句 → 翻译为中文字幕

- 识别 Provider：默认使用 Nemotron 本地 Metal 推理；也可由用户填写自己的 AssemblyAI API Key 使用云端实时识别，仅选择 Cloud 时上传音频
- 实时字幕：边听边显示，悬浮窗支持置顶、穿透、透明度调节
- 稳定断句：结合真实更新中的稳定前缀、模型标点和 endpoint，避免按时间硬切
- 双语记录：自动保存完整的英中双语记录（JSONL + TXT）

## 使用的模型

| 组件 | 模型 | 量化 | 作用 |
|------|------|------|------|
| **ASR（语音识别）** | NVIDIA Nemotron English 0.6B | Q8_0 GGUF | 实时英文语音转文字，使用 NeMo-Speech.cpp cache-aware streaming API |
| **ASR（可选云端）** | AssemblyAI Universal-3.5 Pro | — | v3 WebSocket，`speech_model=universal-3-5-pro` |
| **翻译** | 腾讯 Hy-MT2-1.8B | Q4_K_M GGUF | 英译中，通过 llama.cpp 加载 |

App 不内置模型。首次点击“开始字幕”时，会从模型作者的官方 Hugging Face 仓库下载固定版本的两个 GGUF 文件（合计约 1.7 GB），校验 SHA-256 后保存在 `~/Library/Application Support/XueScribe/Models/`。以后直接复用，不会重复下载。云端识别仍需要网络和有效的 AssemblyAI 账户；中文翻译模型始终在本机下载并运行。

## 系统要求

- Apple Silicon Mac（M 系列芯片）
- macOS 14+
- 系统音频捕获通过 ScreenCaptureKit 实现（需用户授权）

## 使用方法

1. 双击 `XueScribe.app` 启动
2. 点击菜单栏图标 → 设置，选择 ASR Provider 与音频源（麦克风或系统音频）
3. 点击"开始字幕"
4. 使用快捷键 ⌥⌘S 显示/隐藏字幕窗口

### 工作台布局

悬浮窗为左右双栏：左侧实时转录（英文原文 + 中文翻译，自动跟随最新，上滚暂停并出现「回到最新」），右侧 AI 回答（英文在上、中文翻译在下，Short / Detailed、重新生成、复制、清除）。拖动中间分隔线调整宽度（默认 55% / 45%，双击恢复）；窗口窄于 640 pt 时自动改为上下堆叠，最小可缩到 360 × 400，工具栏会逐级收起为图标。工具栏右侧按钮可收起 AI 面板。AI 面板底部有输入框：可直接输入问题，或粘贴（⌘V）/ 拖入 / 选择图片（最多 6 张，自动缩到 1600 px），Return 发送、Shift-Return 换行；转录和参考资料作为背景一起发送。外观可在设置中选择跟随系统、浅色或深色；置顶、点击穿透、屏幕共享隐藏均保留在「…」菜单中。

### 显示模式

- **单句字幕**：保持最后一组完整双语字幕，适合类似传统字幕的体验
- **长段转录与翻译**（默认）：保留最近 50/100/300/1000 段历史记录，可向上滚动回看

### AI 回答助手（Gemini）

1. 设置 → 「AI 回答助手 · Gemini」：保存 Gemini API Key，添加简历、项目经历等参考资料（可查看 / 删除）。支持 Gemini 原生可读的格式：PDF、docx、xlsx/xls、pptx、odt、rtf、文本/Markdown/CSV/JSON/HTML/代码、图片、音频、视频，单个 ≤ 2 GB；旧版 .doc/.ppt 不支持
2. 资料添加后即在后台上传并预读进 Gemini 上下文缓存（cachedContents，1 小时有效、使用时自动续期；资料、Prompt 或模型变化时自动重建），点击时只发送转录。实测 3.6 万 token 资料：不缓存约 25 秒，缓存后 3.8 Flash 约 3–5 秒、3.5 Flash-Lite 约 2 秒（默认 Flash-Lite，设置中可切换为 3.8 Flash）
2b. 资料会提前通过 Gemini Files API 上传并复用引用；引用 48 小时过期前或失效时自动重新上传
3. 对话中对方提问后，点击悬浮窗控制栏的 ✨（或菜单栏「AI 回答」），`gemini-3.8-flash` 会结合最近约 6000 字符的转录与参考资料流式生成可直接说出口的回答
4. 回答区独立于字幕，支持 Short / Detailed、复制、重新生成（使用最新转录）；转录不受影响

5. 英文回答由 Gemini 在同一次回复中紧接着附上简体中文翻译（「【中文翻译】」之后的部分显示在英文下方）；中文回答不重复翻译。内置 Prompt 均为中文，可在设置中修改
6. 设置中可编写「自定义 Prompt」（作为额外指令，与 PDF、转录一起发送），也可修改或恢复「内置回答规则」

### 屏幕共享时隐藏

设置中「屏幕共享 / 截屏时隐藏窗口」默认开启，使用 macOS 原生 `NSWindow.sharingType = .none`，本机显示与操作不受影响。限制：是否生效取决于会议软件的采集方式，部分基于 ScreenCaptureKit 的采集（如 QuickTime）已知仍可能录到该窗口，无法保证 Zoom / Teams / Meet 共享整个屏幕时一定隐藏。最可靠的做法是只共享某个窗口或应用；首次使用前请用另一台设备入会确认。

Key 保存在 `~/Library/Application Support/XueScribe/Secrets/gemini.key`（权限 600），资料副本保存在 `Application Support/XueScribe/Knowledge/`。仅点击 ✨ 时才会把转录文本发送给 Gemini。

### 自定义术语表

设置页面可编辑术语表，格式为每行 `English = 中文`，用于专业词汇的翻译偏好。

## 技术细节

- **断句策略**：ASR 的 final 事件是音频分段边界，不等同于完整句子。使用真实 ASR 更新中的稳定前缀、模型标点和 endpoint 组合判断；无句末标点的 final 可跨段续接，并由统一等待预算兜底。不使用课程关键词或句型特例。本地 ASR 使用 560 ms 前瞻与 2 秒句末停顿判定（800 ms 会在犹豫停顿处断开、补出假句号并在重置时丢词）；逗号兜底切分至少 8 词、等待 4 秒；不足 3 词、以句号结尾的短句（如 "Um." "So."）并入下一句，问句与感叹句始终独立
- **流式处理**：ASR 使用真正的 cache-aware streaming API，持续接收 20ms PCM 帧；翻译仅处理稳定片段
- **Metal 加速**：本地 ASR 和翻译模型使用 Metal GPU 加速

## 构建

```bash
./build.sh
```

需要 Apple Command Line Tools。脚本会重新编译 Swift 代码并打包不含模型的 App（需先退出运行中的 App）。运行时依赖仍保留在 App 内，两个模型由应用首次使用时下载。

## 测试

```bash
Tests/run-tests.sh
```

验证断句逻辑、历史记录管理和 ID 更新机制。

## 官方来源

- [NVIDIA Nemotron English 模型](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)
- [NeMo-Speech.cpp SDK](https://github.com/NVIDIA/NeMo-Speech.cpp)
- [腾讯 Hy-MT2 GGUF](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF)
- [llama.cpp b10991](https://github.com/ggml-org/llama.cpp/releases/tag/b10991)

详细版本和校验值见 [Dependencies/versions.json](Dependencies/versions.json)。

## 注意事项

- 本机 ad-hoc 签名，非 Developer ID 公证签名
- 首次使用需要约 1.7 GB 下载流量和约 2 GB 可用磁盘空间；下载中可停止，未完成文件不会作为模型使用。删除 `~/Library/Application Support/XueScribe/Models/` 后，下次开始字幕会重新下载并校验
- 模型标点不保证语义完整；endpoint 后达到等待预算时可能输出短语；连续无标点发言可能等待更久。最终修订会更新原字幕段并重新翻译，不会作为重复的新句追加。不能保证 ASR 或翻译模型完全准确
- 双语记录保存在 `~/Library/Application Support/XueScribe/Transcripts/`；首次启动新版时会复制旧 `LumaCaption` 目录中的记录

## 0.5 断句与修订

- Bridge 保留相同文本的真实 ASR 更新，提供 utterance ID；定时器不再重放缓存文本。只有同一 utterance 中 audio 游标推进的结果参与稳定性确认。
- 两个通用参数位于 `Segmenter.Configuration`：`confirmation = 0.45s`、`maxWait = 2.0s`。前者确认真实更新中的共同前缀，后者限制 endpoint 后等待续接的时间，并允许使用已稳定的逗号、分号或冒号边界。模型 endpoint 仍使用 SDK 的 800ms token-silence。
- partial 中优先提交已经稳定且后面出现新词的句末边界；超过预算时可提交稳定的分句标点边界；没有标点时不会按时间或词数硬切。没有新 ASR 结果时不强行确认 partial。
- final 中完整标点句及时提交（包括 Yes./No.）；没有句末标点的尾部暂存，等待下一 utterance。跨段保留重复词，不做文本去重猜测。句子范围由系统 NaturalLanguage tokenizer 识别。
- ASR 修订已提交前缀时，保留未受影响的段，替换受影响的后缀并删除旧的后续段。段 ID 保持稳定，revision 递增；过期翻译结果不会显示或写入当前文本记录。
- `transcript.jsonl` 保留事件历史（含 revision 和 segment_removed），`transcript.txt` 保留已完成翻译的当前版本。重建文本只在修订时发生。
- 日志中的 `latency_seconds` 是提交后等待及翻译耗时；`segmentation_wait_seconds` 是应用缓冲等待；`buffer_and_translation_seconds` 是两者之和，**不是精确的最后发声到中文字幕延迟**。800ms endpoint、ASR 推理与采集延迟仍需单独考虑，1～2.5 秒是目标而非保证。
- 当前 SDK 的 stability/confidence 不是可靠的连续置信评分，不用于决策。没有引入语法模型，错误的模型句号仍可能导致语义上不完整的句子。

回归测试包含真实更新/缓存区分、修订插入删除、跨 endpoint 续接、缩写/数字/短回答、停止冲刷、历史 ID、过期译文和 transcript 修订。

## 0.5.1 透明窗口

背景 0% 时保留 10pt 的近乎透明边缘缩放热区，四边与角落均可拖动。字幕采用浅色字及深色描边，以兼容白色页面。鼠标悬停时临时显示深色底板和控制栏，移开后恢复设定透明度。开启点击穿透时，窗口不会接收拖动；需先在菜单栏关闭点击穿透。

## 0.5.2 文字配色

移除字幕描边、文字阴影和窗口阴影。顶部半黑半白圆形按钮可切换深灰／浅灰文字，设置中的“文字颜色”也可选择，偏好自动保存。悬停不再改变整窗背景透明度，仅音频来源和按钮组显示局部底板。背景 0% 时仍保留边缘缩放区域。

## 0.6.0 可选云端 ASR

顶部电脑／云图标菜单，或设置中的 **ASR Provider**，可选择：

- Nemotron 3 English — Local（默认）
- AssemblyAI Universal-3.5 Pro — Cloud

切换时先停止采集，等待旧 ASR 尾段及翻译保存，再开启新 Provider；悬浮窗历史保留。网络错误不会自动切换服务或重复发送旧音频。

两个实现遵循 `ASRProvider` 接口，统一接收 16kHz mono Float32 PCM，输出相同 `ASREvent`。AssemblyAI 实现将连续 PCM 转为 PCM16，以 50ms 二进制帧通过 WebSocket 发送；没有 WAV 文件切片、录音上传或 batch 接口。发送积压上限 2 秒；网络或认证失败会显示错误并停止捕获。

### 官方协议核对（2026-09-16）

- 模型：`universal-3-5-pro`
- 地址：`wss://streaming.assemblyai.com/v3/ws`
- 认证：`Authorization` 请求头直接放 API key，不加 Bearer，不放 URL。
- `Begin.configuration.model` 必须确认请求的模型，随后才开始捕获。
- `Turn.transcript` 是当前 turn 的完整假设；`turn_order` 映射为 utterance ID；final 使用 `end_of_turn && turn_is_formatted`。
- word end 时间戳用于识别进度；Heartbeat 不作为文本稳定证据。同一时间戳上的文本修订会更新预览，但不会被当成进度确认。
- 使用 `mode=balanced`、`include_partial_turns=true`、`continuous_partials=true`；partials 的具体发送时机仍由服务端控制，不保证每个词都返回一条结果。
- 停止时发送 `Terminate`，继续读取尾部 Turn，直到 `Termination`，之后才关闭连接。服务器会话最长约 3 小时；服务器结束或网络中断后需手动重新开始。
- 翻译只调用本机 llama.cpp/Hy-MT2；glossary 仍用于本地翻译，不发送给 AssemblyAI。

AssemblyAI API Key 由用户在设置中填写，并保存在 `~/Library/Application Support/XueScribe/Secrets/assemblyai.key`；目录权限为 `0700`，文件权限为 `0600`，不会触发钥匙串授权窗口。Key 不写入偏好设置、字幕记录或日志。`Sources/LocalSecrets.swift` 不再参与构建。

官方来源：
- https://www.assemblyai.com/docs/streaming/select-the-speech-model
- https://www.assemblyai.com/docs/streaming/api-spec/streaming-websocket
- https://www.assemblyai.com/docs/streaming/message-sequence
- https://www.assemblyai.com/docs/streaming/common-session-errors-and-closures

测试模式可运行 `XUESCRIBE_TEST_PROVIDER=assemblyAI ./XueScribe.app/Contents/MacOS/XueScribe --headless --sample-seconds 12`，仅发送 App 内置样例，不录麦克风，不改变保存的 Provider 偏好；将环境变量改成 `local` 可验证本地路径。
