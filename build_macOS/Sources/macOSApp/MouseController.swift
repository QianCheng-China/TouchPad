// MouseController.swift
// 完整文件：包含 HIDSymbolLoader（动态查找私有符号）与平滑回退的原生缩放实现
// 说明：优先尝试私有 IOHIDEvent 接口（若可用），否则使用智能平滑回退（Command/Control/Alt/Keyboard）。

import Foundation
import Cocoa
import ApplicationServices
import Darwin

let COORD_SCALE: CGFloat = 10000.0
var isStylusDown: Bool = false

struct TouchPoint { var id: Int; var x: CGFloat; var y: CGFloat }

// MARK: - 私有 API 函数类型定义（与常见头文件签名对齐）
typealias IOHIDEventCreateMagnifyEventFunc = @convention(c) (CFAllocator?, UInt64, Double, UInt32) -> UnsafeMutableRawPointer?
typealias IOHIDEventSystemClientDispatchEventFunc = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
typealias IOHIDEventSystemClientCreateFunc = @convention(c) (CFAllocator?) -> OpaquePointer?

// MARK: - HIDSymbolLoader: 动态查找并缓存私有符号
final class HIDSymbolLoader {
    static let shared = HIDSymbolLoader()

    private(set) var createMagnifyEventFunc: IOHIDEventCreateMagnifyEventFunc? = nil
    private(set) var dispatchEventFunc: IOHIDEventSystemClientDispatchEventFunc? = nil
    private(set) var createClientFunc: IOHIDEventSystemClientCreateFunc? = nil

    private var didTryLoad = false
    private let lock = NSLock()

    // 候选路径（按优先级排列，可根据目标 macOS 版本调整）
    private let candidatePaths: [String] = [
        "/System/Library/PrivateFrameworks/IOHIDFamily.framework/IOHIDFamily",
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/usr/lib/libIOKit.dylib",
        "/System/Library/PrivateFrameworks",
        "/usr/lib",
        "/System/Library/Frameworks"
    ]

    private init() {}

    /// 线程安全、幂等的加载入口
    func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        if didTryLoad { return }
        didTryLoad = true

        for path in candidatePaths {
            probePath(path)
            if createMagnifyEventFunc != nil && dispatchEventFunc != nil && createClientFunc != nil { return }
        }

        // 枚举 PrivateFrameworks 和 /usr/lib 目录以增加命中率（可能较慢）
        let privateDir = "/System/Library/PrivateFrameworks"
        if FileManager.default.fileExists(atPath: privateDir) {
            enumerateAndProbe(directory: privateDir)
        }

        let usrLib = "/usr/lib"
        if FileManager.default.fileExists(atPath: usrLib) {
            enumerateAndProbe(directory: usrLib)
        }
    }

    private func probePath(_ path: String) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                enumerateAndProbe(directory: path)
            } else {
                tryLoadSymbols(from: path)
            }
        }
    }

    private func enumerateAndProbe(directory: String) {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return }
        for case let item as String in enumerator {
            if item.hasSuffix(".dylib") || item.hasSuffix(".framework") || item.hasSuffix(".so") || item.hasSuffix(".bundle") {
                let full = (directory as NSString).appendingPathComponent(item)
                tryLoadSymbols(from: full)
                if createMagnifyEventFunc != nil && dispatchEventFunc != nil && createClientFunc != nil { return }
            }
        }
    }

    private func tryLoadSymbols(from path: String) {
        // 使用系统 Darwin 提供的 dlopen/dlsym/dlerror
        guard let handle = Darwin.dlopen(path, RTLD_NOW) else {
            if let err = Darwin.dlerror() {
                let msg = String(cString: err)
                NSLog("[HIDLoader] dlopen failed for \(path): \(msg)")
            } else {
                NSLog("[HIDLoader] dlopen failed for \(path): unknown error")
            }
            return
        }

        if createMagnifyEventFunc == nil {
            if let sym = Darwin.dlsym(handle, "IOHIDEventCreateMagnifyEvent") {
                createMagnifyEventFunc = unsafeBitCast(sym, to: IOHIDEventCreateMagnifyEventFunc.self)
                NSLog("[HIDLoader] loaded IOHIDEventCreateMagnifyEvent from \(path)")
            }
        }

        if dispatchEventFunc == nil {
            if let sym = Darwin.dlsym(handle, "IOHIDEventSystemClientDispatchEvent") {
                dispatchEventFunc = unsafeBitCast(sym, to: IOHIDEventSystemClientDispatchEventFunc.self)
                NSLog("[HIDLoader] loaded IOHIDEventSystemClientDispatchEvent from \(path)")
            }
        }

        if createClientFunc == nil {
            if let sym = Darwin.dlsym(handle, "IOHIDEventSystemClientCreate") {
                createClientFunc = unsafeBitCast(sym, to: IOHIDEventSystemClientCreateFunc.self)
                NSLog("[HIDLoader] loaded IOHIDEventSystemClientCreate from \(path)")
            }
        }

        // 不 dlclose 系统库以避免潜在问题
    }
}

