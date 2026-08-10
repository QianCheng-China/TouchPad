import Foundation
import Cocoa
import CoreGraphics
import CoreMedia
import VideoToolbox
import Darwin
import CoreVideo

let VIDEO_PORT: UInt16 = 9528

class ScreenStreamer {
    static let shared = ScreenStreamer()
    private var streamLoop: Thread?
    private var isStreaming = false
    private var compressionSession: VTCompressionSession?
    private var videoServerSocket: Int32 = -1
    private var clientSocket: Int32? = nil
    private var frameCount = 0
    private var displayStream: CGDisplayStream?
    private let encodeQueue = DispatchQueue(label: "com.touchpad.screen.encode")
    
    private let kCVPixelFormatType_32BGRA_Custom: OSType = 0x42475241

    func start() {
        guard !isStreaming else { NSLog("[Streamer] Already running"); return }
        isStreaming = true
        NSLog("[Streamer] Starting video service...")

        videoServerSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard videoServerSocket != -1 else { NSLog("[Streamer] ERROR: cannot create socket"); isStreaming = false; return }
        var reuse: Int32 = 1
        setsockopt(videoServerSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(VIDEO_PORT).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)
        
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(videoServerSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindRes != -1 else { NSLog("[Streamer] ERROR: bind failed"); close(videoServerSocket); isStreaming = false; return }
        listen(videoServerSocket, 1)
        NSLog("[Streamer] Video server listening on port \(VIDEO_PORT)")

        streamLoop = Thread { [weak self] in
            while self?.isStreaming == true {
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
                let sock = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self!.videoServerSocket, $0, &clientAddrLen)
                    }
                }
                if self?.isStreaming == false { break }
                if sock > 0 {
                    NSLog("[Streamer] Client connected")
                    self?.clientSocket = sock
                    self?.frameCount = 0
                    if self?.setupCompressionSession() == true {
                        self?.startDisplayStream()
                    } else {
                        NSLog("[Streamer] ERROR: compression session setup failed")
                        close(sock)
                    }
                    var buffer = [UInt8](repeating: 0, count: 1)
                    while self?.isStreaming == true && recv(sock, &buffer, 1, 0) > 0 { sleep(1) }
                    NSLog("[Streamer] Client disconnected")
                    self?.stopDisplayStream()
                    self?.teardownCompressionSession()
                    close(sock)
                    self?.clientSocket = nil
                } else { break }
            }
        }
        streamLoop?.start()
    }

    func stop() {
        isStreaming = false
        if let sock = clientSocket { close(sock); clientSocket = nil }
        if videoServerSocket != -1 { close(videoServerSocket); videoServerSocket = -1 }
        streamLoop?.cancel()
        stopDisplayStream()
        teardownCompressionSession()
    }

    // MARK: - Compression session
    private func setupCompressionSession() -> Bool {
        guard compressionSession == nil else { return true }
        guard let screen = NSScreen.main else { NSLog("[Streamer] ERROR: cannot get main screen"); return false }
        
        // 【关键修复】使用物理像素分辨率，而不是逻辑像素
        let scale = screen.backingScaleFactor
        let width = Int32(screen.frame.width * scale)
        let height = Int32(screen.frame.height * scale)
        
        NSLog("[Streamer] Resolution: \(width)x\(height) (Scale: \(scale))")
        
        var session: VTCompressionSession?
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA_Custom,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &session
        )
        guard status == noErr, let s = session else { NSLog("[Streamer] ERROR: VTCompressionSessionCreate failed \(status)"); return false }
        compressionSession = s
        
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 30))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 8000000))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: NSNumber(value: 0)) // Disable VBR for better realtime consistency

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    private func teardownCompressionSession() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    // MARK: - CGDisplayStream capture
    private func startDisplayStream() {
        stopDisplayStream()
        let mainDisplay = CGMainDisplayID()
        guard let screen = NSScreen.main else { return }
        
        // 使用物理像素尺寸
        let scale = screen.backingScaleFactor
        let width = Int(screen.frame.width * scale)
        let height = Int(screen.frame.height * scale)
        
        let handler: CGDisplayStreamFrameAvailableHandler = { (status, displayTime, frameSurface, updateRef) in
            guard status == .frameComplete else { return }
            guard let frameSurface = frameSurface else { return }
            var pixelBuffer: Unmanaged<CVPixelBuffer>?
            let result = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, frameSurface, nil, &pixelBuffer)
            if result == kCVReturnSuccess, let pb = pixelBuffer?.takeRetainedValue() {
                self.encodeQueue.async { self.encodePixelBuffer(pb, presentationTime: displayTime) }
            }
        }
        
        let streamOptions: [String: Any] = [
            CGDisplayStream.showCursor as String: true,
            CGDisplayStream.preserveAspectRatio as String: false // 强制全屏拉伸
        ]
        
        // 使用物理像素作为输出尺寸
        displayStream = CGDisplayStream(
            dispatchQueueDisplay: mainDisplay,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA_Custom),
            properties: streamOptions as CFDictionary,
            queue: DispatchQueue.global(qos: .userInteractive),
            handler: handler
        )
        if let ds = displayStream {
            let startStatus = ds.start()
            if startStatus != .success {
                NSLog("[Streamer] ERROR: CGDisplayStream start failed")
                if startStatus.rawValue == 1004 {
                    NSLog("[Streamer] 错误码 1004: 请前往 系统设置 -> 隐私与安全性 -> 屏幕录制")
                }
            } else {
                NSLog("[Streamer] CGDisplayStream started successfully at \(width)x\(height).")
            }
        }
    }

    private func stopDisplayStream() {
        if let ds = displayStream { ds.stop(); displayStream = nil }
    }

    // MARK: - Encoding
    private func encodePixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: UInt64) {
        guard let session = compressionSession else { return }
        let pts = CMTime(value: Int64(presentationTime), timescale: 600)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr { NSLog("[Streamer] Encode frame failed: \(status)") }
    }

    private let compressionOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
        guard status == noErr, let sampleBuffer = sampleBuffer else { return }
        let streamer = Unmanaged<ScreenStreamer>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
        streamer.handleEncodedSample(sampleBuffer: sampleBuffer)
    }

    // MARK: - Encoded Sample Handling
    private func handleEncodedSample(sampleBuffer: CMSampleBuffer) {
        guard let sock = clientSocket else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { ptr in
            if let baseAddr = ptr.baseAddress { CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddr) }
        }
        let annexBData = convertAVCCToAnnexB(data)
        
        if frameCount == 0 {
            if let (spsData, ppsData) = getParameterSets(from: sampleBuffer) {
                func sendPacket(rawPayload: Data) {
                    var packetData = Data([0x00, 0x00, 0x00, 0x01])
                    packetData.append(rawPayload)
                    let len = UInt32(packetData.count)
                    var header = [UInt8](repeating: 0, count: 5)
                    header[0] = 1
                    for i in 0..<4 { header[i+1] = UInt8(truncatingIfNeeded: len >> (8 * (3-i))) }
                    Darwin.send(sock, &header, header.count, 0)
                    Darwin.send(sock, [UInt8](packetData), packetData.count, 0)
                }
                sendPacket(rawPayload: spsData)
                sendPacket(rawPayload: ppsData)
            }
        }
        let netLength = Int32(annexBData.count)
        var header = [UInt8](repeating: 0, count: 5)
        header[0] = 1
        for i in 0..<4 { header[i+1] = UInt8(truncatingIfNeeded: netLength >> (8 * (3-i))) }
        Darwin.send(sock, &header, header.count, 0)
        Darwin.send(sock, [UInt8](annexBData), annexBData.count, 0)
        frameCount += 1
    }

    private func getParameterSets(from sampleBuffer: CMSampleBuffer) -> (Data, Data)? {
        var sps: Data? = nil
        var pps: Data? = nil
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr {
                for i in 0..<count {
                    var psPtr: UnsafePointer<UInt8>? = nil
                    var psSize: Int = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &psPtr, parameterSetSizeOut: &psSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if status == noErr, let ptr = psPtr {
                        let data = Data(bytes: ptr, count: psSize)
                        if i == 0 { sps = data } else { pps = data }
                    }
                }
            }
        }
        if let s = sps, let p = pps { return (s, p) }
        return nil
    }

    private func convertAVCCToAnnexB(_ data: Data) -> Data {
        var output = Data()
        var index = 0
        while index + 4 <= data.count {
            let lengthData = data.subdata(in: index..<index+4)
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            index += 4
            if index + Int(length) > data.count { break }
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            let naluData = data.subdata(in: index..<index+Int(length))
            output.append(naluData)
            index += Int(length)
        }
        return output
    }
}
