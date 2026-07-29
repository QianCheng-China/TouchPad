import Foundation
import Cocoa
import ApplicationServices

let COORD_SCALE: CGFloat = 10000.0
var isStylusDown: Bool = false

func processCommand(_ cmd: String, from id: String) {
    let parts = cmd.split(separator: ",")
    guard parts.count >= 4 else { return }
    
    let action = String(parts[0]).uppercased()
    
    if action == "GESTURE" {
        processGesture(parts: parts)
        return
    }
    
    guard let tool = String(parts[1]).uppercased() as String?,
          let x = Double(String(parts[2])),
          let y = Double(String(parts[3])) else { return }
    
    if AppState.shared.activeDevice != nil && AppState.shared.activeDevice != id { return }
    if AppState.shared.inputMode == .stylusOnly && tool != "STYLUS" { return }
    
    guard let screen = NSScreen.main else { return }
    let point = CGPoint(
        x: (CGFloat(x) / COORD_SCALE) * screen.frame.width,
        y: (CGFloat(y) / COORD_SCALE) * screen.frame.height
    )
    
    switch action {
    case "HOVER":
        if isStylusDown {
            postMouseEvent(type: .leftMouseUp, location: point, button: .left)
            isStylusDown = false
        }
        postMouseEvent(type: .mouseMoved, location: point, button: .left)
    case "MOVE":
        if isStylusDown {
            postMouseEvent(type: .leftMouseDragged, location: point, button: .left)
        } else {
            postMouseEvent(type: .mouseMoved, location: point, button: .left)
        }
    case "DOWN":
        isStylusDown = true
        postMouseEvent(type: .leftMouseDown, location: point, button: .left)
    case "UP":
        isStylusDown = false
        postMouseEvent(type: .leftMouseUp, location: point, button: .left)
    default:
        break
    }
}

func processGesture(parts: [String.SubSequence]) {
    guard parts.count >= 4 else { return }
    guard let type = String(parts[1]).uppercased() as String?,
          let dx = Double(String(parts[2])),
          let dy = Double(String(parts[3])) else { return }
    
    switch type {
    case "SCROLL":
        postScrollEvent(dx: dx, dy: dy)
    case "ZOOM":
        let factor = dx
        if abs(factor - 1.0) < 0.005 { return }
        
        // 开关：使用原生手势还是 Control+Scroll
        let useNativeGesture = true // 如果原生手势不生效，改为 false
        
        if useNativeGesture {
            postPinchGesture(scale: factor)
        } else {
            postControlZoom(factor: factor)
        }
    default:
        break
    }
}

func postMouseEvent(type: CGEventType, location: CGPoint, button: CGMouseButton) {
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: location,
        mouseButton: button
    ) else { return }
    event.post(tap: .cghidEventTap)
}

func postScrollEvent(dx: Double, dy: Double) {
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 2,
        wheel1: Int32(dy),
        wheel2: Int32(dx),
        wheel3: 0
    ) else { return }
    event.post(tap: .cghidEventTap)
}

// 【方案一】原生捏合手势 (修复方向)
func postPinchGesture(scale: Double) {
    guard let event = CGEvent(source: nil) else { return }
    event.type = CGEventType(rawValue: 41)!
    
    // 【核心修复】反转手势比例
    // 如果 factor > 1.0 (张开) 却导致了缩小，说明系统解释反了
    // 我们发送一个 "反向" 的比例，让系统表现出正确的效果
    let correctedScale: Double
    if scale > 1.0 {
        correctedScale = 1.0 / scale // 张开 -> 压缩比例 (如 1.04 -> 0.96)
    } else if scale < 1.0 {
        correctedScale = 1.0 / scale // 捏合 -> 扩张比例 (如 0.96 -> 1.04)
    } else {
        correctedScale = 1.0
    }
    
    // 设置手势类型为 Pinch (6)
    event.setIntegerValueField(CGEventField(rawValue: 102)!, value: 6)
    
    // Begin
    event.setIntegerValueField(CGEventField(rawValue: 101)!, value: 1)
    event.setDoubleValueField(CGEventField(rawValue: 110)!, value: 1.0)
    event.post(tap: .cghidEventTap)
    
    // Changed
    event.setIntegerValueField(CGEventField(rawValue: 101)!, value: 2)
    event.setDoubleValueField(CGEventField(rawValue: 110)!, value: correctedScale)
    event.post(tap: .cghidEventTap)
    
    // End
    event.setIntegerValueField(CGEventField(rawValue: 101)!, value: 4)
    event.post(tap: .cghidEventTap)
}

// 【方案二】Control + 滚动 (备选方案)
func postControlZoom(factor: Double) {
    let delta = factor - 1.0
    if abs(delta) < 0.002 { return }
    
    let acceleration: Double = 600.0
    var scrollLines = Int32(abs(delta) * acceleration)
    if scrollLines < 5 { scrollLines = 5 }
    
    // 修正方向：张开(factor>1) 为放大(lines为负)
    // 如果方向反了，就把这里改为 scrollLines (正数)
    let finalLines = delta > 0 ? -scrollLines : scrollLines
    
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: finalLines,
        wheel2: 0,
        wheel3: 0
    ) else { return }
    
    event.flags = .maskControl
    event.post(tap: .cghidEventTap)
}
