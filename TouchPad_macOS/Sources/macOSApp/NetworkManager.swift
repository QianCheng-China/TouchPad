import Foundation
import Cocoa

let TCP_PORT: UInt16 = 9527
let UDP_PORT: UInt16 = 9528

var currentClientSocket: Int32? = nil

func startNetworkServices() {
    Thread {
        setupAdbTunnel()
        startUdpBeacon()
        startTcpServer()
    }.start()
}

public func setupAdbTunnel() {
    var paths = [String]()
    
    // 1. 【最高优先级】查找 App 包内部的 adb (Resources 目录)
    if let bundlePath = Bundle.main.path(forResource: "adb", ofType: nil) {
        paths.append(bundlePath)
    }
    
    // 2. 【备选】查找系统路径 (兼容开发者环境)
    paths.append(contentsOf: [
        "/usr/local/bin/adb",
        "/opt/homebrew/bin/adb",
        "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
    ])
    
    var adbPath: String?
    for path in paths {
        // 检查文件是否存在且可执行
        if FileManager.default.isExecutableFile(atPath: path) {
            adbPath = path
            break
        }
    }
    
    guard let path = adbPath else {
        NSLog("[TouchPad] 未找到 adb 可执行文件")
        return
    }
    
    // --- 以下是原有的执行逻辑 ---
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = ["devices"]
    let pipe = Pipe()
    task.standardOutput = pipe
    
    do { try task.run(); task.waitUntilExit() } catch { return }
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    let lines = output.components(separatedBy: "\n")
    
    for line in lines {
        if line.contains("List of devices attached") || line.isEmpty { continue }
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        if parts.count >= 2 && String(parts[1]) == "device" {
            let serial = String(parts[0])
            runAdbCommand(path: path, serial: serial)
        }
    }
}


func runAdbCommand(path: String, serial: String) {
    DispatchQueue.global().async {
        let tunnelTask = Process()
        tunnelTask.executableURL = URL(fileURLWithPath: path)
        tunnelTask.arguments = ["-s", serial, "reverse", "tcp:9527", "tcp:9527"]
        do {
            try tunnelTask.run(); tunnelTask.waitUntilExit()
            if tunnelTask.terminationStatus == 0 {
                NSLog("[TouchPad] ADB 隧道已建立: \(serial)")
                
                let nameTask = Process()
                nameTask.executableURL = URL(fileURLWithPath: path)
                nameTask.arguments = ["-s", serial, "shell", "settings", "get", "secure", "bluetooth_name"]
                let namePipe = Pipe()
                nameTask.standardOutput = namePipe
                
                do {
                    try nameTask.run(); nameTask.waitUntilExit()
                    let nameData = namePipe.fileHandleForReading.readDataToEndOfFile()
                    var deviceName = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if deviceName.isEmpty { deviceName = serial }
                    AppState.shared.registerDevice(deviceName)
                } catch {
                    AppState.shared.registerDevice(serial)
                }
            }
        } catch { NSLog("[TouchPad] ADB 执行异常") }
    }
}

func sendCommandToClient(_ cmd: String) {
    guard let sock = currentClientSocket else { return }
    let data = "\(cmd)\n".data(using: .utf8)!
    var bytes = [UInt8](data)
    Darwin.send(sock, &bytes, bytes.count, 0)
}

// ... (startUdpBeacon 保持不变) ...
func startUdpBeacon() {
    DispatchQueue.global().async {
        let socket = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UDP_PORT).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)
        
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if bindRes < 0 { return }
        
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
            
            let len = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socket, &buffer, buffer.count, 0, $0, &clientLen)
                }
            }
            
            if len > 0 {
                if let data = "TABLET_SERVER_ACK".data(using: .utf8) {
                    var bytes = [UInt8](data)
                    _ = withUnsafePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socket, &bytes, bytes.count, 0, $0, clientLen)
                        }
                    }
                }
            }
        }
    }
}

func startTcpServer() {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var reuse: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(TCP_PORT).bigEndian
    addr.sin_addr.s_addr = in_addr_t(0)
    
    _ = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
    listen(listener, 5)
    NSLog("[TouchPad] 数位板服务已启动")

    while true {
        var clientAddr = sockaddr_in()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
        
        let clientSock = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listener, $0, &clientAddrLen)
            }
        }
        
        if clientSock > 0 {
            var noDelay: Int32 = 1
            setsockopt(clientSock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            
            currentClientSocket = clientSock
            DispatchQueue.global().async {
                handleClient(sock: clientSock)
            }
        }
    }
}

func handleClient(sock: Int32) {
    var buffer = [UInt8](repeating: 0, count: 1024)
    var recvStr = ""
    var deviceId: String? = nil
    
    while true {
        let len = recv(sock, &buffer, buffer.count, 0)
        if len <= 0 { break }
        
        let chunkData = Data(bytes: &buffer, count: Int(len))
        if let chunk = String(data: chunkData, encoding: .utf8) { recvStr.append(chunk) }
        
        while let range = recvStr.range(of: "\n") {
            let msg = String(recvStr[..<range.lowerBound])
            recvStr = String(recvStr[range.upperBound...])
            let cleanMsg = msg.trimmingCharacters(in: .whitespaces)
            
            if cleanMsg.isEmpty { continue }
            
            if cleanMsg.hasPrefix("IDENT,") {
                let name = cleanMsg.replacingOccurrences(of: "IDENT,", with: "")
                deviceId = name
                AppState.shared.registerDevice(name)
                continue
            }
            
            // 【修改】处理同步请求，返回明确的状态字符串
            if cleanMsg == "SYNC_REQ" {
                let resp = AppState.shared.isLocked ? "SYNC_RESP:LOCKED" : "SYNC_RESP:UNLOCKED"
                sendCommandToClient(resp)
                continue
            }
            
            if let id = deviceId {
                processCommand(cleanMsg, from: id)
            }
        }
    }
    
    if let id = deviceId {
        AppState.shared.removeDevice(id)
    }
    if currentClientSocket == sock { currentClientSocket = nil }
    close(sock)
}