// MARK: - IOHIDEvent 系统客户端句柄（使用 loader 提供的 createClientFunc）
private var hidEventSystemClient: OpaquePointer? = nil

func initHIDEventSystem() {
    HIDSymbolLoader.shared.loadIfNeeded()

    if hidEventSystemClient != nil { return }

    if let createClient = HIDSymbolLoader.shared.createClientFunc {
        hidEventSystemClient = createClient(nil)
        if hidEventSystemClient == nil {
            NSLog("[TouchPad] 无法创建 IOHIDEventSystemClient via loaded symbol")
        } else {
            NSLog("[TouchPad] IOHIDEvent 系统初始化成功 via loaded symbol")
        }
        return
    }

    // 备用尝试：直接从常见路径加载 create 函数
    if let handle = Darwin.dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
       let sym = Darwin.dlsym(handle, "IOHIDEventSystemClientCreate") {
        let createClient = unsafeBitCast(sym, to: IOHIDEventSystemClientCreateFunc.self)
        hidEventSystemClient = createClient(nil)
        if hidEventSystemClient == nil {
            NSLog("[TouchPad] 无法创建 IOHIDEventSystemClient from IOKit")
        } else {
            NSLog("[TouchPad] IOHIDEvent 系统初始化成功 from IOKit")
        }
    } else {
        NSLog("[TouchPad] IOHIDEventSystemClientCreate not available; native magnify may be unavailable")
    }
}

// MARK: - 原生缩放注入（优先私有 API；不可用时回退到平滑策略）
func postNativeMagnify(magnification: Double) {
    // 1) 尝试私有 API（若 loader 已加载并 client 可用）
    HIDSymbolLoader.shared.loadIfNeeded()
    if hidEventSystemClient == nil {
        initHIDEventSystem()
    }
    if let client = hidEventSystemClient,
       let createEvent = HIDSymbolLoader.shared.createMagnifyEventFunc,
       let dispatchEvent = HIDSymbolLoader.shared.dispatchEventFunc {
        let timestamp = mach_absolute_time()
        if let rawEventPtr = createEvent(nil, timestamp, magnification, 0) {
            // 桥接并交付（假设 Create* 返回 retained）
            let unmanagedEvent = Unmanaged<CFTypeRef>.fromOpaque(rawEventPtr)
            let cfEvent = unmanagedEvent.takeRetainedValue()
            dispatchEvent(client, rawEventPtr)
            _ = cfEvent
            return
        } else {
            NSLog("[TouchPad] IOHIDEventCreateMagnifyEvent returned nil; falling back to smooth fallback")
        }
    }

    // 2) 私有 API 不可用或失败：使用智能回退（按前台应用选择最佳策略）
    smartZoomForFrontApp(magnification: magnification)
}

