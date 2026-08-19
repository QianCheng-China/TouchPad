# TouchPad 开发者文档

通过该文档了解TouchPad的工作原理，进行故障排除并进行二次开发。

## I.概述

### 一、整体设计框架

TouchPad 是一套完整的Android平板转Mac绘图板解决方案，采用**客户端-服务器**架构，通过**USB隧道（ADB reverse）**实现低延迟通信。

### 二、主要平台与组件


| 平台        | 语言   | 主要职责                                      |
| ------------- | -------- | ----------------------------------------------- |
| **macOS**   | Swift  | 接收触控输入，控制鼠标/触控板，进行屏幕镜像   |
| **Android** | Kotlin | 采集触控笔/手指输入，接收屏幕镜像，显示视频流 |

## II.底层通信协议

### 一、ADB 隧道建立

#### ADB Reverse 机制

TouchPad 使用 **ADB reverse** 建立 USB 隧道，而非 forward。这样 Android 端可以主动连接 Mac 端，避免 Mac 需要找设备地址。

**建立流程（macOS端 - NetworkManager.swift）**：

```swift
// 第1步：建立命令通道隧道
adb reverse tcp:9527 tcp:9527

// 第2步：建立视频通道隧道
adb reverse tcp:9528 tcp:9528

// 第3步：获取设备名
adb shell settings get secure bluetooth_name
```

**关键点**：

- 两个独立的端口：**9527（命令）** 和 **9528（视频）**
- Android 连接 `127.0.0.1:9527` 实际连接到 macOS 上的 `127.0.0.1:9527`
- ADB 自动处理 USB 物理层转发，开发者无需关心

#### 代码实现位置

- **macOS**: `TouchPad_macOS/Sources/macOSApp/NetworkManager.swift` → `setupAdbTunnel()`
- **Android**: `TouchPad_Android/app/src/main/java/com/example/touchpad/MainActivity.kt` → `connectToMac()`

### 二、命令通道（TCP 9527）协议

#### 连接建立

1. **Android 发起连接**（MainActivity.kt）：

   ```kotlin
   usbSocket.connect(InetSocketAddress("127.0.0.1", Constants.COMMAND_PORT), 500)
   ```
2. **macOS 接收并建立 TCP 服务器**（NetworkManager.swift）：

   ```swift
   startTcpServer()  // 监听 TCP 9527
   ```

#### 消息格式

所有命令采用**纯文本 + 换行符**格式：

```
[COMMAND],[PARAM1],[PARAM2],...\n
```

#### 支持的命令列表

**A. 设备标识 → macOS**

```
IDENT,<设备名称>
```

- **触发时机**：Android 连接建立后立即发送
- **目的**：告知 macOS 当前连接的设备标识
- **示例**：`IDENT,Samsung Galaxy Tab S8`

**B. 同步请求 → Android → macOS**

```
SYNC_REQ
```

- **触发时机**：Android 应用恢复（onResume）或定时（每1000ms）
- **macOS 应答**：
  ```
  SYNC_RESP:LOCKED    # 设备被锁定
  SYNC_RESP:UNLOCKED  # 设备未锁定
  ```
- **用途**：同步屏幕锁定状态

**C. 触控笔输入 → Android → macOS**

```
PEN_DOWN,<normX>,<normY>     # 笔按下
PEN_MOVE,<normX>,<normY>     # 笔移动
PEN_UP,<normX>,<normY>       # 笔抬起
PEN_HOVER,<normX>,<normY>    # 笔悬停
```

- **参数说明**：
  - `normX`, `normY`：标准化坐标（0-10000），计算方式：
    ```kotlin
    normX = (event.x / width * 10000f).toInt()
    normY = (event.y / height * 10000f).toInt()
    ```
  - macOS 端转换为屏幕坐标：
    ```swift
    x = (normX / COORD_SCALE) * screen.frame.width
    y = (normY / COORD_SCALE) * screen.frame.height
    ```

**D. 触控板多点输入 → Android → macOS**

```
TOUCH,<count>,<id1>,<x1>,<y1>,<id2>,<x2>,<y2>,...
```

- **参数说明**：
  - `count`：触控点数（1-4）
  - `id`：触控点ID（用于多点追踪）
  - `x`, `y`：标准化坐标（0-10000）

**E. 控制命令 → macOS → Android**

