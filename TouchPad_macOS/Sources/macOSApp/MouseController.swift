// MouseController.swift
// 优化版：更丝滑的缩放、智能应用感知、惯性曲线、可中断/合并的缩放任务
import Foundation
import Cocoa
import ApplicationServices
import Darwin

let COORD_SCALE: CGFloat = 10000.0
var isStylusDown: Bool = false

// 【修复1】补充缺失的手势冷却时间常量
let gestureCooldown: TimeInterval = 0.8

struct TouchPoint { var id: Int; var x: CGFloat; var y: CGFloat }

// MARK: - ZoomController: 平滑缩放与惯性模拟（可中断、合并、按应用策略）
final class ZoomController {
    static let shared = ZoomController()
    private let queue = DispatchQueue(label: "com.touchpad.zoom", qos: .userInteractive)
    private var currentTask: ZoomTask? = nil
    private let lock = NSLock()
    
    private init() {}
    
    func performZoom(magnification: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        if let task = currentTask, task.isSameDirection(as: magnification) {
            task.append(magnification: magnification)
            return
        } else {
            currentTask?.cancel()
            let task = ZoomTask(initialMagnification: magnification)
            currentTask = task
            queue.async {
                task.run { [weak self] in
                    self?.lock.lock()
                    if self?.currentTask === task {
                        self?.currentTask = nil
                    }
                    self?.lock.unlock()
                }
            }
        }
    }
    
    func cancel() {
        lock.lock()
        currentTask?.cancel()
        currentTask = nil
        lock.unlock()
    }
}

private final class ZoomTask {
    private var magnitudes: [Double] = []
    private var cancelled = false
    private let lock = NSLock()
    
    private let maxSteps = 80
    private let minInterval: Double = 0.006
    private let maxInterval: Double = 0.03
    
    init(initialMagnification: Double) {
        magnitudes.append(initialMagnification)
    }
    
    func append(magnification: Double) {
        lock.lock()
        magnitudes.append(magnification)
        lock.unlock()
    }
    
    func isSameDirection(as mag: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let first = magnitudes.first else { return true }
        return (first >= 0 && mag >= 0) || (first < 0 && mag < 0)
    }
    
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    
    private func consumeMagnitudes() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let sum = magnitudes.reduce(0, +)
        magnitudes.removeAll()
        return sum
    }
    
    func run(completion: @escaping () -> Void) {
        Thread.sleep(forTimeInterval: 0.008)
        if cancelled { completion(); return }
        
        var totalMag = consumeMagnitudes()
        if cancelled { completion(); return }
        if abs(totalMag) < 0.0005 { completion(); return }
        
        let sensitivity = AppState.shared.sensitivity
        let baseSteps: Int
        switch sensitivity {
        case .low: baseSteps = 6
        case .medium: baseSteps = 12
        case .high: baseSteps = 20
        }
        
        let magScale = min(6.0, max(0.5, abs(totalMag) * 8.0))
        var steps = Int(Double(baseSteps) * magScale)
        steps = min(max(3, steps), maxSteps)
        
        let interval = max(minInterval, min(maxInterval, 0.012 / (Double(steps) / 10.0)))
        let easing = ZoomTask.generateEaseOutWeights(count: steps, exponent: 2.2)
        let direction = totalMag >= 0 ? 1.0 : -1.0
        var perStepMags: [Double] = easing.map { $0 * abs(totalMag) * direction }
        
        // 添加惯性尾迹
        if abs(totalMag) > 0.25 {
            let tailSteps = min(12, steps / 4)
            for i in 0..<tailSteps {
                let decay = pow(0.6, Double(i))
                perStepMags.append(direction * 0.02 * decay)
            }
        }
        
        // 【修复2】获取缩放策略
        let strategy = getZoomStrategy()
        
        for (i, stepMag) in perStepMags.enumerated() {
            if cancelled { break }
            
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                ZoomTask.sendStep(magnitude: stepMag, strategy: strategy)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 0.05)
            Thread.sleep(forTimeInterval: interval)
            
            if !magnitudes.isEmpty {
                let newTotal = consumeMagnitudes()
                if abs(newTotal) > 0.0005 {
                    let remaining = max(1, perStepMags.count - i - 1)
                    let addPerStep = newTotal / Double(remaining)
                    for j in (i+1)..<perStepMags.count {
                        perStepMags[j] += addPerStep
                    }
                }
            }
        }
        completion()
    }
    
    private static func generateEaseOutWeights(count: Int, exponent: Double) -> [Double] {
        guard count > 0 else { return [] }
        var weights = [Double](repeating: 0.0, count: count)
        var sum: Double = 0
        for i in 0..<count {
            let t = Double(i) / Double(max(1, count - 1))
            let w = 1.0 - pow(1.0 - t, exponent)
            weights[i] = w
            sum += w
        }
        if sum == 0 { return weights.map { _ in 1.0 / Double(count) } }
        return weights.map { $0 / sum }
    }
    
    static func sendStep(magnitude: Double, strategy: ZoomStrategy) {
        let absMag = abs(magnitude)
        let direction = magnitude >= 0 ? 1 : -1
        let perStepLines: Int32
        if absMag > 0.2 { perStepLines = 10 }
        else if absMag > 0.08 { perStepLines = 4 }
        else { perStepLines = 1 }
        
        switch strategy {
        case .keyboard:
            let repeats = min(4, max(1, Int(absMag * 8.0)))
            for _ in 0..<repeats {
                postKeyboardShortcut(keyCode: direction > 0 ? 0x18 : 0x1B, modifiers: .maskCommand)
            }
        case .altScroll:
            postAltScroll(lines: Int32(direction) * perStepLines)
        case .controlScroll:
            postControlZoom(lines: Int32(direction) * perStepLines)
        case .commandScroll:
            postCommandScroll(lines: Int32(direction) * perStepLines)
        }
    }
}

