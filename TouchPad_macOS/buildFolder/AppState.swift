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
    
    // 【新增】全局锁定状态
    @Published var isLocked: Bool = false
    
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
            NotificationCenter.default.post(name: .deviceListChanged, object: nil)
        }
    }
}
