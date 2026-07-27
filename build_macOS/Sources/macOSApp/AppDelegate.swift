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
        NotificationCenter.default.addObserver(forName: .deviceListChanged, object: nil, queue: .main) { _ in
            self.rebuildMenu()
        }
        
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
        
        // --- 设备列表子菜单 ---
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
        
        // --- 锁定设备界面 ---
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
        if AppState.shared.isLocked {
            sendCommandToClient("CMD_LOCK")
            NSLog("[TouchPad] 发送锁定指令")
        } else {
            sendCommandToClient("CMD_UNLOCK")
            NSLog("[TouchPad] 发送解锁指令")
        }
        rebuildMenu()
    }
    
    @objc func changeModeBoth() {
        AppState.shared.inputMode = .both
        rebuildMenu()
        NSLog("[TouchPad] 模式切换: 全部接收")
    }
    
    @objc func changeModeStylus() {
        AppState.shared.inputMode = .stylusOnly
        rebuildMenu()
        NSLog("[TouchPad] 模式切换: 仅触控笔")
    }
    
    @objc func selectDevice(_ sender: NSMenuItem) {
        if let deviceId = sender.representedObject as? String {
            AppState.shared.activeDevice = deviceId
            
            // 【终极修复】三重保险机制：
            // 1. 重置软件状态
            AppState.shared.isMouseDown = false
            
            // 2. 强制调用底层鼠标释放（硬件级），解决切换瞬间的卡死问题
            // 注意：这里不需要精确坐标，只需要释放按键动作
            if let screen = NSScreen.main {
                let point = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
                postMouseEvent(type: .leftMouseUp, location: point, button: .left)
            }
            
            // 3. 通知 AppState 进行其他清理
            AppState.shared.forceResetMouseState()
            
            rebuildMenu()
            NSLog("[TouchPad] 切换控制设备: \(deviceId)，已强制释放鼠标")
        }
    }
    
    @objc func scanDevices() {
        NSLog("[TouchPad] 手动触发设备扫描...")
        Thread {
            setupAdbTunnel()
        }.start()
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