// MARK: - 替代原生缩放：直接使用 ZoomController
func postNativeMagnify(magnification: Double) {
    ZoomController.shared.performZoom(magnification: magnification)
}

// MARK: - 手势方向锁与触控处理
enum GestureLock {
    case none
    case swipe
    case pinch
}

class TouchState {
    var points: [Int: TouchPoint] = [:]
    var lastFingerCount: Int = 0
    
    var prevCentroid: CGPoint? = nil
    var prevSpan: CGFloat? = nil
    
    var startCentroid: CGPoint? = nil
    var startSpan: CGFloat? = nil
    var gestureTriggered: Bool = false
    
    var settleFrames: Int = 0
    var zoomAccumulator: CGFloat = 0
    var startMaxSpan: CGFloat? = nil
    
    var gestureLock: GestureLock = .none
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

enum SystemGestureState {
    case normal
    case missionControl
    case appExpose
    case launchpad
    case showDesktop
}
var systemGestureState: SystemGestureState = .normal

enum ZoomStrategy {
    case keyboard
    case commandScroll
    case controlScroll
    case altScroll
}

// 缓存前台应用检测结果
var cachedZoomStrategy: ZoomStrategy? = nil
var lastZoomCacheTime: TimeInterval = 0
let zoomCacheTTL: TimeInterval = 1.0

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
        if AppState.shared.gestureOptions.isEnabled(.singleFingerMove) {
            handleOneFinger(centroid: centroid)
        }
    case 2:
        if AppState.shared.gestureOptions.isEnabled(.pinchZoomAndScroll) {
            handleTwoFingers(centroid: centroid, span: span)
        }
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
    guard let prevCentroid = touchState.prevCentroid, let prevSpanVal = touchState.prevSpan else { return }
    
    let dy = centroid.y - prevCentroid.y
    let dx = centroid.x - prevCentroid.x
    let deltaSpan = span - prevSpanVal
    
    let zoomThreshold = AppState.shared.sensitivity.zoomStepThreshold
    
    if abs(deltaSpan) > zoomThreshold * 0.5 {
        handleZoom(deltaSpan: deltaSpan, span: span, centroid: centroid)
    } else if abs(dy) > 1.0 || abs(dx) > 1.0 {
        postScrollEvent(dy: -dy * 0.5, dx: -dx * 0.5)
        touchState.prevCentroid = centroid
        touchState.prevSpan = span
    }
}

