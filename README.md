# TouchPad 开发者手册

Turn your Android tablet into a Mac graphics tablet, just like an iPad.

本手册适用于TouchPad v0.1.2-rc。使用本手册以辅助你对于TouchPad进行审计。

## Overview

TouchPad 采用 Client–Server 架构：Android 端为前台 Client（捕获 MotionEvent 并发送），macOS 端为 Server（监听 TCP 端口并通过系统 API 模拟鼠标/笔之动作）。Android与macOS间使用 USB（通过 Android Debug Bridge,ADB 隧道）通信方式。

---

## 参数和权限

- 命令通道端口：9527（Constants.COMMAND_PORT）
- 视频/镜像通道端口：9528（Constants.VIDEO_PORT）
- 主机IP（本机环回）：127.0.0.1（Android 端和 macOS 端通过 adb reverse 在本机回环上建立隧道）
- BUFFER_SIZE = 1024 * 200
- TouchPad的macOS App随附了ADB软件包。一般均调用该软件包。但TouchPad依旧有几个备份位置来搜索ADB软件包

  - 程序包自带的 adb
  - /usr/local/bin/adb
  - /opt/homebrew/bin/adb
  - ~/Library/Android/sdk/platform-tools/adb
    macOS 客户端会先运行 `adb devices` 并对每个已连接设备执行 `adb -s <serial> reverse tcp:9527 tcp:9527` 和 `adb -s <serial> reverse tcp:9528 tcp:9528`。
- AndroidManifest 权限（来源：TouchPad_Android/app/src/main/AndroidManifest.xml）：

  - 请求 INTERNET 权限：android.permission.INTERNET
  - 主 Activity 固定为横屏（sensorLandscape）
  - 声明了一个 DeviceAdminReceiver（device_admin_receiver.xml），包含诸如 force-lock / wipe-data / disable-camera 等策略，说明应用可能在某些功能下请求设备管理员权限（通常用于“锁定屏幕”等远程控制功能）
- Android 客户端与 macOS 服务之间的控制指令（在 MainActivity.kt / 命令监听处可见）：

  - 应用发送身份：IDENT,<deviceName></devicename>\n
  - 常见命令（macOS -> Android）：
    - CMD_LOCK / CMD_UNLOCK（锁定/解锁）
    - CMD_TRACKPAD_ON / CMD_TRACKPAD_OFF（切换为触控板模式）
    - CMD_MIRROR_ON / CMD_MIRROR_OFF（打开/关闭视频镜像）
    - SYNC_REQ（Android 定期发送以请求状态） / SYNC_RESP:LOCKED（响应）
- 视频镜像 UI（Android）：

  - 使用 TextureView 展示来自 macOS 的视频流，TextureView 在代码中以全屏强制测量（覆盖默认测量），并在可用时启动解码渲染（DecoderRenderer）。
- 日志与错误提示（macOS）：

  - 如果没找到 adb，macOS 客户端会输出日志 “[TouchPad] 未找到 adb 可执行文件”
  - macOS 程序会在找到 adb 后打印隧道建立成功的日志，例如 “[TouchPad] USB 命令通道隧道已建立: <serial></serial>”

---

## 系统要求（源码校验后）

- macOS：建议 macOS 11.0 (Big Sur) 及以上（实际可运行需授予辅助功能/输入监控权限以控制鼠标）。
- Android：Android 10.0 (API 29) 及以上（代码中至少以 API 29 为目标说明）。
- 连接方式：USB（ADB reverse 隧道）。仓库 README 与源码均表明自 v0.1.1 起，首选 USB 隧道。

---

## 安装与配置（补充具体命令与步骤）

### 在 macOS 上

1. 将 TouchPad.app 放入 /Applications 并首次启动。
2. 授权必要权限：
   - 系统偏好设置 → 隐私与安全性 → 辅助功能（Accessibility）：允许 TouchPad 控制你的电脑，否则无法模拟鼠标/笔事件。
   - 如果出现「无法打开」或「已阻止」提示，在隐私设置中允许打开。