// MARK: - 平滑回退策略（智能选择并平滑发送事件）

/// 根据前台应用选择最合适的缩放策略并执行（平滑回退）
func smartZoomForFrontApp(magnification: Double) {
    // 计算绝对缩放量并基于灵敏度决定步数
    let absMag = max(0.0, abs(magnification))
    let sensitivity = AppState.shared.sensitivity
    let baseSteps: Int
    switch sensitivity {
    case .low: baseSteps = 3
    case .medium: baseSteps = 6
    case .high: baseSteps = 10
    }

    // 步数与 magnification 成正比（限制范围）
    let steps = max(1, Int(Double(baseSteps) * min(4.0, absMag * 10.0)))
    // 每步的滚轮行数（经验值）
    let perStepLines: Int32 = Int32((absMag > 0.15) ? 8 : (absMag > 0.06 ? 4 : 2))
    let direction = magnification > 0 ? 1 : -1

    // 选择策略：优先按前台应用
    let strategy = getZoomStrategy()
    switch strategy {
    case .keyboard:
        // 使用键盘缩放（Command + = / Command + -），分多次发送
        for i in 0..<steps {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.02) {
                postKeyboardShortcut(keyCode: direction > 0 ? 0x18 : 0x1B, modifiers: .maskCommand)
            }
        }
    case .altScroll:
        // Photoshop 等使用 Alt + 滚轮
        for i in 0..<steps {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.015) {
                postAltScroll(lines: Int32(direction) * perStepLines)
            }
        }
    case .controlScroll:
        // 系统缩放（辅助功能）: Control + 滚轮
        for i in 0..<steps {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.015) {
                postControlZoom(lines: Int32(direction) * perStepLines)
            }
        }
    case .commandScroll:
        // 浏览器/大多数应用: Command + 滚轮（平滑）
        smoothCommandScroll(totalSteps: steps, perStepLines: perStepLines * Int32(direction))
    }
}

/// 平滑发送 Command+滚轮 的实现：把 totalSteps 次小滚轮事件分散在短时间内
func smoothCommandScroll(totalSteps: Int, perStepLines: Int32) {
    let cappedSteps = min(max(1, totalSteps), 60)
    // 根据灵敏度调整间隔
    let intervalBase: Double
    switch AppState.shared.sensitivity {
    case .low: intervalBase = 0.018
    case .medium: intervalBase = 0.012
    case .high: intervalBase = 0.008
    }
    for i in 0..<cappedSteps {
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * intervalBase) {
            postCommandScroll(lines: perStepLines)
        }
    }
}

// MARK: - 手势方向锁
enum GestureLock {
    case none
    case swipe
    case pinch
}

class TouchState {
    var points: [Int: TouchPoint] = [:]
    var lastFingerCount: Int = 0

    // 用于滚动/缩放 (增量计算)
    var prevCentroid: CGPoint? = nil
    var prevSpan: CGFloat? = nil

    // 用于三指/四指手势 (累积判定)
    var startCentroid: CGPoint? = nil
    var startSpan: CGFloat? = nil
    var gestureTriggered: Bool = false

    // 手指稳定期: 手指数变化后跳过前几帧
    var settleFrames: Int = 0

    // 缩放累积器
    var zoomAccumulator: CGFloat = 0

    // 四指手势专用：起始最大点间距
    var startMaxSpan: CGFloat? = nil

    // 手势方向锁 (四指)
    var gestureLock: GestureLock = .none

    // 手势冷却期 (防止连续触发)
    var gestureCooldownUntil: TimeInterval = 0

    func reset() {
        points.removeAll()
        prevCentroid = nil; prevSpan = nil
        startCentroid = nil
        startSpan = nil
        gestureTriggered = false
        settleFrames = 3
        zoomAccumulator = 0
        startMaxSpan = nil
        gestureLock = .none
        gestureCooldownUntil = 0
    }
}
let touchState = TouchState()

