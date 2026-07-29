import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSLog("[TouchPad] 正在初始化...")
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: "TouchPad") {
                image.isTemplate = true
                button.image = image
                button.toolTip = "TouchPad Control Center"
            } else {
                button.title = "T"
            }
        } else {
            NSLog("[TouchPad] 错误: 无法创建状态栏按钮")
            return
        }
        
        rebuildMenu()
        NotificationCenter.default.addObserver(forName: .deviceListChanged, object: nil, queue: .main) { _ in self.rebuildMenu() }
        
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("[TouchPad] 警告: 缺少辅助功能权限")
        }
        startNetworkServices()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        
        // --- 输入模式子菜单 ---
        let modeMenuItem = NSMenuItem(title: "输入模式", action: nil, keyEquivalent: "")
        let modeSubMenu = NSMenu()
        
        let stylusItem = NSMenuItem(title: "仅主动式触控笔", action: #selector(changeModeStylus), keyEquivalent: "")
        stylusItem.target = self
        stylusItem.state = (AppState.shared.inputMode == .stylusOnly) ? .on : .off
        
        let bothItem = NSMenuItem(title: "广泛", action: #selector(changeModeBoth), keyEquivalent: "")
        bothItem.target = self
        bothItem.state = (AppState.shared.inputMode == .both) ? .on : .off
        
        modeSubMenu.addItem(stylusItem)
        modeSubMenu.addItem(bothItem)
        modeMenuItem.submenu = modeSubMenu
        menu.addItem(modeMenuItem)
        
        // --- 手势功能子菜单 (仅在触控笔模式下可用) ---
        if AppState.shared.inputMode == .stylusOnly {
            let gestureMenuItem = NSMenuItem(title: "手指功能", action: nil, keyEquivalent: "")
            let gestureSubMenu = NSMenu()
            
            let gOnItem = NSMenuItem(title: "缩放与平移", action: #selector(enableGesture), keyEquivalent: "")
            gOnItem.target = self
            gOnItem.state = (AppState.shared.gestureEnabled) ? .on : .off
            
            let gOffItem = NSMenuItem(title: "忽略触摸", action: #selector(disableGesture), keyEquivalent: "")
            gOffItem.target = self
            gOffItem.state = (!AppState.shared.gestureEnabled) ? .on : .off
            
            gestureSubMenu.addItem(gOnItem)
            gestureSubMenu.addItem(gOffItem)
            gestureMenuItem.submenu = gestureSubMenu
            menu.addItem(gestureMenuItem)
        }
        
        // --- 设备列表 ---
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
        deviceSubMenu.addItem(NSMenuItem.separator())
        let scanItem = NSMenuItem(title: "扫描新设备...", action: #selector(scanDevices), keyEquivalent: "")
        scanItem.target = self
        deviceSubMenu.addItem(scanItem)
        deviceMenuItem.submenu = deviceSubMenu
        menu.addItem(deviceMenuItem)
        
        // --- 锁定 ---
        menu.addItem(NSMenuItem.separator())
        let lockItem = NSMenuItem(title: "锁定移动设备 TouchPad 界面", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        lockItem.state = AppState.shared.isLocked ? .on : .off
        menu.addItem(lockItem)
        
        // --- 退出 ---
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc func toggleLock() {
        AppState.shared.isLocked.toggle()
        if AppState.shared.isLocked { sendCommandToClient("CMD_LOCK") }
        else { sendCommandToClient("CMD_UNLOCK") }
        rebuildMenu()
    }
    
    @objc func enableGesture() {
        AppState.shared.gestureEnabled = true
        sendCommandToClient("CMD_GESTURE_ON")
        NSLog("[TouchPad] CMD_GESTURE_ON sent")
        rebuildMenu()
    }
    
    @objc func disableGesture() {
        AppState.shared.gestureEnabled = false
        sendCommandToClient("CMD_GESTURE_OFF")
        NSLog("[TouchPad] CMD_GESTURE_OFF sent")
        rebuildMenu()
    }
    
    @objc func changeModeBoth() {
        AppState.shared.inputMode = .both
        // 切换广泛模式时，关闭手势
        AppState.shared.gestureEnabled = false
        sendCommandToClient("CMD_GESTURE_OFF")
        rebuildMenu()
        NSLog("[TouchPad] Mode: Both (Mouse)")
    }
    
    @objc func changeModeStylus() {
        AppState.shared.inputMode = .stylusOnly
        rebuildMenu()
        NSLog("[TouchPad] Mode: Stylus Only")
    }
    
    @objc func selectDevice(_ sender: NSMenuItem) {
        if let deviceId = sender.representedObject as? String {
            AppState.shared.activeDevice = deviceId
            rebuildMenu()
        }
    }
    
    @objc func scanDevices() {
        Thread { setupAdbTunnel() }.start()
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