```
CMD_LOCK              # 启用屏幕锁定
CMD_UNLOCK            # 禁用屏幕锁定
CMD_TRACKPAD_ON       # 启用触控板模式
CMD_TRACKPAD_OFF      # 禁用触控板模式
CMD_MIRROR_ON         # 启用屏幕镜像
CMD_MIRROR_OFF        # 禁用屏幕镜像
```

#### 协议处理代码位置

**Android 端处理（MainActivity.kt）**：

```kotlin
fun startCommandListener(inputStream: java.io.InputStream) {
    val reader = java.io.BufferedReader(inputStream.reader())
    while (true) {
        val line = reader.readLine() ?: break
        when {
            line == "CMD_LOCK" -> runOnUiThread { enableLockMode() }
            line == "CMD_UNLOCK" -> runOnUiThread { disableLockMode() }
            // ... 其他命令处理
        }
    }
}
```

**macOS 端处理（NetworkManager.swift）**：

```swift
func handleClient(sock: Int32) {
    // 解析接收的消息
    if cleanMsg.hasPrefix("IDENT,") { ... }
    if cleanMsg == "SYNC_REQ" { ... }
    if let id = deviceId { processCommand(cleanMsg, from: id) }
}
```

### 三、视频通道（TCP 9528）协议

#### 视频流格式

使用 **H.264 编码**，采用自定义封包格式：

```
┌──┬──┬──┬──┬──┬───────────────────────────┐
│T │  L0 │  L1 │  L2  │  L3  │ H.264 Data  │
└──┴──┴──┴──┴──┴───────────────────────────┘
 1B      4B (大端)           Variable
```

- **T（1 字节）**：数据类型标记 = `0x01`
- **L（4 字节）**：后续数据长度（大端序）
- **Data**：实际 H.264 编码数据（Annex-B 格式）

#### 关键参数


| 参数       | 值       | 说明                                     |
| ------------ | ---------- | ------------------------------------------ |
| 编码格式   | H.264    | 硬件编码支持好，兼容性强                 |
| 码率       | 8 Mbps   | 平衡质量与延迟                           |
| 关键帧间隔 | 30 帧    | 2秒一个关键帧                            |
| 帧率       | ~60fps   | 屏幕刷新率同步                           |
| 分辨率     | 物理像素 | 使用 backingScaleFactor 处理 Retina 屏幕 |

#### 代码位置

**macOS 端编码（ScreenStreamer.swift）**：

```swift
// 压缩配置
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, 
                      value: NSNumber(value: 8000000))  // 8Mbps
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, 
                      value: NSNumber(value: 30))       // 关键帧间隔

// 发送编码数据
let netLength = Int32(annexBData.count)
var header = [UInt8](repeating: 0, count: 5)
header[0] = 1  // 数据类型
Darwin.send(sock, &header, header.count, 0)
Darwin.send(sock, [UInt8](annexBData), annexBData.count, 0)
```

**Android 端解码（NetworkReceiver.kt）**：

```kotlin
private fun readPacket(input: InputStream): ByteArray? {
    val type = input.read()           // 读取类型 (0x01)
    val lengthBytes = ByteArray(4)
    input.readFully(lengthBytes, 4)   // 读取长度
    val length = ByteBuffer.wrap(lengthBytes)
                            .order(ByteOrder.BIG_ENDIAN).int
    val payload = ByteArray(length)
    input.readFully(payload, length)
    return payload
}
```

---

## III.关键模块

### 一、输入处理模块

#### A. 触控笔识别与处理（DrawingPadView.kt）

```kotlin
override fun onTouchEvent(event: MotionEvent): Boolean {
    // 第1步：判断输入工具类型
    if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
        handleStylus(event)  // 触控笔处理
        return true
    }
  
    // 第2步：判断是否为触控板模式
    if (isTrackpadMode) {
        handleMultiTouch(event)  // 多点触控处理
        return true
    }
    return false
}

override fun onHoverEvent(event: MotionEvent): Boolean {
    // 悬停检测（触控笔在屏幕上方）
    if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
        handleStylus(event)
    }
    return true
}
```

**触控笔事件处理**：

```kotlin
private fun handleStylus(event: MotionEvent) {
    val normX = (event.x / width * 10000f).toInt()  // 归一化坐标
    val normY = (event.y / height * 10000f).toInt()
  
    when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> 
            onCommandSent?.invoke("PEN_DOWN,$normX,$normY")
        MotionEvent.ACTION_MOVE -> 
            onCommandSent?.invoke("PEN_MOVE,$normX,$normY")
        MotionEvent.ACTION_UP -> 
            onCommandSent?.invoke("PEN_UP,$normX,$normY")
        MotionEvent.ACTION_HOVER_ENTER,
        MotionEvent.ACTION_HOVER_MOVE -> 
            onCommandSent?.invoke("PEN_HOVER,$normX,$normY")
    }
}
```