3. 检查 adb 可用性（可选，若未打包 adb 或未安装 platform-tools）：
   - 打开终端，运行：
     - adb devices
   - 若没有 adb，请安装 Android Platform Tools 或将 adb 放在上述路径之一。
4. macOS 客户端会自动执行：
   - adb devices
   - 对每个设备执行：
     - adb -s <serial></serial> reverse tcp:9527 tcp:9527
     - adb -s <serial></serial> reverse tcp:9528 tcp:9528

### 在 Android 平板上

1. 启用开发者选项与 USB 调试（Settings → About → 连续点击 Build number，回到 Developer options 打开 USB debugging）。
2. 安装 APK（从 Releases 下载或自行构建）。
   - 通过 ADB 安装： adb install path/to/TouchPad.apk
3. 启动应用并允许应用请求的权限（网络、必要时设备管理权限）。
   - 如果需要启用“锁定”功能，应用可能会引导你授予设备管理员权限（在系统设置的安全或设备管理项中确认）。

---

## 建议的手动调试命令

- 查看已连接设备并获取序列号：
  - adb devices
- 手动建立 adb reverse 隧道（如果需要手工执行）：
  - adb -s <serial></serial> reverse tcp:9527 tcp:9527
  - adb -s <serial></serial> reverse tcp:9528 tcp:9528
- 确认本地端口是否监听（在 macOS 侧）：
  - lsof -iTCP:9527 -sTCP:LISTEN
  - lsof -iTCP:9528 -sTCP:LISTEN

---

## 连接与使用（源码对应的行为）

- 启动 macOS 客户端后，应用会尝试自动建立 ADB 隧道并启动 TCP 服务（端口 9527 用于命令，9528 用于视频流）。
- 启动 Android 客户端并连接 USB 后，Android 会尝试通过 127.0.0.1:9527 建立 socket 连接（客户端源码中连接到 127.0.0.1:9527）。
- 建立连接后 Android 会发送 IDENT,<deviceName></devicename>\n，macOS 可发送控制命令如 CMD_LOCK 等，Android 会根据收到的命令切换模式或显示/隐藏视频镜像。
- Android 客户端会每秒发送 SYNC_REQ（源码中有 1 秒的轮询），服务端可返回 SYNC_RESP:LOCKED 等状态。

---

## 权限与安全（源码提示）

- AndroidManifest 中只声明了 INTERNET 权限；但代码包含 DeviceAdminReceiver（device_admin_receiver.xml），所以若启用锁定等功能，应用会请求“设备管理员”权限。启用前请核实用途并在系统设置中查看权限详情。
- 网络通信仅在本机（127.0.0.1）通过 adb 隧道，因此不会直接开放到局域网；默认实现不会把触控内容上传到第三方服务器（参考源码通信为点对点）。如有隐私或安全疑虑，请审阅源码网络/日志相关实现。

---

## Log

一、macOS（NSLog） — TouchPad_macOS / build_macOS 来源：NetworkManager.swift、ScreenStreamer.swift（或 build_macOS 对应文件）

“[TouchPad] 未找到 adb 可执行文件”

触发时机：setupAdbTunnel() 搜索内置或常见路径下的 adb 可执行文件未找到时。
含义/原因：未安装 adb，且应用包内没有内置 adb 可执行文件。
建议：安装 Android Platform Tools（adb），或将 adb 放到 /usr/local/bin、/opt/homebrew/bin 或 ~/Library/Android/sdk/platform-tools，或打包内置 adb 到 .app。
“[TouchPad] ADB 执行失败: <error></error>”

触发时机：尝试运行 adb (例如 adb devices) 时 Process.run() 抛异常。
含义/原因：执行 adb 命令失败（权限、路径错误、可执行权限问题或其他系统错误）。
建议：检查 adb 可执行权限（chmod +x）、路径是否正确、是否允许应用访问该可执行文件；查看具体 error 消息。
“[TouchPad] ADB 异常: <error></error>”

