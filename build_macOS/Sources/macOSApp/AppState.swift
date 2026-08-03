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
        case smart = "智能缩放"        // 自动检测前台应用，选择最佳缩放方式
        case native = "原生缩放"       // 使用IOHIDEvent注入真正的捏合缩放事件
        case system = "系统缩放"       // Control + 滚轮（需在辅助功能中开启缩放）
        case browser = "浏览器缩放"    // Command + 滚轮（适用于 Safari, Chrome, Preview 等）
        case keyboard = "键盘缩放"     // Command + = / Command + -（适用于 Word, Excel, PS 等）
    }
    
    // 【新增】手势灵敏度枚举
    enum Sensitivity: String, CaseIterable {
        case low = "低灵敏度"
        case medium = "中灵敏度"
        case high = "高灵敏度"
        
        // 滑动触发阈值 (三指/四指滑动)
        var swipeThreshold: CGFloat {
            switch self {
            case .low: return 90
            case .medium: return 60
            case .high: return 40
            }
        }
        
        // 捏合/张开触发阈值 (四指)
        var pinchThreshold: CGFloat {
            switch self {
            case .low: return 600
            case .medium: return 400
            case .high: return 250
            }
        }
        
        // 缩放步进阈值
        var zoomStepThreshold: CGFloat {
            switch self {
            case .low: return 40
            case .medium: return 30
            case .high: return 20
            }
        }
    }
    
    @Published var inputMode: InputMode = .stylusOnly
    @Published var connectedDevices: [String] = []
    @Published var activeDevice: String? = nil
    @Published var isMouseDown: Bool = false
    @Published var isLocked: Bool = false
    @Published var trackpadEnabled: Bool = false
    
    @Published var zoomMode: ZoomMode = .smart
    
    // 【新增】手势灵敏度 (默认中灵敏度)
    @Published var sensitivity: Sensitivity = .medium
    
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