#### B. 多点触控处理（触控板模式）

```kotlin
private fun handleMultiTouch(event: MotionEvent) {
    if (event.pointerCount > 4) return  // 最多4个触控点
  
    val count = event.pointerCount
    val sb = StringBuilder("TOUCH,$count")
  
    // 遍历所有触控点
    for (i in 0 until count) {
        val id = event.getPointerId(i)        // 触控点ID
        val x = (event.getX(i) / width * 10000f).toInt()
        val y = (event.getY(i) / height * 10000f).toInt()
        sb.append(",$id,$x,$y")
    }
  
    onCommandSent?.invoke(sb.toString())
}
```

#### C. 发送管道（MainActivity.kt）

```kotlin
// 所有命令通过 Channel 异步发送，确保不阻塞 UI
private val sendChannel = Channel<String>(capacity = Channel.UNLIMITED)

scope.launch(Dispatchers.IO) {
    for (msg in sendChannel) {
        try {
            outputStream!!.write(msg.toByteArray())
            outputStream!!.flush()
        } catch (e: Exception) {
            socket = null
            break
        }
    }
}

// 使用
onCommandSent = { cmd: String -> sendChannel.trySend("$cmd\n") }
```

### 二、鼠标控制模块（MouseController.swift）

#### A. 命令入口

```swift
func processCommand(_ cmd: String, from id: String) {
    let parts = cmd.split(separator: ",")
    guard !parts.isEmpty else { return }
    let action = String(parts[0])
  
    if action.hasPrefix("PEN") {
        handleStylus(cmd: cmd, parts: parts)
    } else if action == "TOUCH" {
        handleTouch(cmd: cmd, parts: parts)
    }
}
```

#### B. 触控笔事件转换

```swift
func handleStylus(cmd: String, parts: [String.SubSequence]) {
    guard parts.count >= 3,
          let x = Double(String(parts[1])),
          let y = Double(String(parts[2])) else { return }
  
    // 转换标准化坐标到屏幕坐标
    guard let screen = NSScreen.main else { return }
    let point = CGPoint(
        x: (x / COORD_SCALE) * screen.frame.width,
        y: (y / COORD_SCALE) * screen.frame.height
    )
  
    switch String(parts[0]) {
    case "PEN_DOWN":
        isStylusDown = true
        postMouseEvent(type: .leftMouseDown, location: point, button: .left)
    case "PEN_MOVE":
        let type: CGEventType = isStylusDown ? .leftMouseDragged : .mouseMoved
        postMouseEvent(type: type, location: point, button: .left)
    case "PEN_UP":
        isStylusDown = false
        postMouseEvent(type: .leftMouseUp, location: point, button: .left)
    case "PEN_HOVER":
        if isStylusDown {
            isStylusDown = false
            postMouseEvent(type: .leftMouseUp, location: point, button: .left)
        }
        postMouseEvent(type: .mouseMoved, location: point, button: .left)
    default: break
    }
}
```

#### C. 系统事件注入

```swift
private func postMouseEvent(type: CGEventType, location: CGPoint, button: CGMouseButton) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, 
                              mouseCursorPosition: location, mouseButton: button) 
    else { return }
    event.post(tap: .cghidEventTap)
}

private func postScrollEvent(dy: Int32, dx: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, 
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) 
    else { return }
    event.post(tap: .cghidEventTap)
}
```

#### D. 触控板手势识别

```swift
func handleTouch(cmd: String, parts: [String.SubSequence]) {
    guard let count = Int(String(parts[1])) else { return }
  
    // 解析多个触控点
    var points: [TouchPoint] = []
    var idx = 2
    while idx + 2 < parts.count {
        if let id = Int(String(parts[idx])),
           let x = CGFloat(String(parts[idx+1])),
           let y = CGFloat(String(parts[idx+2])) {
            points.append(TouchPoint(id: id, x: x, y: y))
        }
        idx += 3
    }
  
    // 识别手势：单指移动、缩放、滑动等
    updateTouchState(points: points)
    recognizeGestures()
}
```

### 三、屏幕镜像模块

#### A. macOS 端编码（ScreenStreamer.swift）

**分辨率处理**：

