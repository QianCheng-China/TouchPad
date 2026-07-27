import Foundation
import Combine
import Cocoa

extension Notification.Name {
    static let deviceListChanged = Notification.Name("deviceListChanged")
}

class AppState: ObservableObject {
    static let shared = AppState()
    
    enum InputMode: String {
        case both = "触控笔 + 手指"
        case stylusOnly = "仅触控笔"
    }
    
    @Published var inputMode: InputMode = .stylusOnly
    @Published var connectedDevices: [String] = []
    @Published var activeDevice: String? = nil
    @Published var isMouseDown: Bool = false
    @Published var isLocked: Bool = false
    
    func registerDevice(_ id: String) {
        DispatchQueue.main.async {
            if !self.connectedDevices.contains(id) {
                self.connectedDevices.append(id)
                if self.activeDevice == nil {
                    self.activeDevice = id
                }
                NotificationCenter.default.post(name: .deviceListChanged, object: nil)
            }
        }
    }
    
    func removeDevice(_ id: String) {
        DispatchQueue.main.async {
            self.connectedDevices.removeAll { $0 == id }
            
            if self.activeDevice == id {
                self.activeDevice = self.connectedDevices.first
                // 断开设备时强制重置状态
                self.isMouseDown = false
            }
            
            NotificationCenter.default.post(name: .deviceListChanged, object: nil)
        }
    }
    
    // 【新增】提供一个安全的方法来强制重置鼠标状态
    func forceResetMouseState() {
        DispatchQueue.main.async {
            if self.isMouseDown {
                self.isMouseDown = false
                // 发送真实的鼠标释放事件，确保系统状态同步
                if let location = NSEvent.mouseLocation as CGPoint? {
                    // 这里仅仅重置状态，不发送事件，因为AppDelegate会处理
                    // 但如果需要更底层控制，可以在这里调用MouseController
                }
                NSLog("[AppState] 强制重置鼠标状态为 false")
            }
        }
    }
}
