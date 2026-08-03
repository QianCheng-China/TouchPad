import Foundation
import Cocoa
import ApplicationServices

let COORD_SCALE: CGFloat = 10000.0
var isStylusDown: Bool = false

struct TouchPoint { var id: Int; var x: CGFloat; var y: CGFloat }

// 手势方向锁
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

// 键盘缩放节流
var lastKeyboardZoomTime: TimeInterval = 0
let keyboardZoomThrottle: TimeInterval = 0.15

// 缓存前台应用检测结果
var cachedKeyboardZoom: Bool? = nil
var lastZoomCacheTime: TimeInterval = 0
let zoomCacheTTL: TimeInterval = 2.0

// 手势冷却期时长
let gestureCooldown: TimeInterval = 0.4

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

    let zoomMode = AppState.shared.zoomMode
    let isKeyboardMode = (zoomMode == .keyboard) || (zoomMode == .smart && shouldUseKeyboardZoom())
    let zoomThreshold = AppState.shared.sensitivity.zoomStepThreshold

    if abs(deltaSpan) > zoomThreshold * 0.5 {
        handleZoom(deltaSpan: deltaSpan, span: span, centroid: centroid, isKeyboardMode: isKeyboardMode)
    }
    else if abs(dy) > 1.0 || abs(dx) > 1.0 {
        postScrollEvent(dy: -dy * 0.5, dx: -dx * 0.5)
        touchState.prevCentroid = centroid
        touchState.prevSpan = span
    }
}

// MARK: - 缩放处理
func handleZoom(deltaSpan: CGFloat, span: CGFloat, centroid: CGPoint, isKeyboardMode: Bool) {
    let zoomMode = AppState.shared.zoomMode
    let zoomStepThreshold = AppState.shared.sensitivity.zoomStepThreshold

    touchState.zoomAccumulator += deltaSpan

    if abs(touchState.zoomAccumulator) < zoomStepThreshold {
        touchState.prevSpan = span
        return
    }

    let zoomIn = touchState.zoomAccumulator > 0

    switch zoomMode {
    case .system:
        postControlZoom(lines: zoomIn ? 6 : -6)
    case .browser:
        postCommandScroll(lines: zoomIn ? 6 : -6)
    case .keyboard:
        postKeyboardZoom(zoomIn: zoomIn)
    case .smart:
        if isKeyboardMode {
            postKeyboardZoom(zoomIn: zoomIn)
        } else {
            postCommandScroll(lines: zoomIn ? 6 : -6)
        }
    }

    touchState.zoomAccumulator -= zoomIn ? zoomStepThreshold : -zoomStepThreshold
    touchState.prevSpan = span
}

// MARK: - 智能缩放: 检测前台应用是否需要键盘缩放
func shouldUseKeyboardZoom() -> Bool {
    let now = Date().timeIntervalSince1970
    if let cached = cachedKeyboardZoom, now - lastZoomCacheTime < zoomCacheTTL {
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
        cachedKeyboardZoom = false
        lastZoomCacheTime = now
        return false
    }

    let keyboardZoomApps: [String] = [
        "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
        "com.microsoft.outlook", "com.microsoft.onenote",
        "com.adobe.photoshop", "com.adobe.illustrator", "com.adobe.indesign",
        "com.adobe.premiere", "com.adobe.aftereffects", "com.adobe.acrobat", "com.adobe.lightroom",
        "com.autodesk", "com.blender", "com.sketchup", "com.maxon",
        "com.sublimetext", "com.jetbrains", "com.microsoft.vscode", "com.todesktop", "com.github.atom",
        "md.obsidian", "notion.id",
        "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote",
    ]

    let result = keyboardZoomApps.contains { bid.contains($0) }
    cachedKeyboardZoom = result
    lastZoomCacheTime = now
    return result
}

// MARK: - 键盘缩放 (Command + = / Command + -)
func postKeyboardZoom(zoomIn: Bool) {
    let now = Date().timeIntervalSince1970
    if now - lastKeyboardZoomTime < keyboardZoomThrottle { return }
    lastKeyboardZoomTime = now

    let keyCode: CGKeyCode = zoomIn ? 0x18 : 0x1B
    postKeyboardShortcut(keyCode: keyCode, modifiers: .maskCommand)
}