触发时机：在 runAdbCommand 的 try/catch 捕获到异常（如 run() 抛出）。
含义/原因：在执行 adb reverse 或其他 adb 子命令时发生异常。
建议：查看 error 详情，确认设备连通与 adb 权限，手工运行相同 adb 命令定位问题。
“[TouchPad] USB 命令通道隧道已建立: <serial></serial>”

触发时机：adb reverse tcp:9527 tcp:9527 成功（tunnelTask.terminationStatus == 0）后打印。
含义/原因：macOS 已为该设备建立了命令通道（9527）反向隧道，Android 可通过 127.0.0.1:9527 连接。
建议：若 Android 无法连接，确认该日志存在并检查 adb devices 是否列出该 <serial></serial>。
“[TouchPad] USB 视频通道隧道已建立: tcp:9528”

触发时机：adb reverse tcp:9528 tcp:9528 成功后打印。
含义/原因：用于视频/镜像流的 9528 隧道建立成功。
建议：若镜像不可用，确认此日志存在、并检查 Android 端 127.0.0.1:9528 连接。
“[TouchPad] ERROR: 视频通道隧道建立失败: <error></error>”

触发时机：为视频通道执行 adb reverse 时抛异常（catch 分支）。
含义/原因：adb 在建立 9528 隧道时失败（权限、设备已断开或 adb 错误）。
建议：查看 error；手动运行 adb reverse 命令以调查原因；确认设备是否仍在线。
“[TouchPad] ERROR: 命令通道隧道建立失败”

触发时机：adb reverse 命令运行后返回非 0（tunnelTask.terminationStatus != 0）。
含义/原因：adb reverse 未能成功建立隧道（可能 adb 版本不支持、权限或设备状态问题）。
建议：手动运行 “adb -s <serial></serial> reverse tcp:9527 tcp:9527” 检查输出；重插 USB / 重启 adb server。
“[Streamer] Starting video service...”

触发时机：ScreenStreamer 启动视频服务的入口处。
含义/原因：开始监听视频端口并建立视频流服务。
“[Streamer] ERROR: cannot create socket”

触发时机：调用 socket() 返回 -1（不可创建 socket）。
含义/原因：系统资源不足或调用参数错误导致无法创建 socket。
建议：检查系统限制（ulimit）、是否存在权限限制或冲突的安全软件；查看系统日志。
“[Streamer] ERROR: bind failed”

触发时机：bind(...) 返回 -1（无法在指定端口绑定）。
含义/原因：端口被占用或权限问题（低端口/防火墙策略）或地址无效。
建议：确认没有其它进程监听该端口（lsof -iTCP:9528）。重启应用或选择不同端口。
“[Streamer] Video server listening on port 9528”

触发时机：listen(...) 成功后。
含义/原因：视频服务端口已监听，等待客户端连接。
“[Streamer] Client connected”

触发时机：accept() 返回客户端 socket（有客户端建立连接）。
含义/原因：某客户端（通常是 Android 端）连接到了视频端口。
“[Streamer] ERROR: compression session setup failed”

触发时机：setupCompressionSession() 返回 false（压缩/编码会话初始化失败）。
含义/原因：创建 VTCompressionSession 或获取屏幕信息失败（可能与权限、屏幕不可用或 API 限制有关）。
建议：确认应用已获得屏幕捕获权限、NSScreen 可用，检查控制台中的详细 CoreVideo/VideoToolbox 错误。
“[Streamer] Client disconnected”

触发时机：检测到客户端断开（recv 返回 0 或循环结束）。
含义/原因：客户端关闭了连接或网络错误导致断开。
“[Streamer] ERROR: cannot get main screen”

触发时机：NSScreen.main 为 nil（setupCompressionSession 中）。
含义/原因：无主屏或运行环境不支持获取屏幕（Headless 或权限问题）。
建议：确认在桌面环境运行，检查系统隐私设置、沙箱权限或是否以正确用户运行。
“[Streamer] Resolution: <width></width>x<height></height> (Scale: <scale></scale>)”

