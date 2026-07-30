import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            // 【修改】使用 pencil.tip 作为状态栏图标
            if let image = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "TouchPad") {
                image.isTemplate = true // 自动适应深色/浅色模式
                button.image = image
                button.toolTip = "TouchPad Control Center"
            } else {
                // 备选方案：如果加载失败则显示文字
                button.title = "T"
            }
        }
        
        rebuildMenu()
        NotificationCenter.default.addObserver(forName: .deviceListChanged, object: nil, queue: .main) { _ in self.rebuildMenu() }
        
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startNetworkServices()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        
        // --- 输入模式 ---
        let modeItem = NSMenuItem(title: "输入模式", action: nil, keyEquivalent: "")
        let modeSubMenu = NSMenu()
        let stylusItem = NSMenuItem(title: "仅主动式触控笔", action: #selector(changeModeStylus), keyEquivalent: "")
        stylusItem.target = self
        stylusItem.state = (AppState.shared.inputMode == .stylusOnly) ? .on : .off
        
        let bothItem = NSMenuItem(title: "广泛", action: #selector(changeModeBoth), keyEquivalent: "")
        bothItem.target = self
        bothItem.state = (AppState.shared.inputMode == .both) ? .on : .off
        
        modeSubMenu.addItem(stylusItem)
        modeSubMenu.addItem(bothItem)
        modeItem.submenu = modeSubMenu
        menu.addItem(modeItem)
        
        // --- 手指触控板开关 ---
        if AppState.shared.inputMode == .stylusOnly {
            let trackpadItem = NSMenuItem(title: "将手指作为触控板输入", action: #selector(toggleTrackpad), keyEquivalent: "")
            trackpadItem.target = self
            trackpadItem.state = AppState.shared.trackpadEnabled ? .on : .off
            menu.addItem(trackpadItem)
        }
        
        // --- 缩放模式选择 ---
        let zoomModeItem = NSMenuItem(title: "双指缩放模式", action: nil, keyEquivalent: "")
        let zoomSubMenu = NSMenu()
        
        for mode in AppState.ZoomMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(changeZoomMode(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.target = self
            item.state = (AppState.shared.zoomMode == mode) ? .on : .off
            zoomSubMenu.addItem(item)
        }
        zoomModeItem.submenu = zoomSubMenu
        menu.addItem(zoomModeItem)
        
        // --- 设备列表 ---
        menu.addItem(NSMenuItem.separator())
        let deviceMenuItem = NSMenuItem(title: "设备列表", action: nil, keyEquivalent: "")
        let deviceSubMenu = NSMenu()
        if AppState.shared.connectedDevices.isEmpty {
            deviceSubMenu.addItem(NSMenuItem(title: "无设备连接", action: nil, keyEquivalent: ""))
        } else {
            for device in AppState.shared.connectedDevices {
                let item = NSMenuItem(title: device, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.representedObject = device
                item.target = self
                item.state = (device == AppState.shared.activeDevice) ? .on : .off
                deviceSubMenu.addItem(item)
            }
        }
        deviceMenuItem.submenu = deviceSubMenu
        menu.addItem(deviceMenuItem)
        
        // --- 锁定与退出 ---
        menu.addItem(NSMenuItem.separator())
        let lockItem = NSMenuItem(title: "锁定移动设备", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        lockItem.state = AppState.shared.isLocked ? .on : .off
        menu.addItem(lockItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    @objc func changeZoomMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? AppState.ZoomMode else { return }
        AppState.shared.zoomMode = mode
        rebuildMenu()
    }
    
    @objc func toggleTrackpad() {
        AppState.shared.trackpadEnabled.toggle()
        let cmd = AppState.shared.trackpadEnabled ? "CMD_TRACKPAD_ON" : "CMD_TRACKPAD_OFF"
        sendCommandToClient(cmd)
        rebuildMenu()
    }
    
    @objc func toggleLock() {
        AppState.shared.isLocked.toggle()
        sendCommandToClient(AppState.shared.isLocked ? "CMD_LOCK" : "CMD_UNLOCK")
        rebuildMenu()
    }
    @objc func changeModeBoth() {
        AppState.shared.inputMode = .both
        AppState.shared.trackpadEnabled = false
        sendCommandToClient("CMD_TRACKPAD_OFF")
        rebuildMenu()
    }
    @objc func changeModeStylus() { AppState.shared.inputMode = .stylusOnly; rebuildMenu() }
    @objc func selectDevice(_ sender: NSMenuItem) { AppState.shared.activeDevice = sender.representedObject as? String; rebuildMenu() }
    @objc func quitApp() { NSApp.terminate(nil) }
}
