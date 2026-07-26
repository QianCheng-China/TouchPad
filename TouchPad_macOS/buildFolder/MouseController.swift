import Foundation
import Cocoa
import ApplicationServices

let COORD_SCALE: CGFloat = 10000.0

func processCommand(_ cmd: String, from id: String) {
    let parts = cmd.split(separator: ",")
    guard parts.count == 4 else { return }
    
    guard let action = String(parts[0]).uppercased() as String?,
          let tool = String(parts[1]).uppercased() as String?,
          let x = Double(String(parts[2])),
          let y = Double(String(parts[3])) else { return }
    
    if AppState.shared.activeDevice != nil && AppState.shared.activeDevice != id { return }
    
    if AppState.shared.inputMode == .stylusOnly && tool != "STYLUS" {
        return 
    }
    
    switch action {
    case "MOVE": moveMouse(x: CGFloat(x), y: CGFloat(y))
    case "DOWN": mouseDown(x: CGFloat(x), y: CGFloat(y))
    case "UP": mouseUp(x: CGFloat(x), y: CGFloat(y))
    default: break
    }
}

func postMouseEvent(type: CGEventType, location: CGPoint, button: CGMouseButton) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
    event.post(tap: .cghidEventTap)
}

func moveMouse(x: CGFloat, y: CGFloat) {
    guard let screen = NSScreen.main else { return }
    let point = CGPoint(x: (x / COORD_SCALE) * screen.frame.width, y: (y / COORD_SCALE) * screen.frame.height)
    
    if AppState.shared.isMouseDown {
        postMouseEvent(type: .leftMouseDragged, location: point, button: .left)
    } else {
        postMouseEvent(type: .mouseMoved, location: point, button: .left)
    }
}

func mouseDown(x: CGFloat, y: CGFloat) {
    guard let screen = NSScreen.main else { return }
    let point = CGPoint(x: (x / COORD_SCALE) * screen.frame.width, y: (y / COORD_SCALE) * screen.frame.height)
    AppState.shared.isMouseDown = true
    postMouseEvent(type: .leftMouseDown, location: point, button: .left)
}

func mouseUp(x: CGFloat, y: CGFloat) {
    guard let screen = NSScreen.main else { return }
    let point = CGPoint(x: (x / COORD_SCALE) * screen.frame.width, y: (y / COORD_SCALE) * screen.frame.height)
    AppState.shared.isMouseDown = false
    postMouseEvent(type: .leftMouseUp, location: point, button: .left)
}
