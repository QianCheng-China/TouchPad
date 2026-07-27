import Foundation
import Cocoa
import ApplicationServices

let COORD_SCALE: CGFloat = 10000.0

// 仅用于记录当前是否处于 "按下" 状态，辅助 MOVE 判断
var isStylusDown: Bool = false

func processCommand(_ cmd: String, from id: String) {
    // [日志] 入口
    NSLog("[TouchPad] [RX] 接收: \(cmd)")
    
    let parts = cmd.split(separator: ",")
    guard parts.count == 4 else { return }
    
    guard let action = String(parts[0]).uppercased() as String?,
          let tool = String(parts[1]).uppercased() as String?,
          let x = Double(String(parts[2])),
          let y = Double(String(parts[3])) else { return }
    
    // 权限与模式检查
    if AppState.shared.activeDevice != nil && AppState.shared.activeDevice != id { return }
    if AppState.shared.inputMode == .stylusOnly && tool != "STYLUS" { return }
    
    // 计算坐标
    guard let screen = NSScreen.main else { return }
    let point = CGPoint(
        x: (CGFloat(x) / COORD_SCALE) * screen.frame.width,
        y: (CGFloat(y) / COORD_SCALE) * screen.frame.height
    )
    
    // [核心逻辑] 根据指令执行操作
    switch action {
    case "HOVER":
        // 策略：激进重置
        // 无论之前状态如何，HOVER 意味着 "松开并移动"。
        // 无条件发送 UP 事件，可以解除任何因丢包或异常导致的 "卡死" 状态。
        // 额外的 UP 事件对系统无害，但能修复卡死。
        
        if isStylusDown {
            NSLog("[TouchPad] [WARN] 检测到状态不一致: HOVER时记录为按下，执行强制释放")
        }
        
        // 1. 强制发送 UP (关键修复步骤)
        postMouseEvent(type: .leftMouseUp, location: point, button: .left)
        
        // 2. 发送移动
        postMouseEvent(type: .mouseMoved, location: point, button: .left)
        
        // 3. 重置状态
        isStylusDown = false
        
    case "MOVE":
        if isStylusDown {
            // 如果是按下状态，发送拖拽事件
            postMouseEvent(type: .leftMouseDragged, location: point, button: .left)
        } else {
            // 否则发送普通移动
            postMouseEvent(type: .mouseMoved, location: point, button: .left)
        }
        
    case "DOWN":
        NSLog("[TouchPad] [INFO] 执行 DOWN")
        isStylusDown = true
        postMouseEvent(type: .leftMouseDown, location: point, button: .left)
        
    case "UP":
        NSLog("[TouchPad] [INFO] 执行 UP")
        isStylusDown = false
        postMouseEvent(type: .leftMouseUp, location: point, button: .left)
        
    default:
        break
    }
}

// 底层事件发送封装
func postMouseEvent(type: CGEventType, location: CGPoint, button: CGMouseButton) {
    // 创建事件
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: location,
        mouseButton: button
    ) else {
        NSLog("[TouchPad] [ERR] CGEvent 创建失败! Type: \(type), Loc: \(location)")
        return
    }
    
    // 发送事件
    event.post(tap: .cghidEventTap)
    
    // [调试日志] 仅在状态切换时打印，避免刷屏
    if type == .leftMouseDown || type == .leftMouseUp {
        NSLog("[TouchPad] [POST] 事件已发送: \(type)")
    }
}
