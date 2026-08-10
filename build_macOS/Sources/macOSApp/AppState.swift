import Foundation
import Combine
import Cocoa

extension Notification.Name {
    static let deviceListChanged = Notification.Name("deviceListChanged")
}

class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - 枚举定义
    enum InputMode: String {
        case both = "触控笔 + 手指"
        case stylusOnly = "仅触控笔"
    }

    enum ZoomMode: String, CaseIterable {
        case smart = "智能缩放"
        case system = "系统缩放"
        case browser = "浏览器缩放"
        case keyboard = "键盘缩放"
    }

    enum Sensitivity: String, CaseIterable {
        case low = "低灵敏度"
        case medium = "中灵敏度"
        case high = "高灵敏度"

        var swipeThreshold: CGFloat {
            switch self {
            case .low: return 90
            case .medium: return 60
            case .high: return 40
            }
        }

        var pinchThreshold: CGFloat {
            switch self {
            case .low: return 600
            case .medium: return 400
            case .high: return 250
            }
        }

        var zoomStepThreshold: CGFloat {
            switch self {
            case .low: return 40
            case .medium: return 30
            case .high: return 20
            }
        }
    }

    enum GestureOption: CaseIterable {
        case singleFingerMove
        case pinchZoomAndScroll
        case launchpad
        case appExpose
        case showDesktop
        case missionControl
        case desktopSwitch

        var displayName: String {
            switch self {
            case .singleFingerMove: return "单指移动光标"
            case .pinchZoomAndScroll: return "缩放与滚动"
            case .launchpad: return "启动台"
            case .appExpose: return "App Expose"
            case .showDesktop: return "显示桌面"
            case .missionControl: return "Mission Control"
            case .desktopSwitch: return "桌面切换"
            }
        }

        var key: String {
            switch self {
            case .singleFingerMove: return "singleFingerMove"
            case .pinchZoomAndScroll: return "pinchZoomAndScroll"
            case .launchpad: return "launchpad"
            case .appExpose: return "appExpose"
            case .showDesktop: return "showDesktop"
            case .missionControl: return "missionControl"
            case .desktopSwitch: return "desktopSwitch"
            }
        }
    }

    struct GestureOptions {
        private var enabledSet: Set<String> = []

        init() {
            enabledSet.insert(GestureOption.singleFingerMove.key)
            enabledSet.insert(GestureOption.pinchZoomAndScroll.key)
            enabledSet.insert(GestureOption.desktopSwitch.key)
        }

        func isEnabled(_ opt: GestureOption) -> Bool {
            return enabledSet.contains(opt.key)
        }

        mutating func set(_ opt: GestureOption, enabled: Bool) {
            if enabled {
                enabledSet.insert(opt.key)
            } else {
                enabledSet.remove(opt.key)
            }
        }

        mutating func toggle(_ opt: GestureOption) {
            if isEnabled(opt) {
                set(opt, enabled: false)
            } else {
                set(opt, enabled: true)
            }
        }
    }

    // MARK: - 存储属性
    @Published var inputMode: InputMode = .stylusOnly
    @Published var connectedDevices: [String] = []
    @Published var activeDevice: String? = nil
    @Published var isMouseDown: Bool = false
    @Published var isLocked: Bool = false
    @Published var trackpadEnabled: Bool = false
    @Published var zoomMode: ZoomMode = .smart
    @Published var sensitivity: Sensitivity = .medium
    @Published var gestureOptions = GestureOptions()
    
    // 新增：屏幕镜像状态
    @Published var screenMirroringEnabled: Bool = false

    // MARK: - 方法
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
            }
            self.isMouseDown = false

            // 【关键修复】设备断开连接时，强制重置所有运行状态
            // 这样可以确保菜单栏自动取消勾选，并且下次连接时不会状态冲突
            self.screenMirroringEnabled = false
            self.trackpadEnabled = false
            self.isLocked = false

            NotificationCenter.default.post(name: .deviceListChanged, object: nil)
        }
    }

    func toggleGestureOption(_ opt: GestureOption) {
        gestureOptions.toggle(opt)
    }

    func setGestureOption(_ opt: GestureOption, enabled: Bool) {
        gestureOptions.set(opt, enabled: enabled)
    }
}