// 系统手势状态机 - 用于返回手势
enum SystemGestureState {
    case normal
    case missionControl
    case appExpose
    case launchpad
    case showDesktop
}
var systemGestureState: SystemGestureState = .normal

// 缩放策略枚举 (提前定义，供全局变量引用)
enum ZoomStrategy {
    case keyboard        // Command + = / Command + -
    case commandScroll   // Command + 滚轮
    case controlScroll   // Control + 滚轮
    case altScroll       // Alt + 滚轮 (Photoshop等)
}

// 键盘缩放节流
var lastKeyboardZoomTime: TimeInterval = 0
let keyboardZoomThrottle: TimeInterval = 0.15

// 缓存前台应用检测结果
var cachedZoomStrategy: ZoomStrategy? = nil
var lastZoomCacheTime: TimeInterval = 0
let zoomCacheTTL: TimeInterval = 2.0

// 手势冷却期时长
let gestureCooldown: TimeInterval = 0.4

// MARK: - 命令处理入口
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

// MARK: - 触控笔逻辑
func handleStylus(cmd: String, parts: [String.SubSequence]) {
    guard parts.count >= 3,
          let x = Double(String(parts[1])),
          let y = Double(String(parts[2])) else { return }

    guard let screen = NSScreen.main else { return }

    let point = CGPoint(
        x: (x / COORD_SCALE) * screen.frame.width,
        y: (y / COORD_SCALE) * screen.frame.height
    )

    switch String(parts[0]) {
    case "PEN_DOWN":
        isStylusDown = true
        systemGestureState = .normal
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

// MARK: - 触摸逻辑
func handleTouch(cmd: String, parts: [String.SubSequence]) {
    guard parts.count >= 2 else { return }
    guard let count = Int(String(parts[1])) else { return }

    if count != touchState.lastFingerCount {
        touchState.reset()
        touchState.lastFingerCount = count
    }

    if count > 4 { return }

    touchState.points.removeAll()
    var iterator = parts.makeIterator()
    _ = iterator.next(); _ = iterator.next()

    while let idStr = iterator.next(),
          let xStr = iterator.next(),
          let yStr = iterator.next(),
          let id = Int(String(idStr)),
          let x = Double(String(xStr)),
          let y = Double(String(yStr)) {
        touchState.points[id] = TouchPoint(id: id, x: x, y: y)
    }

    let centroid = calculateCentroid(touchState.points)
    let span = calculateSpan(touchState.points)

    if touchState.prevCentroid == nil {
        touchState.startCentroid = centroid
        touchState.startSpan = span
        touchState.startMaxSpan = calculateMaxSpan(touchState.points)
        touchState.prevCentroid = centroid
        touchState.prevSpan = span
        return
    }

    if touchState.settleFrames > 0 {
        touchState.settleFrames -= 1
        touchState.prevCentroid = centroid
        touchState.prevSpan = span
        touchState.startCentroid = centroid
        touchState.startSpan = span
        touchState.startMaxSpan = calculateMaxSpan(touchState.points)
        return
    }

    switch count {
    case 1:
        handleOneFinger(centroid: centroid)
    case 2:
        handleTwoFingers(centroid: centroid, span: span)
    case 3:
        handleThreeFingerSwipe(centroid: centroid)
    case 4:
        handleFourFingers(centroid: centroid, span: span)
    default: break
    }
}

// MARK: - 单指：光标移动
func handleOneFinger(centroid: CGPoint) {
    guard let screen = NSScreen.main else { return }
    if let point = touchState.points.values.first {
        let screenPoint = CGPoint(
            x: (point.x / COORD_SCALE) * screen.frame.width,
            y: (point.y / COORD_SCALE) * screen.frame.height
        )
        postMouseEvent(type: .mouseMoved, location: screenPoint, button: .left)
    }
    touchState.gestureTriggered = false
}

// MARK: - 双指：滚动 / 缩放
func handleTwoFingers(centroid: CGPoint, span: CGFloat) {
    guard let prevCentroid = touchState.prevCentroid,
          let prevSpanVal = touchState.prevSpan else { return }

    let dy = centroid.y - prevCentroid.y
    let dx = centroid.x - prevCentroid.x
    let deltaSpan = span - prevSpanVal

    let zoomThreshold = AppState.shared.sensitivity.zoomStepThreshold

    // 缩放检测：span变化超过阈值的一半
    if abs(deltaSpan) > zoomThreshold * 0.5 {
        handleZoom(deltaSpan: deltaSpan, span: span, centroid: centroid)
    }
    // 滚动检测：有位移且span变化不大
    else if abs(dy) > 1.0 || abs(dx) > 1.0 {
        postScrollEvent(dy: -dy * 0.5, dx: -dx * 0.5)
        touchState.prevCentroid = centroid
        touchState.prevSpan = span
    }
}

// MARK: - 缩放处理 (多策略方案 + 原生缩放)
func handleZoom(deltaSpan: CGFloat, span: CGFloat, centroid: CGPoint) {
    let zoomMode = AppState.shared.zoomMode
    let zoomStepThreshold = AppState.shared.sensitivity.zoomStepThreshold

    touchState.zoomAccumulator += deltaSpan

    // 原生缩放模式不需要累积阈值，直接根据 deltaSpan 注入
    if zoomMode == .native || zoomMode == .smart {
        // 原生缩放: 根据 deltaSpan 计算缩放比例
        let magnification = Double(deltaSpan / 300.0)
        if abs(magnification) > 0.01 {
            postNativeMagnify(magnification: magnification)
        }
        touchState.zoomAccumulator = 0
        touchState.prevSpan = span
        return
    }

    if abs(touchState.zoomAccumulator) < zoomStepThreshold {
        touchState.prevSpan = span
        return
    }

    let zoomIn = touchState.zoomAccumulator > 0

    switch zoomMode {
    case .system:
        postControlZoom(lines: zoomIn ? 6 : -6)
    case .browser:
        postCommandScroll(lines: zoomIn ? 10 : -10)
    case .keyboard:
        postKeyboardZoom(zoomIn: zoomIn)
    case .native:
        break
    case .smart:
        break
    }

    touchState.zoomAccumulator -= zoomIn ? zoomStepThreshold : -zoomStepThreshold
    touchState.prevSpan = span
}

// MARK: - 智能缩放: 根据前台应用选择最佳缩放策略
func getZoomStrategy() -> ZoomStrategy {
    let now = Date().timeIntervalSince1970
    if let cached = cachedZoomStrategy, now - lastZoomCacheTime < zoomCacheTTL {
        return cached
    }

    var bundleId: String? = nil
    if Thread.isMainThread {
        bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    } else {
        DispatchQueue.main.sync {
            bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    guard let bid = bundleId?.lowercased() else {
        cachedZoomStrategy = .commandScroll
        lastZoomCacheTime = now
        return .commandScroll
    }

    let strategy: ZoomStrategy

    let keyboardZoomApps = [
        "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
        "com.microsoft.outlook", "com.microsoft.onenote",
        "com.microsoft.vscode", "com.todesktop", "com.github.atom",
        "com.sublimetext", "com.jetbrains", "com.google.android.studio",
        "com.apple.dt.xcode",
        "md.obsidian", "notion.id",
        "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote",
    ]

    let altScrollApps = [
        "com.adobe.photoshop", "com.adobe.illustrator", "com.adobe.indesign",
        "com.adobe.lightroom",
    ]

    let commandScrollApps = [
        "com.apple.safari", "com.google.chrome", "com.microsoft.edge",
        "org.mozilla.firefox", "com.brave.browser", "com.operasoftware.opera",
        "com.apple.preview", "com.apple.finder", "com.apple.mail",
        "com.apple.notes", "com.apple.textedit",
    ]

    if keyboardZoomApps.contains(where: { bid.contains($0) }) {
        strategy = .keyboard
    } else if altScrollApps.contains(where: { bid.contains($0) }) {
        strategy = .altScroll
    } else if commandScrollApps.contains(where: { bid.contains($0) }) {
        strategy = .commandScroll
    } else {
        strategy = .commandScroll
    }

    cachedZoomStrategy = strategy
    lastZoomCacheTime = now
    return strategy
}

// MARK: - 保留旧函数用于兼容
func shouldUseKeyboardZoom() -> Bool {
    return getZoomStrategy() == .keyboard
}

// MARK: - 键盘缩放 (Command + = / Command + -)
func postKeyboardZoom(zoomIn: Bool) {
    let now = Date().timeIntervalSince1970
    if now - lastKeyboardZoomTime < keyboardZoomThrottle { return }
    lastKeyboardZoomTime = now

    let keyCode: CGKeyCode = zoomIn ? 0x18 : 0x1B
    postKeyboardShortcut(keyCode: keyCode, modifiers: .maskCommand)
}

// MARK: - 三指滑动
func handleThreeFingerSwipe(centroid: CGPoint) {
    let now = Date().timeIntervalSince1970
    if now < touchState.gestureCooldownUntil { return }

    guard let start = touchState.startCentroid else { return }

    let totalDy = centroid.y - start.y
    let totalDx = centroid.x - start.x
    let threshold = AppState.shared.sensitivity.swipeThreshold

    if abs(totalDy) > abs(totalDx) {
        if totalDy < -threshold {
            showMissionControl()
            touchState.gestureCooldownUntil = now + gestureCooldown
            resetGestureState(centroid: centroid)
        } else if totalDy > threshold {
            showAppExpose()
            touchState.gestureCooldownUntil = now + gestureCooldown
            resetGestureState(centroid: centroid)
        }
    } else {
        if totalDx < -threshold {
            switchDesktop(direction: .left)
            touchState.gestureCooldownUntil = now + gestureCooldown
            resetGestureState(centroid: centroid)
        } else if totalDx > threshold {
            switchDesktop(direction: .right)
            touchState.gestureCooldownUntil = now + gestureCooldown
            resetGestureState(centroid: centroid)
        }
    }
}

// MARK: - 四指手势 (方向锁定 + 冷却期 + maxSpan + 相对变化率)
func handleFourFingers(centroid: CGPoint, span: CGFloat) {
    let now = Date().timeIntervalSince1970
    if now < touchState.gestureCooldownUntil { return }

    guard let start = touchState.startCentroid,
          let startMaxSpan = touchState.startMaxSpan else { return }

    let totalDy = centroid.y - start.y
    let totalDx = centroid.x - start.x
    let currentMaxSpan = calculateMaxSpan(touchState.points)
    let spanChange = currentMaxSpan - startMaxSpan
    let totalMovement = sqrt(totalDx * totalDx + totalDy * totalDy)

    let swipeThreshold = AppState.shared.sensitivity.swipeThreshold

    let spanRate = startMaxSpan > 0 ? abs(spanChange) / startMaxSpan : 0
    let moveRate = startMaxSpan > 0 ? totalMovement / startMaxSpan : 0

    if touchState.gestureLock == .none {
        if spanRate > 0.03 && spanRate > moveRate * 3 {
            touchState.gestureLock = .pinch
        } else if totalMovement > swipeThreshold * 0.7 {
            touchState.gestureLock = .swipe
        } else {
            return
        }
    }

    if touchState.gestureLock == .pinch {
        if spanRate > 0.08 {
            if spanChange < 0 {
                if systemGestureState == .showDesktop {
                    showDesktop()
                    systemGestureState = .normal
                } else {
                    openLaunchpad()
                    systemGestureState = .launchpad
                }
            } else {
                if systemGestureState == .launchpad {
                    postEscapeKey()
                    systemGestureState = .normal
                } else {
                    showDesktop()
                    systemGestureState = .showDesktop
                }
            }
            touchState.gestureCooldownUntil = now + gestureCooldown
            touchState.gestureLock = .none
            resetGestureState(centroid: centroid)
        }
    } else if touchState.gestureLock == .swipe {
        if abs(totalDy) > abs(totalDx) {
            if totalDy < -swipeThreshold {
                if systemGestureState == .appExpose {
                    postEscapeKey()
                    systemGestureState = .normal
                } else {
                    showMissionControl()
                    systemGestureState = .missionControl
                }
                touchState.gestureCooldownUntil = now + gestureCooldown
                touchState.gestureLock = .none
                resetGestureState(centroid: centroid)
            } else if totalDy > swipeThreshold {
                if systemGestureState == .missionControl {
                    postEscapeKey()
                    systemGestureState = .normal
                } else {
                    showAppExpose()
                    systemGestureState = .appExpose
                }
                touchState.gestureCooldownUntil = now + gestureCooldown
                touchState.gestureLock = .none
                resetGestureState(centroid: centroid)
            }
        } else {
            if totalDx < -swipeThreshold {
                switchDesktop(direction: .left)
                touchState.gestureCooldownUntil = now + gestureCooldown
                touchState.gestureLock = .none
                resetGestureState(centroid: centroid)
            } else if totalDx > swipeThreshold {
                switchDesktop(direction: .right)
                touchState.gestureCooldownUntil = now + gestureCooldown
                touchState.gestureLock = .none
                resetGestureState(centroid: centroid)
            }
        }
    }
}

// MARK: - 重置手势状态
func resetGestureState(centroid: CGPoint) {
    touchState.gestureTriggered = false
    touchState.startCentroid = centroid
    touchState.startSpan = touchState.prevSpan
    touchState.startMaxSpan = calculateMaxSpan(touchState.points)
}

// MARK: - 辅助计算
func calculateCentroid(_ points: [Int: TouchPoint]) -> CGPoint {
    guard !points.isEmpty else { return .zero }
    var sumX: CGFloat = 0, sumY: CGFloat = 0
    for p in points.values { sumX += p.x; sumY += p.y }
    return CGPoint(x: sumX / CGFloat(points.count), y: sumY / CGFloat(points.count))
}

func calculateSpan(_ points: [Int: TouchPoint]) -> CGFloat {
    guard points.count >= 2 else { return 0 }
    let center = calculateCentroid(points)
    var distSum: CGFloat = 0
    for p in points.values {
        let dx = p.x - center.x
        let dy = p.y - center.y
        distSum += sqrt(dx * dx + dy * dy)
    }
    return distSum / CGFloat(points.count)
}

func calculateMaxSpan(_ points: [Int: TouchPoint]) -> CGFloat {
    guard points.count >= 2 else { return 0 }
    let pts = Array(points.values)
    var maxDist: CGFloat = 0
    for i in 0..<pts.count {
        for j in (i+1)..<pts.count {
            let dx = pts[i].x - pts[j].x
            let dy = pts[i].y - pts[j].y
            let dist = sqrt(dx * dx + dy * dy)
            if dist > maxDist { maxDist = dist }
        }
    }
    return maxDist
}

// MARK: - 底层事件发送
func postMouseEvent(type: CGEventType, location: CGPoint, button: CGMouseButton) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
    event.post(tap: .cghidEventTap)
}

func postScrollEvent(dy: CGFloat, dx: CGFloat) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
    event.flags = []
    event.post(tap: .cghidEventTap)
}

// 系统缩放: Control + 滚轮
func postControlZoom(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskControl
    event.post(tap: .cgSessionEventTap)
}

// 浏览器缩放: Command + 滚轮
func postCommandScroll(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskCommand
    event.post(tap: .cgSessionEventTap)
}

// Alt + 滚轮 (Photoshop等应用的缩放)
func postAltScroll(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskAlternate
    event.post(tap: .cgSessionEventTap)
}

// MARK: - 键盘快捷键发送
func postKeyboardShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)

    let controlKey: CGKeyCode = 0x3B
    let shiftKey: CGKeyCode = 0x38
    let optionKey: CGKeyCode = 0x3A
    let commandKey: CGKeyCode = 0x37

    var currentFlags: CGEventFlags = []

    if modifiers.contains(.maskControl) {
        currentFlags.insert(.maskControl)
        let event = CGEvent(keyboardEventSource: src, virtualKey: controlKey, keyDown: true)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }
    if modifiers.contains(.maskShift) {
        currentFlags.insert(.maskShift)
        let event = CGEvent(keyboardEventSource: src, virtualKey: shiftKey, keyDown: true)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }
    if modifiers.contains(.maskAlternate) {
        currentFlags.insert(.maskAlternate)
        let event = CGEvent(keyboardEventSource: src, virtualKey: optionKey, keyDown: true)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }
    if modifiers.contains(.maskCommand) {
        currentFlags.insert(.maskCommand)
        let event = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }

    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    keyDown?.flags = modifiers
    keyDown?.post(tap: .cghidEventTap)
    usleep(5000)

    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    keyUp?.flags = modifiers
    keyUp?.post(tap: .cghidEventTap)
    usleep(5000)

    if modifiers.contains(.maskCommand) {
        currentFlags.remove(.maskCommand)
        let event = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }
    if modifiers.contains(.maskAlternate) {
        currentFlags.remove(.maskAlternate)
        let event = CGEvent(keyboardEventSource: src, virtualKey: optionKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }
    if modifiers.contains(.maskShift) {
        currentFlags.remove(.maskShift)
        let event = CGEvent(keyboardEventSource: src, virtualKey: shiftKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }
    if modifiers.contains(.maskControl) {
        currentFlags.remove(.maskControl)
        let event = CGEvent(keyboardEventSource: src, virtualKey: controlKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(5000)
    }
}

// MARK: - Escape 键
func postEscapeKey() {
    let src = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)
    keyDown?.post(tap: .cghidEventTap)
    usleep(5000)
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)
    keyUp?.post(tap: .cghidEventTap)
}

// MARK: - 桌面切换
enum DesktopDirection {
    case left
    case right
}

func switchDesktop(direction: DesktopDirection) {
    // 方向翻转：手指向右滑 → 切换到左边桌面 → 需要 Ctrl+左箭头
    let keyCode: CGKeyCode = (direction == .left) ? 0x7C : 0x7B
    let keyCodeStr: String = (direction == .left) ? "124" : "123"

    DispatchQueue.global().async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code \(keyCodeStr) using control down"]
        try? task.run()
    }

    postKeyboardShortcut(keyCode: keyCode, modifiers: .maskControl)
}

func showMissionControl() {
    DispatchQueue.global().async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Mission Control"]
        try? task.run()
    }
    postKeyboardShortcut(keyCode: 0x7E, modifiers: .maskControl)
}

func showAppExpose() {
    DispatchQueue.global().async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code 125 using control down"]
        try? task.run()
    }
    postKeyboardShortcut(keyCode: 0x7D, modifiers: .maskControl)
}

func openLaunchpad() {
    let src = CGEventSource(stateID: .hidSystemState)
    // F4 键码 = 0x76 (118)
    let f4Key: CGKeyCode = 0x76
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: f4Key, keyDown: true)
    keyDown?.post(tap: .cghidEventTap)
    usleep(5000)
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: f4Key, keyDown: false)
    keyUp?.post(tap: .cghidEventTap)
}

func showDesktop() {
    DispatchQueue.global().async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code 103 using control down"]
        try? task.run()
    }
}