```swift
private func setupCompressionSession() -> Bool {
    guard let screen = NSScreen.main else { return false }
  
    // 【关键】使用物理像素分辨率，处理 Retina 屏幕
    let scale = screen.backingScaleFactor
    let width = Int32(screen.frame.width * scale)
    let height = Int32(screen.frame.height * scale)
  
    NSLog("[Streamer] Resolution: \(width)x\(height) (Scale: \(scale))")
  
    // 创建 H.264 编码会话
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: width,
        height: height,
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil,
        imageBufferAttributes: sourceAttributes as CFDictionary,
        compressedDataAllocator: nil,
        outputCallback: compressionOutputCallback,
        refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
        compressionSessionOut: &session
    )
}
```

**屏幕捕获**：

```swift
private func startDisplayStream() {
    let mainDisplay = CGMainDisplayID()
    guard let screen = NSScreen.main else { return }
  
    let scale = screen.backingScaleFactor
    let width = Int(screen.frame.width * scale)
    let height = Int(screen.frame.height * scale)
  
    // 使用 CGDisplayStream 捕获屏幕
    displayStream = CGDisplayStream(
        dispatchQueueDisplay: mainDisplay,
        outputWidth: width,
        outputHeight: height,
        pixelFormat: Int32(kCVPixelFormatType_32BGRA_Custom),
        properties: streamOptions as CFDictionary,
        queue: DispatchQueue.global(qos: .userInteractive),
        handler: handler  // 帧可用回调
    )
  
    displayStream?.start()
}
```

**帧编码与发送**：

```swift
private func handleEncodedSample(sampleBuffer: CMSampleBuffer) {
    guard let sock = clientSocket else { return }
  
    // 获取编码数据
    let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)!
    let length = CMBlockBufferGetDataLength(blockBuffer)
    var data = Data(count: length)
    data.withUnsafeMutableBytes { ptr in
        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, 
                                   dataLength: length, destination: ptr.baseAddress!)
    }
  
    // 转换格式（AVCC → Annex-B）
    let annexBData = convertAVCCToAnnexB(data)
  
    // 发送 H.264 数据包
    var header = [UInt8](repeating: 0, count: 5)
    header[0] = 1  // 类型标记
    let netLength = Int32(annexBData.count)
    for i in 0..<4 {
        header[i+1] = UInt8(truncatingIfNeeded: netLength >> (8 * (3-i)))
    }
    Darwin.send(sock, &header, header.count, 0)
    Darwin.send(sock, [UInt8](annexBData), annexBData.count, 0)
}
```

#### B. Android 端解码（NetworkReceiver.kt）

```kotlin
fun connect() {
    job = CoroutineScope(Dispatchers.IO).launch {
        // 连接到 macOS 端的视频服务
        socket = Socket(Constants.HOST, Constants.VIDEO_PORT)
  
        try {
            val input = socket!!.getInputStream()
            while (isRunning) {
                val packet = readPacket(input)
                if (packet != null) {
                    onFrameReceived(packet)  // 回调给解码器
                } else {
                    break
                }
            }
        } finally {
            disconnect()
            onDisconnected()  // 连接断开通知
        }
    }
}

private fun readPacket(input: InputStream): ByteArray? {
    try {
        val type = input.read()  // 读取类型 (0x01)
        if (type == -1) return null
  
        // 读取 4 字节长度（大端序）
        val lengthBytes = ByteArray(4)
        if (!readFully(input, lengthBytes, 4)) return null
  
        val length = ByteBuffer.wrap(lengthBytes)
                               .order(ByteOrder.BIG_ENDIAN).int
        if (length <= 0 || length > Constants.BUFFER_SIZE * 10) {
            Log.e("NetworkReceiver", "Invalid packet length: $length")
            return null
        }
  
        // 读取实际数据
        val payload = ByteArray(length)
        if (!readFully(input, payload, length)) return null
        return payload
    } catch (e: Exception) {
        return null
    }
}
```

**渲染到 TextureView**：

```kotlin
private fun enableMirrorMode() {
    textureView?.visibility = View.VISIBLE
    textureView?.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
            startVideoStream(surface)
        }
    }
}

private fun startVideoStream(surfaceTexture: SurfaceTexture) {
    val surface = Surface(surfaceTexture)
    decoderRenderer = DecoderRenderer(surface)
  
    // 【关键】接收到视频大小信息，设置缓冲区
    decoderRenderer?.onVideoSizeChanged = { vW, vH ->
        Log.d("MainActivity", "Video size: ${vW}x${vH}")
        runOnUiThread {
            textureView?.surfaceTexture?.setDefaultBufferSize(vW, vH)
        }
    }
  
    decoderRenderer?.start()
    networkReceiver = NetworkReceiver(onFrameReceived = { data ->
        decoderRenderer?.decode(data)  // 解码 H.264 数据
    })
    networkReceiver?.connect()
}
```

