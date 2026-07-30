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
    
    // 缩放模式枚举
    enum ZoomMode: String, CaseIterable {
        case system = "系统缩放"      // 适用于 Word, PDF, 系统界面
        case browser = "浏览器缩放"    // 适用于 Safari, Chrome
    }
    
    @Published var inputMode: InputMode = .stylusOnly
    @Published var connectedDevices: [String] = []
    @Published var activeDevice: String? = nil
    @Published var isMouseDown: Bool = false
    @Published var isLocked: Bool = false
    @Published var trackpadEnabled: Bool = false
    
    // 当前选中的缩放模式
    @Published var zoomMode: ZoomMode = .system
    
    func registerDevice(_ id: String) {
        DispatchQueue.main.async {
            if !self.connectedDevices.contains(id) {
                self.connectedDevices.append(id)
                if self.activeDevice == nil { self.activeDevice = id }
                NotificationCenter.default.post(name: .deviceListChanged, object: nil)
            }
        }
    }
    
    func removeDevice(_ id: String) {
        DispatchQueue.main.async {
            self.connectedDevices.removeAll { $0 == id }
            if self.activeDevice == id { self.activeDevice = self.connectedDevices.first }
            self.isMouseDown = false
            NotificationCenter.default.post(name: .deviceListChanged, object: nil)
        }
    }
}