// MARK: - 缩放处理 (修复逻辑错误)
func handleZoom(deltaSpan: CGFloat, span: CGFloat, centroid: CGPoint) {
    // 使用阈值判定是否触发缩放
    let zoomStepThreshold = AppState.shared.sensitivity.zoomStepThreshold
    touchState.zoomAccumulator += deltaSpan
    
    // 累积变化超过阈值才触发，防止微小抖动
    if abs(touchState.zoomAccumulator) > zoomStepThreshold * 0.5 {
        let magnification = Double(touchState.zoomAccumulator / 300.0)
        if abs(magnification) > 0.01 {
            postNativeMagnify(magnification: magnification)
        }
        touchState.zoomAccumulator = 0 // 发送后重置累积
    }
    
    touchState.prevSpan = span
}

// MARK: - 三指滑动（受选项控制）
func handleThreeFingerSwipe(centroid: CGPoint) {
    let now = Date().timeIntervalSince1970
    if now < touchState.gestureCooldownUntil { return }
    
    guard let start = touchState.startCentroid else { return }
    
    let totalDy = centroid.y - start.y
    let totalDx = centroid.x - start.x
    let threshold = AppState.shared.sensitivity.swipeThreshold
    
    if abs(totalDy) > abs(totalDx) {
        if totalDy < -threshold {
            if AppState.shared.gestureOptions.isEnabled(.missionControl) {
                showMissionControl()
                touchState.gestureCooldownUntil = now + gestureCooldown
                resetGestureState(centroid: centroid)
            }
        } else if totalDy > threshold {
            if AppState.shared.gestureOptions.isEnabled(.appExpose) {
                showAppExpose()
                touchState.gestureCooldownUntil = now + gestureCooldown
                resetGestureState(centroid: centroid)
            }
        }
    } else {
        if totalDx < -threshold {
            if AppState.shared.gestureOptions.isEnabled(.desktopSwitch) {
                switchDesktop(direction: .left)
                touchState.gestureCooldownUntil = now + gestureCooldown
                resetGestureState(centroid: centroid)
            }
        } else if totalDx > threshold {
            if AppState.shared.gestureOptions.isEnabled(.desktopSwitch) {
                switchDesktop(direction: .right)
                touchState.gestureCooldownUntil = now + gestureCooldown
                resetGestureState(centroid: centroid)
            }
        }
    }
}

// MARK: - 四指手势（受选项控制）
func handleFourFingers(centroid: CGPoint, span: CGFloat) {
    let now = Date().timeIntervalSince1970
    if now < touchState.gestureCooldownUntil { return }
    
    guard let start = touchState.startCentroid, let startMaxSpan = touchState.startMaxSpan else { return }
    
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
                if AppState.shared.gestureOptions.isEnabled(.showDesktop) {
                    showDesktop()
                    systemGestureState = .normal
                } else if AppState.shared.gestureOptions.isEnabled(.launchpad) {
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
                if AppState.shared.gestureOptions.isEnabled(.missionControl) {
                    showMissionControl()
                    touchState.gestureCooldownUntil = now + gestureCooldown
                    touchState.gestureLock = .none
                    resetGestureState(centroid: centroid)
                }
            } else if totalDy > swipeThreshold {
                if AppState.shared.gestureOptions.isEnabled(.appExpose) {
                    showAppExpose()
                    touchState.gestureCooldownUntil = now + gestureCooldown
                    touchState.gestureLock = .none
                    resetGestureState(centroid: centroid)
                }
            }
        } else {
            if totalDx < -swipeThreshold {
                if AppState.shared.gestureOptions.isEnabled(.desktopSwitch) {
                    switchDesktop(direction: .left)
                    touchState.gestureCooldownUntil = now + gestureCooldown
                    touchState.gestureLock = .none
                    resetGestureState(centroid: centroid)
                }
            } else if totalDx > swipeThreshold {
                if AppState.shared.gestureOptions.isEnabled(.desktopSwitch) {
                    switchDesktop(direction: .right)
                    touchState.gestureCooldownUntil = now + gestureCooldown
                    touchState.gestureLock = .none
                    resetGestureState(centroid: centroid)
                }
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

func postControlZoom(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskControl
    event.post(tap: .cgSessionEventTap)
}

func postCommandScroll(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskCommand
    event.post(tap: .cgSessionEventTap)
}

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
        usleep(3000)
    }
    if modifiers.contains(.maskShift) {
        currentFlags.insert(.maskShift)
        let event = CGEvent(keyboardEventSource: src, virtualKey: shiftKey, keyDown: true)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(3000)
    }
    if modifiers.contains(.maskAlternate) {
        currentFlags.insert(.maskAlternate)
        let event = CGEvent(keyboardEventSource: src, virtualKey: optionKey, keyDown: true)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(3000)
    }
    if modifiers.contains(.maskCommand) {
        currentFlags.insert(.maskCommand)
        let event = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(3000)
    }
    
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    keyDown?.flags = modifiers
    keyDown?.post(tap: .cghidEventTap)
    usleep(3000)
    
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    keyUp?.flags = modifiers
    keyUp?.post(tap: .cghidEventTap)
    usleep(3000)
    
    if modifiers.contains(.maskCommand) {
        currentFlags.remove(.maskCommand)
        let event = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(3000)
    }
    if modifiers.contains(.maskAlternate) {
        currentFlags.remove(.maskAlternate)
        let event = CGEvent(keyboardEventSource: src, virtualKey: optionKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(3000)
    }
    if modifiers.contains(.maskShift) {
        currentFlags.remove(.maskShift)
        let event = CGEvent(keyboardEventSource: src, virtualKey: shiftKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(3000)
    }
    if modifiers.contains(.maskControl) {
        currentFlags.remove(.maskControl)
        let event = CGEvent(keyboardEventSource: src, virtualKey: controlKey, keyDown: false)
        event?.flags = currentFlags
        event?.post(tap: .cghidEventTap)
        usleep(3000)
    }
}

// MARK: - Escape 键与桌面/任务视图操作
func postEscapeKey() {
    let src = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)
    keyDown?.post(tap: .cghidEventTap)
    usleep(3000)
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)
    keyUp?.post(tap: .cghidEventTap)
}