### 四、屏幕锁定模块

#### macOS 端（AppDelegate.swift）

```swift
@objc func toggleScreenLocking() {
    AppState.shared.isLocked.toggle()
    if AppState.shared.isLocked {
        sendCommandToClient("CMD_LOCK")
    } else {
        sendCommandToClient("CMD_UNLOCK")
    }
}
```

#### Android 端（MainActivity.kt）

```kotlin
private fun enableLockMode() {
    if (isLocked) return
    isLocked = true
  
    // 隐藏系统UI
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        window.insetsController?.hide(
            WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars()
        )
    } else {
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
    }
  
    // 启动 Lock Task（设备所有者模式）
    try {
        if (isDeviceOwner) {
            dpm.setLockTaskFeatures(adminName, 
                DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
        }
        startLockTask()
    } catch (e: Exception) {
        Log.e("MainActivity", "Lock Error: ${e.message}")
    }
}
```

---

## IV.日志系统与调试

### 一、日志输出位置与格式

#### Android 端日志

**Log Tag 规范**：


| 模块     | Tag               | 用途                     |
| ---------- | ------------------- | -------------------------- |
| 主界面   | `MainActivity`    | 连接、命令接收、模式切换 |
| 网络接收 | `NetworkReceiver` | 视频连接、包接收         |
| 绘图板   | `DrawingPadView`  | 触控事件                 |

**查看日志**：

```bash
adb logcat MainActivity:V NetworkReceiver:V DrawingPadView:V *:S
```

#### macOS 端日志

**Log 前缀规范**：

- `[TouchPad]` - 主程序
- `[Streamer]` - 屏幕镜像
- `[Network]` - 网络通信

**查看日志**：

```bash
# 实时查看 Console 应用
open /Applications/Utilities/Console.app

# 或者通过命令行
log stream --predicate 'process == "TouchPad"'
```

### 二、所有可能的日志及诊断

#### A. Android 端日志

**1. 连接相关**

```
D/MainActivity: USB 连接成功
```

- **含义**：成功连接到 macOS
- **前置条件**：ADB 隧道已建立、macOS 端 TCP 服务已启动
- **问题排查**：
  1. 检查 ADB 隧道：`adb reverse -l`
  2. 检查 macOS 端 TCP 服务是否运行
  3. 检查网络连接（USB 数据线质量）

**2. 连接失败**

```
E/MainActivity: USB 连接失败: java.net.ConnectException: Connection refused
```

- **含义**：无法连接到 `127.0.0.1:9527`
- **原因**：
  - ADB 隧道未建立
  - macOS 端 TCP 服务未启动
  - macOS 的 adb 无法识别设备
- **排查步骤**：
  ```bash
  # Mac 端执行
  adb devices  # 检查设备是否被识别
  adb reverse -l  # 检查隧道是否建立
  # 如果列表为空，说明隧道建立失败

  # 重新建立隧道
  adb reverse tcp:9527 tcp:9527
  adb reverse tcp:9528 tcp:9528
  ```

**3. 屏幕镜像连接**

```
D/NetworkReceiver: Connected successfully!
D/NetworkReceiver: Connecting to 127.0.0.1:9528 (Attempt 1)
```

- **正常流程**：连接 → 发送数据 → 渲染
- **问题排查**：
  - 如果显示 `Connection refused`，可能是屏幕镜像功能未启用

**4. 视频解码**

```
E/NetworkReceiver: readPacket: Invalid packet length: 123456789
```

- **含义**：收到的数据包长度异常（超过缓冲区限制）
- **原因**：
  - 网络数据损坏
  - macOS 端视频流异常
- **修复**：重新连接或检查网络质量

**5. 触控事件**

```
D/MainActivity: Received cmd: PEN_DOWN,5000,5000
```

- **含义**：正常接收触控笔事件
- **如果没有这条日志**：
  - 检查 DrawingPadView 是否在最前面
  - 检查输入模式设置（仅触控笔 vs 广泛）
  - 触控笔可能不支持当前设备