触发时机：成功取得屏幕并计算物理像素尺寸后打印。
含义/原因：告知用于编码的视频分辨率和屏幕缩放因子（有助于调试分辨率/缩放问题）。
二、Android（Log.d / Log.w / Log.e） — TouchPad_Android

来源：MainActivity.kt、NetworkReceiver.kt、DecoderRenderer.kt 等

A. MainActivity / UI、连接、命令监听

"TextureView created"

触发时机：在创建 TextureView 的 factory 时。
含义/原因：TextureView 已创建（用于视频显示）。
"USB 连接成功"

触发时机：connectToMac() 成功连接到 127.0.0.1:9527 后。
含义/原因：Android 成功建立命令通道 socket，与 macOS 建立了通信（通常依赖 adb reverse）。
建议：如果未看到此日志，检查 adb reverse 隧道是否建立、adb devices、数据线与 USB 调试。
"USB 连接失败: <message></message>"

触发时机：连接 127.0.0.1:9527 抛异���时（catch）。
含义/原因：无法连接到本地命令端口（9527），可能隧道未建立或服务未监听。
建议：确认 macOS 已建立隧道并监听 9527；在 mac 上查看 TouchPad 日志中是否有 “USB 命令通道隧道已建立”。
"Received cmd: <line></line>"

触发时机：从命令通道 reader 读到一行命令时。
含义/原因：收到来自 macOS 的控制命令（例如 CMD_LOCK、CMD_MIRROR_ON 等）。
建议：查看 line 的具体内容以判断是否为预期指令。
"enableMirrorMode called"

触发时机：收到 CMD_MIRROR_ON 或用户触发镜像时调用 enableMirrorMode()。
含义/原因：准备显示视频镜像，开始设置 TextureView 与 DecoderRenderer。
"Mirror already running" (Log.w)

触发时机：enableMirrorMode() 被再次调用但已在运行时。
含义/原因：重复开启镜像会被忽略。
建议：无需处理；若期望重启镜像，可先关闭再打开。
"TextureView is null!" (Log.e)

触发时机：enableMirrorMode() 中 textureView 为 null 时。
含义/原因：UI 未初始化或已被释放，无法显示视频。
建议：确保 UI 已加载或在 UI 线程上正确创建 TextureView。
"TextureView Surface Available"

触发时机：TextureView 的 SurfaceTextureListener.onSurfaceTextureAvailable 回调。
含义/原因：Surface 可用，开始视频流解码。
"TextureView is already available, starting stream immediately"

触发时机：在启用镜像时发现 textureView 已可用的分支。
含义/原因：无需等待回调，立即开始解码/播放。
B. NetworkReceiver（视频帧接收）—— TouchPad_Android/app/src/.../NetworkReceiver.kt

"Already running, forcing restart" (Log.w)

触发时机：connect() 被重复调用且 isRunning 为 true 时。
含义/原因：已有接收器在运行，新的连接请求会先断开旧连接重启接收器。
"Connecting to 127.0.0.1:9528 (Attempt N)"

触发时机：尝试连接视频流端口（Constants.HOST / VIDEO_PORT）时每次尝试都会打印。
含义/原因：表明正在尝试与服务器建立视频连接（会重试最多 10 次）。
"Connected successfully!"

触发时机：连接成功（Socket 创建并未抛异常）。
含义/原因：已与服务端（macOS 视频端）建立 TCP 连接。
"Connection failed: <msg></msg>. Retrying in 100ms..." (Log.w)

触发时机：连接尝试抛异常但尚未达到最大重试次数时。
含义/原因：短暂网络/隧道问题，准备重试。
建议：如果持续出现，检查 adb reverse、USB 连接及 macOS 端视频服务是否可用。
"Failed to connect after <attempts></attempts> attempts" (Log.e)

触发时机：重试多次仍失败后退出连接循环。
含义/原因：无法建立视频连接（9528），可能隧道未建立或服务未监听。
建议：检查 macOS 日志（[Streamer] Video server listening...）及 adb 隧道。
"readPacket returned null (EOF or Error)" (Log.w)

