import Foundation
import Cocoa
import ApplicationServices

let COORD_SCALE: CGFloat = 10000.0
var isStylusDown: Bool = false

struct TouchPoint { var id: Int; var x: CGFloat; var y: CGFloat }

class TouchState {
    var points: [Int: TouchPoint] = [:]
    var lastFingerCount: Int = 0
    
    var prevCentroid: CGPoint? = nil
    var prevSpan: CGFloat? = nil
    
    func reset() {
        points.removeAll()
        prevCentroid = nil; prevSpan = nil
    }
}
let touchState = TouchState()

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
        postMouseEvent(type: .leftMouseDown, location: point, button: .left)
    case "PEN_MOVE":
        let type: CGEventType = isStylusDown ? .leftMouseDragged : .mouseMoved
        postMouseEvent(type: type, location: point, button: .left)
    case "PEN_UP":
        isStylusDown = false
        postMouseEvent(type: .leftMouseUp, location: point, button: .left)
    case "PEN_HOVER":
        postMouseEvent(type: .mouseMoved, location: point, button: .left)
    default: break
    }
}

// MARK: - 触摸逻辑 (仅保留单指和双指)
func handleTouch(cmd: String, parts: [String.SubSequence]) {
    guard parts.count >= 2 else { return }
    guard let count = Int(String(parts[1])) else { return }
    
    // 手指数量变化检测
    if count != touchState.lastFingerCount {
        touchState.reset()
        touchState.lastFingerCount = count
    }
    
    // 仅处理 1 指和 2 指
    if count > 2 { return }
    
    // 更新点集
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
    
    // 首帧初始化
    if touchState.prevCentroid == nil {
        touchState.prevCentroid = centroid
        touchState.prevSpan = span
        return
    }
    
    // 分发逻辑
    switch count {
    case 1:
        handleOneFinger(centroid: centroid)
    case 2:
        handleTwoFingers(centroid: centroid, span: span)
    default: break
    }
    
    // 更新历史数据
    touchState.prevCentroid = centroid
    touchState.prevSpan = span
}

func handleOneFinger(centroid: CGPoint) {
    if let point = touchState.points.values.first {
        let screenPoint = CGPoint(
            x: (point.x / COORD_SCALE) * (NSScreen.main?.frame.width ?? 0),
            y: (point.y / COORD_SCALE) * (NSScreen.main?.frame.height ?? 0)
        )
        postMouseEvent(type: .mouseMoved, location: screenPoint, button: .left)
    }
}

// MARK: - 双指逻辑 (修正方向：取反)
func handleTwoFingers(centroid: CGPoint, span: CGFloat) {
    let prevY = touchState.prevCentroid?.y ?? centroid.y
    let dy = centroid.y - prevY
    
    let prevSpanVal = touchState.prevSpan ?? span
    let deltaSpan = span - prevSpanVal
    
    // 阈值设置
    let zoomThreshold: CGFloat = 25.0
    
    // 优先判定缩放
    if abs(deltaSpan) > zoomThreshold {
        // === 缩放模式 ===
        // 用户反馈修正：张开(delta > 0) 现在应该发送正值 以放大 (之前发送负值导致缩小)
        // 反转逻辑：张开 -> 6 (放大)
        let zoomVal: Int32 = deltaSpan > 0 ? 6 : -6
        
        if AppState.shared.zoomMode == .system {
            postControlZoom(lines: zoomVal)
        } else {
            postCommandScroll(lines: zoomVal)
        }
        
        touchState.prevSpan = span
        touchState.prevCentroid = centroid
        
    } else if abs(dy) > 1.0 {
        // === 滚动模式 ===
        // 用户反馈修正：双指上滑(y减小, dy < 0) -> 发送正值 -> 向下滚动 (传统鼠标逻辑)
        // 反转逻辑：发送 -dy
        postScrollEvent(dy: -dy * 0.5, dx: 0)
        
        touchState.prevCentroid = centroid
    }
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
        distSum += sqrt(dx*dx + dy*dy)
    }
    return distSum / CGFloat(points.count)
}

// MARK: - 底层发送
func postMouseEvent(type: CGEventType, location: CGPoint, button: CGMouseButton) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
    event.post(tap: .cghidEventTap)
}

func postScrollEvent(dy: CGFloat, dx: CGFloat) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
    event.flags = [] // 确保无修饰键
    event.post(tap: .cghidEventTap)
}

// 系统缩放
func postControlZoom(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskControl
    event.post(tap: .cghidEventTap)
}

// 浏览器缩放
func postCommandScroll(lines: Int32) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    event.flags = .maskCommand // Command 键修饰
    event.post(tap: .cghidEventTap)
}
