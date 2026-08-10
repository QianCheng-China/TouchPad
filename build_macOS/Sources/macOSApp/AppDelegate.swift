import Cocoa
import ApplicationServices // 【修复】必须导入此模块以使用辅助功能和 AXIsProcessTrustedWithOptions

class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        // 设置状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "TouchPad") {
                image.isTemplate = true
                button.image = image
                button.toolTip = "TouchPad Control Center"
            } else {
                button.title = "T"
            }
        }
        
        rebuildMenu()
        
        // 监听设备变化
        NotificationCenter.default.addObserver(forName: .deviceListChanged, object: nil, queue: .main) { _ in self.rebuildMenu() }
        
        // 请求辅助功能权限（必须用于触控控制）
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        
        // 启动网络服务
        startNetworkServices()
    }
    
    func rebuildMenu() {
        let menu = NSMenu()
        
        // 输入模式
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
        
        // 屏幕镜像
        let mirrorItem = NSMenuItem(title: "屏幕镜像", action: #selector(toggleScreenMirroring), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.state = AppState.shared.screenMirroringEnabled ? .on : .off
        mirrorItem.isEnabled = !AppState.shared.trackpadEnabled // 互斥
        menu.addItem(mirrorItem)
        
        // 触控板输入
        let trackpadItem = NSMenuItem(title: "将手指作为触控板输入", action: #selector(toggleTrackpad), keyEquivalent: "")
        trackpadItem.target = self
        if AppState.shared.inputMode == .stylusOnly {
            trackpadItem.isEnabled = !AppState.shared.screenMirroringEnabled // 互斥
            trackpadItem.state = AppState.shared.trackpadEnabled ? .on : .off
        } else {
            trackpadItem.state = .off
            trackpadItem.isEnabled = false
        }
        menu.addItem(trackpadItem)
        
        // 设备列表
        menu.addItem(NSMenuItem.separator())
        let deviceMenuItem = NSMenuItem(title: "设备列表", action: nil, keyEquivalent: "")
        let deviceSubMenu = NSMenu()
        let scanItem = NSMenuItem(title: "扫描新设备", action: #selector(scanNewDevices), keyEquivalent: "")
        scanItem.target = self
        deviceSubMenu.addItem(scanItem)
        deviceSubMenu.addItem(NSMenuItem.separator())
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
        
        // 锁定与退出
        menu.addItem(NSMenuItem.separator())
        let lockItem = NSMenuItem(title: "锁定移动设备", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        lockItem.state = AppState.shared.isLocked ? .on : .off
        menu.addItem(lockItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Actions
    @objc func toggleScreenMirroring() {
        AppState.shared.screenMirroringEnabled.toggle()
        if AppState.shared.screenMirroringEnabled {
            // 互斥逻辑
            if AppState.shared.trackpadEnabled {
                AppState.shared.trackpadEnabled = false
                sendCommandToClient("CMD_TRACKPAD_OFF")
            }
            
            // 启动视频流
            ScreenStreamer.shared.start()
            sendCommandToClient("CMD_MIRROR_ON")
        } else {
            ScreenStreamer.shared.stop()
            sendCommandToClient("CMD_MIRROR_OFF")
        }
        rebuildMenu()
    }

    @objc func toggleTrackpad() {
        guard AppState.shared.inputMode == .stylusOnly else { return }
        AppState.shared.trackpadEnabled.toggle()
        if AppState.shared.trackpadEnabled {
            if AppState.shared.screenMirroringEnabled {
                AppState.shared.screenMirroringEnabled = false
                ScreenStreamer.shared.stop()
                sendCommandToClient("CMD_MIRROR_OFF")
            }
            sendCommandToClient("CMD_TRACKPAD_ON")
        } else {
            sendCommandToClient("CMD_TRACKPAD_OFF")
        }
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

    @objc func changeModeStylus() {
        AppState.shared.inputMode = .stylusOnly
        rebuildMenu()
    }

    @objc func selectDevice(_ sender: NSMenuItem) {
        AppState.shared.activeDevice = sender.representedObject as? String
        rebuildMenu()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func scanNewDevices() {
        Thread { setupAdbTunnel() }.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.rebuildMenu()
        }
    }
}