#### B. macOS 端日志

**1. 应用启动**

```
[TouchPad] 未找到 adb 可执行文件
```

- **含义**：macOS 找不到 adb
- **排查**：
  ```bash
  which adb  # 查看 adb 位置
  ls -la ~/.local/share/Android/sdk/platform-tools/adb
  ```
- **解决**：
  - 重新安装 Android SDK
  - 将 adb 放在搜索路径中：
    ```bash
    cp adb /usr/local/bin/adb
    chmod +x /usr/local/bin/adb
    ```

**2. ADB 隧道建立失败**

```
[TouchPad] ADB 执行失败: ...
[TouchPad] ERROR: 命令通道隧道建立失败
```

- **原因**：
  - 设备未连接或未被识别
  - USB 数据线问题
  - ADB 服务崩溃
- **排查**：
  ```bash
  adb kill-server
  adb start-server
  adb devices -l  # 应显示目标设备
  ```

**3. TCP 服务启动**

```
[TouchPad] 服务已启动 (仅USB模式)
```

- **含义**：TCP 服务已在 9527 端口监听
- **如果没有此日志**：检查权限问题或端口占用

**4. 客户端连接**

```
[TouchPad] 未找到 adb 可执行文件
[TouchPad] USB 命令通道隧道已建立: XXXXX
```

- **正常流程**：隧道建立 → 等待连接 → 接收命令
- **问题排查**：
  - 如果没有第二条日志，说明隧道建立失败

**5. 屏幕镜像**

```
[Streamer] Starting video service...
[Streamer] Video server listening on port 9528
[Streamer] Client connected
[Streamer] Resolution: 2560x1600 (Scale: 2.0)
[Streamer] CGDisplayStream started successfully at 2560x1600
```

- **正常流程**：
  1. 服务启动
  2. 客户端连接
  3. 分辨率确定
  4. 开始捕获
- **问题排查**：
  - `ERROR: CGDisplayStream start failed` → 缺少屏幕录制权限
    ```
    系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 TouchPad.app
    ```

**6. 帧编码**

```
[Streamer] Encode frame failed: -12345
```

- **含义**：H.264 编码失败
- **常见错误码**：
  - `-8960` (paramErr)：参数错误
  - `-12000` (kVTInvalidSessionErr)：编码会话无效
- **解决**：重启应用

**7. 连接断开**

```
[TouchPad] Client disconnected
```

- **原因**：
  - 正常断开（拔出数据线）
  - 网络问题导致断开
- **处理**：自动重新监听，等待新连接

#### C. 常见错误日志组合

**场景1：屏幕镜像黑屏**

```
[Streamer] ERROR: CGDisplayStream start failed
```

**原因**：缺少屏幕录制权限

**解决**：

```bash
System Preferences → Security & Privacy → Screen Recording → Add TouchPad
```

---

**场景2：触控笔无反应**

```
D/MainActivity: TextureView created
// 但没有 D/MainActivity: Received cmd: PEN_DOWN,...
```

**原因**：

1. 触控笔驱动未启用
2. 输入模式设置错误
3. DrawingPadView 未获得焦点

**排查**：

```kotlin
// 在 DrawingPadView.kt 中添加日志
override fun onTouchEvent(event: MotionEvent): Boolean {
    Log.d("DrawingPadView", "Tool type: ${event.getToolType(0)}, " +
                             "Expected: ${MotionEvent.TOOL_TYPE_STYLUS}")
    // ...
}
```

---

**场景3：延迟过高**

```
[Streamer] Resolution: 2560x1600  // 超高分辨率
D/MainActivity: Video size changed: 2560x1600
```

**原因**：屏幕分辨率过高，编码/解码耗时过长

**优化**：

- 降低屏幕分辨率（Mac 端）
- 调整 H.264 码率（降低至 4-6 Mbps）
- 检查网络延迟（USB 隧道质量）

---

### 三、调试技巧

#### 1. 启用详细日志（Android）

在 `MainActivity.kt` 开头添加：

```kotlin
// 启用 Log 输出
android.util.Log.isLoggable("MainActivity", android.util.Log.DEBUG) // true
```

#### 2. 网络流量监控

```bash
# macOS 端监控 9527 端口
sudo tcpdump -i lo0 -n 'port 9527 or port 9528'

# 查看 ADB 隧道状态
adb reverse -l
```

#### 3. 性能分析

**Android 端**：

```bash
# 使用 Android Profiler
# Android Studio → View → Tool Windows → Profiler
# 查看 CPU/内存/网络使用
```