触发时机：readPacket 返回 null（输入流 EOF 或读包失败）时。
含义/原因：服务端断开或数据流格式错误。
建议：检查网络连接、服务端是否仍在发送、包头长度是否合法。
"Connection error: <message></message>" (Log.e)

触发时机：在 frame 循环外层 try/catch 捕获到异常。
含义/原因：I/O 错误、socket 异常或其他运行时异常导致连接中断。
建议：查看 exception message、Logcat 与 macOS 端日志。
"Disconnecting..." (Log.d)

触发时机：disconnect() 被调用，或连接失败后清理。
含义/原因：正在关闭 socket / 停止接收线程。
"readPacket: Invalid packet length: <length></length>" (Log.e)

触发时机：接收到的包长度 <=0 或超过阈值（Constants.BUFFER_SIZE * 10）。
含义/原因：收到恶意/损坏/格式错误的数据包或协议不同步。
建议：检查服务端数据编码与协议；在 macOS 端确认发送的包长度字段是否合法。
C. DecoderRenderer（解码器）—— DecoderRenderer.kt

"SPS found (Raw size: <n></n>)" (Log.d)

触发时机：从视频流中解析到 H.264 的 SPS NAL（nal type 7）并缓存时。
含义/原因：解码器获得初始化所需的 SPS 头信息，有利于快速配置 MediaCodec。
"PPS found (Raw size: <n></n>)" (Log.d)

触发时机：解析到 PPS NAL（nal type 8）并缓存时。
含义/原因：与 SPS 一起用于配置解码器。
"Decoder started with CSD headers." (Log.d)

触发时机：在 configureDecoder() 成功 configure/start decoderInstance 后打印。
含义/原因：解码器启动成功并使用了 csd-0/csd-1（SPS/PPS）辅助初始化。
"Output format changed event: <w></w>x<h></h>" (Log.d)

触发时机：MediaCodec 收到 INFO_OUTPUT_FORMAT_CHANGED 或在 outputFormat 更新后记录较大的尺寸。
含义/原因：解码器输出尺寸发生变化，应用需根据新尺寸调整显示布局。
"Decode error" (Log.e) + exception

触发时机：在解码循环或 dequeue/release 过程中抛异常。
含义/原因：解码失败（数据损坏、不支持的编码、硬件问题等）。
建议：检查传入流的 SPS/PPS 与帧数据，查看具体异常堆栈；在 CPU/GPU 解码不兼容时考虑软件解码（如果实现）。
"Config error" (Log.e) + exception

触发时机：configureDecoder() 中 configure/start 抛异常时。
含义/原因：提供给 MediaCodec 的格式或 csd 字节不合法或硬件解码器问题。
建议：打印/检查 csd 内容与占位分辨率（源码使用 1920x1080 作为占位），确认硬件解码支持 H.264。
"Stop error" (Log.e) + exception

触发时机：stop() 中 stop()/release() 抛异常时。
含义/原因：解码器资源释放异常（通常不致命，但需检查）。

---

## 从源码构建（补充）

- Android：
  - 在 `TouchPad_Android/` 模块中使用 Gradle 构建：
    - ./gradlew assembleDebug
  - 主包名在源码里为 `com.example.touchpad`（见 `TouchPad_Android/app/src/main/java/com/example/touchpad`）。
- macOS：
  - 在 `TouchPad_macOS/` 或 `build_macOS/` 源码中用 Xcode 打开并构建，应用会尝试在启动时运行 adb 并建立隧道（参见 NetworkManager.swift）。
  - macOS 二进制可能包含一个内置的 adb 可执行文件（应用 bundle 内），若存在则应用会先尝试使用内置版本。

---

## 报告问题与贡献（源码映射）

- 提交 Issue 时请包含：
  - macOS 版本、Android 设备型号与 Android 版本
  - TouchPad 版本 / 构建方式（Release 下载或自行构建）
  - 日志片段（macOS Console、Android Logcat）
  - 是否为 USB（ADB）连接以及 adb devices 输出
- PR 流程：Fork → 新分支 → 变更 → PR（参见仓库根目录的 CONTRIBUTING.md，如存在）

---