// MARK: - 三指滑动 (添加冷却期防止连续触发)
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
// 【修复】用相对变化率精确区分捏合和滑动
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

    // 【关键修复】用相对变化率区分捏合和滑动
    // 两者都用 startMaxSpan 作为基准归一化，在同一尺度上比较
    // spanRate = |span变化| / 初始maxSpan  (捏合时: 0.3-0.7, 滑动时: ~0)
    // moveRate = 质心位移 / 初始maxSpan    (滑动时: 0.1-0.3, 捏合时: 0.01-0.05)
    let spanRate = startMaxSpan > 0 ? abs(spanChange) / startMaxSpan : 0
    let moveRate = startMaxSpan > 0 ? totalMovement / startMaxSpan : 0

    // 方向锁定：如果还没确定方向，根据运动特征判断
    if touchState.gestureLock == .none {
        // 【关键修复】捏合用相对变化率判断，滑动用绝对位移判断
        // 
        // 坐标空间 0-10000, 四指初始 maxSpan ≈ 6000-8000
        // 捏合刚开始时 span 变化通常只有 100-200
        //   spanRate = 150/7000 ≈ 0.02
        // 所以 spanRate 阈值必须很低才能及时锁定为 pinch
        //
        // 滑动时质心位移通常 30-100
        //   moveRate = 60/7000 ≈ 0.009
        // 
        // 关键: spanRate 和 moveRate 都很小，但 spanRate/moveRate 比值能区分两者
        //   捏合: spanRate/moveRate ≈ 5-20 (span变化远大于位移)
        //   滑动: spanRate/moveRate ≈ 0-1 (位移远大于span变化)
        
        // 捏合判定：span变化率 > 3% 且 span变化率 > 位移率的3倍
        if spanRate > 0.03 && spanRate > moveRate * 3 {
            touchState.gestureLock = .pinch
        } else if totalMovement > swipeThreshold * 0.7 {
            // 滑动判定：位移达到滑动阈值的70%
            // 提高阈值避免轻微移动就锁定为滑动
            touchState.gestureLock = .swipe
        } else {
            return  // 还不够确定，等待更多数据
        }
    }

    // 根据锁定的方向处理手势
    if touchState.gestureLock == .pinch {
        // 【关键修复】捏合触发阈值改为相对值：span变化率 > 8%
        // 降低阈值，用户捏合到一定程度即可触发
        if spanRate > 0.08 {
            if spanChange < 0 {
                // 捏合
                if systemGestureState == .showDesktop {
                    showDesktop()
                    systemGestureState = .normal
                } else {
                    openLaunchpad()
                    systemGestureState = .launchpad
                }
            } else {
                // 张开
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
                // 上滑
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
                // 下滑
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
                // 左滑
                switchDesktop(direction: .left)
                touchState.gestureCooldownUntil = now + gestureCooldown
                touchState.gestureLock = .none
                resetGestureState(centroid: centroid)
            } else if totalDx > swipeThreshold {
                // 右滑
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

// 最大点间距：用于四指捏合/张开检测
// 比平均到质心距离更精确：滑动时不变，捏合/张开时显著变化
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

func postControlZoom(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskControl
    event.post(tap: .cghidEventTap)
}

func postCommandScroll(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskCommand
    event.post(tap: .cghidEventTap)
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

// 【修复1】macOS 原生触控板行为：手指向右滑 = 切换到左边的桌面（内容跟随手指，像翻页）
// 因此 .left 对应 Ctrl+→ (0x7C)，.right 对应 Ctrl+← (0x7B)
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

// MARK: - Mission Control
func showMissionControl() {
    DispatchQueue.global().async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Mission Control"]
        try? task.run()
    }
    postKeyboardShortcut(keyCode: 0x7E, modifiers: .maskControl)
}

// MARK: - App Exposé
func showAppExpose() {
    DispatchQueue.global().async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code 125 using control down"]
        try? task.run()
    }
    postKeyboardShortcut(keyCode: 0x7D, modifiers: .maskControl)
}

// MARK: - 启动台
// 【修复】F4 键码方案不可行:
//   - 用户Mac上 F4 = 聚焦搜索 (不是启动台)
//   - Fn+F4 = 闪白屏 (无效组合)
//   - 终端输出 ^[OS = F4被当作普通功能键发送给前台应用
//
// 正确方案: 使用 NSWorkspace 直接打开 Launchpad.app
//   - 比 Process + open 命令更可靠
//   - 不会报错 -1712
//   - 在主线程执行确保 NSWorkspace 正常工作
func openLaunchpad() {
    DispatchQueue.main.async {
        // 尝试多个可能的路径
        let paths = [
            "/System/Applications/Launchpad.app",
            "/Applications/Launchpad.app",
            "/System/Library/CoreServices/Launchpad.app"
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        // 后备方案: 使用 open 命令
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["/System/Applications/Launchpad.app"]
        try? task.run()
    }
}

// MARK: - 显示桌面
func showDesktop() {
    let src = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x67, keyDown: true)
    keyDown?.flags = .maskSecondaryFn
    keyDown?.post(tap: .cghidEventTap)
    usleep(5000)
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x67, keyDown: false)
    keyUp?.flags = .maskSecondaryFn
    keyUp?.post(tap: .cghidEventTap)
}