**macOS 端**：

```bash
# 查看进程信息
ps aux | grep TouchPad
top -p $(pgrep -f TouchPad)
```

#### 4. Strace 追踪（高级）

```bash
# 追踪 macOS 端系统调用
sudo dtrace -p $(pgrep -f TouchPad) -n 'syscall:::-entry { @[execname] = count() }'
```

---

## V.可能出现的问题

### 问题 1：设备连接后立即断开

**症状**：

```
D/MainActivity: USB 连接成功
// 几秒后自动断开，循环尝试
```

**可能原因**：

1. **Android 端读取线程崩溃**

   ```kotlin
   // 原因：bufferReader.readLine() 抛出异常
   private fun startCommandListener(inputStream: java.io.InputStream) {
       try {
           val reader = java.io.BufferedReader(inputStream.reader())
           while (true) {
               val line = reader.readLine() ?: break  // 网络异常时为 null
           }
       } catch (e: Exception) {}  // 异常被吞掉
   }
   ```
2. **macOS 端 TCP 服务未保持连接**

**解决**：

- 检查 Android 日志中是否有异常堆栈
- 确保 macOS 端 `startTcpServer()` 的 `while (true)` 循环持续运行
- 尝试增加日志输出以定位断开点

---

### 问题 2：触控笔输入偏移

**症状**：触控笔在平板上的位置与 Mac 上鼠标位置不一致

**原因分析**：

1. **Android 设备屏幕宽高比 ≠ Mac 屏幕宽高比**

   ```
   Android: 16:10 (2560x1600)
   Mac:    16:10 (1440x900)
   // 虽然比例相同，但如果计算错误仍会偏移
   ```
2. **缩放因子 (backingScaleFactor) 未正确处理**

   ```swift
   // 错误
   let x = (normX / COORD_SCALE) * screen.frame.width  // 逻辑像素

   // 正确
   let scale = screen.backingScaleFactor
   let x = (normX / COORD_SCALE) * screen.frame.width * scale  // 物理像素
   ```
3. **标准化坐标计算错误**

   ```kotlin
   // 错误
   val normX = (event.x / width * 100).toInt()  // 0-100

   // 正确
   val normX = (event.x / width * 10000).toInt()  // 0-10000
   ```

**排查步骤**：

```swift
// 在 handleStylus 中添加日志
NSLog("[Debug] normX=\(x), screen.width=\(screen.frame.width), " +
      "scale=\(screen.backingScaleFactor), finalX=\(point.x)")
```

**校准方法**：

1. 在 Android 平板左上角点击，记录 Mac 上显示的坐标
2. 在 Android 平板右下角点击，记录 Mac 上显示的坐标
3. 计算偏移量和缩放比例，调整公式

---

### 问题 3：屏幕镜像卡顿或无画面

**症状**：

- 启用屏幕镜像后，Android 端显示黑屏或持续缓冲
- Mac 端 CPU 飙升

**原因分析**：

1. **网络延迟过高**

   - USB 隧道传输速率不足
   - H.264 码率过高导致卡顿
2. **分辨率过高**

   - Mac 屏幕物理分辨率 × backingScaleFactor 可能超过 4K
   - 编码/解码性能瓶颈
3. **缺少屏幕录制权限**

   ```
   [Streamer] ERROR: CGDisplayStream start failed (error 1004)
   ```

**排查步骤**：

```bash
# 1. 检查权限
System Preferences → Security & Privacy → Screen Recording

# 2. 监控 CPU/内存
top -p $(pgrep -f TouchPad)

# 3. 检查网络
adb shell ping 127.0.0.1
```

**优化方法**：

```swift
// 降低编码码率
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, 
                      value: NSNumber(value: 4000000))  // 4Mbps

// 增加关键帧间隔（降低帧率，减少网络压力）
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, 
                      value: NSNumber(value: 60))  // 2秒一个关键帧
```

---

### 问题 4：手势识别不稳定

**症状**：

- 两指缩放有时识别，有时不识别
- 滑动手势触发不一致

**原因**：

1. **手势灵敏度阈值不合理**

   ```swift
   enum Sensitivity {
       case low: swipeThreshold = 90    // 像素
       case medium: swipeThreshold = 60
       case high: swipeThreshold = 40
   }
   ```
2. **触控点追踪 ID 丢失**

   ```kotlin
   // 多点触控中，如果 ID 不一致，无法追踪
   for (i in 0 until count) {
       val id = event.getPointerId(i)  // 必须与前次一致
   }
   ```