enum DesktopDirection {
    case left
    case right
}

func switchDesktop(direction: DesktopDirection) {
    let keyCode: CGKeyCode = (direction == .left) ? 0x7C : 0x7B
    let keyCodeStr: String = (direction == .left) ? "124" : "123"
    
    // 使用 AppleScript 备用方案以防系统权限问题
    DispatchQueue.global().async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code \(keyCodeStr) using control down"]
        try? task.run()
    }
    
    // 主方案：直接发送按键
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
    let f4Key: CGKeyCode = 0x76
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: f4Key, keyDown: true)
    keyDown?.post(tap: .cghidEventTap)
    usleep(3000)
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

// MARK: - 【修复3】智能缩放策略检测函数
func getZoomStrategy() -> ZoomStrategy {
    let mode = AppState.shared.zoomMode
    
    // 如果用户指定了具体模式，则直接使用
    switch mode {
    case .smart:
        return getSmartZoomStrategy()
    case .system:
        return .controlScroll
    case .browser:
        return .commandScroll
    case .keyboard:
        return .keyboard
    }
}

/// 智能检测当前前台应用，返回最适合的缩放策略
func getSmartZoomStrategy() -> ZoomStrategy {
    // 简单的缓存机制，避免频繁检测
    let now = Date().timeIntervalSince1970
    if let cached = cachedZoomStrategy, (now - lastZoomCacheTime) < zoomCacheTTL {
        return cached
    }
    
    // 获取前台应用
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return .commandScroll // 默认策略
    }
    let bundleId = app.bundleIdentifier ?? ""
    
    // 策略映射表
    // Word, Excel, PowerPoint: 使用键盘快捷键 (Cmd + = / Cmd + -)
    if bundleId.contains("com.microsoft.Word") ||
       bundleId.contains("com.microsoft.Excel") ||
       bundleId.contains("com.microsoft.Powerpoint") ||
       bundleId.contains("com.microsoft.Outlook") {
        return .keyboard
    }
    
    // Safari, Chrome, Firefox, Preview: 使用 Command + Scroll
    if bundleId.contains("com.apple.Safari") ||
       bundleId.contains("com.google.Chrome") ||
       bundleId.contains("org.mozilla.firefox") ||
       bundleId.contains("com.apple.Preview") ||
       bundleId.contains("com.adobe.acrobat") {
        return .commandScroll
    }
    
    // 其他应用：默认使用 Command + Scroll
    let strategy: ZoomStrategy = .commandScroll
    
    // 更新缓存
    cachedZoomStrategy = strategy
    lastZoomCacheTime = now
    
    return strategy
}