3. **手势冷却时间过长**

   ```swift
   let gestureCooldown: TimeInterval = 0.8  // 800ms 内无法连续识别
   ```

**调试**：

```swift
// 在 handleTouch 中添加日志
NSLog("[Debug] points=\(points.count), " +
      "prevSpan=\(touchState.prevSpan ?? 0), " +
      "gestureTriggered=\(touchState.gestureTriggered)")
```

**优化**：

```swift
// 调整灵敏度
AppState.shared.sensitivity = .high  // 0.5倍阈值

// 或手动调整阈值
let customThreshold: CGFloat = 30
```

---

### 问题 5：ADB 命令超时或无响应

**症状**：

```
[TouchPad] 未找到 adb 可执行文件
// 或 adb 命令卡住，等待很久
```

**原因**：

1. **ADB 守护进程崩溃**

   ```bash
   adb: command not found
   ```
2. **设备断开或进入休眠**

   ```bash
   adb: error: no devices/emulators found
   ```
3. **权限问题**

   ```bash
   adb: error: insufficient permissions for device
   ```

**解决**：

```bash
# 重启 ADB 服务
adb kill-server
adb start-server

# 检查设备权限
adb shell id

# 重新插拔 USB 数据线
# 在 Android 设备上允许 USB 调试
```

---

## VI.调参指南

### 三、性能优化建议

#### 1. 减少网络流量

```swift
// 优化 1：合并多个小数据包
// 【不优化】每个事件单独发送
sendCommandToClient("PEN_MOVE,5000,5000\n")
sendCommandToClient("PEN_MOVE,5001,5001\n")

// 【优化】批量发送
var buffer = ""
buffer += "PEN_MOVE,5000,5000\n"
buffer += "PEN_MOVE,5001,5001\n"
Darwin.send(sock, [UInt8](buffer.utf8), buffer.utf8.count, 0)
```

#### 2. 降低屏幕镜像延迟

```swift
// 优化分辨率与码率的平衡
let maxBitrate = 6000000  // 6Mbps
let frameDuration = 1.0 / 30.0  // 30fps

VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, 
                      value: NSNumber(value: maxBitrate))
```

#### 3. 内存管理

```kotlin
// Android 端定期清理缓冲区
private fun cleanupBuffers() {
    System.gc()  // 建议垃圾回收
    Runtime.getRuntime().gc()
}
```

---

### 四、单元测试框架

**macOS 端测试（Swift）**：

```swift
import XCTest

class MouseControllerTests: XCTestCase {
  
    func testStylusDownEvent() {
        let cmd = "PEN_DOWN,5000,5000"
        let parts = cmd.split(separator: ",")
  
        handleStylus(cmd: cmd, parts: parts)
  
        XCTAssertTrue(isStylusDown, "Stylus should be down")
    }
  
    func testCoordinateConversion() {
        let normX: Double = 5000.0
        let normY: Double = 5000.0
  
        // 假设屏幕宽高为 1440x900
        let expectedX = (normX / COORD_SCALE) * 1440.0
        let expectedY = (normY / COORD_SCALE) * 900.0
  
        XCTAssertEqual(expectedX, 720.0, accuracy: 1.0)
        XCTAssertEqual(expectedY, 450.0, accuracy: 1.0)
    }
}
```

**Android 端测试（Kotlin）：**

```Kotlin
import org.junit.Test
import org.junit.Assert.*

class DrawingPadViewTest {
  
    @Test
    fun testNormalizedCoordinateCalculation() {
        val width = 2560
        val height = 1600
        val eventX = 1280f
        val eventY = 800f
  
        val normX = (eventX / width * 10000f).toInt()
        val normY = (eventY / height * 10000f).toInt()
  
        assertEquals(5000, normX)
        assertEquals(5000, normY)
    }
}
```

### 五、跨版本兼容性

#### Android 版本适配

```kotlin
// 检查 Android 版本
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
    // Android 11+ 特定代码
    window.insetsController?.show(WindowInsets.Type.statusBars())
} else {
    // Android 10 及以下
    @Suppress("DEPRECATION")
    window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
}
```

#### macOS 版本适配

```swift
// 检查 macOS 版本
if #available(macOS 11.0, *) {
    // macOS 11+ 特定代码
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_H264EntropyMode,
                          value: kVTH264EntropyMode_CABAC)
}
```

---
