#!/usr/bin/env swift
import Foundation

// Usage: swift find_hid_symbols.swift SymbolA SymbolB ...
// Example: swift find_hid_symbols.swift IOHIDEventCreateMagnifyEvent IOHIDEventSystemClientDispatchEvent

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: \(args[0]) SYMBOL [SYMBOL ...]")
    exit(1)
}

let symbols = Array(args.dropFirst())

// 常见候选路径（可按需增删或把路径放到命令行参数里）
let candidatePaths = [
    "/System/Library/Frameworks/IOKit.framework/IOKit",
    "/System/Library/PrivateFrameworks/IOHIDFamily.framework/IOHIDFamily",
    "/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
    "/usr/lib/libIOKit.dylib",
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
]

// Helper: run shell command and capture output
@discardableResult
func runCommand(_ launchPath: String, _ arguments: [String]) -> (Int32, String) {
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    do {
        try task.run()
    } catch {
        return (-1, "Failed to run \(launchPath) \(arguments): \(error)")
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    task.waitUntilExit()
    return (task.terminationStatus, output)
}

// Helper: check file exists and is readable
func fileExists(_ path: String) -> Bool {
    return FileManager.default.fileExists(atPath: path)
}

// Try dlopen + dlsym using C APIs via bridging
typealias DlHandle = UnsafeMutableRawPointer

@_silgen_name("dlopen")
func c_dlopen(_ path: UnsafePointer<CChar>?, _ mode: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("dlsym")
func c_dlsym(_ handle: UnsafeMutableRawPointer?, _ symbol: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

@_silgen_name("dlerror")
func c_dlerror() -> UnsafePointer<CChar>?

let RTLD_NOW: Int32 = 2

func dlopenPath(_ path: String) -> UnsafeMutableRawPointer? {
    return c_dlopen(path.withCString { $0 }, RTLD_NOW)
}

func dlsymSymbol(_ handle: UnsafeMutableRawPointer?, _ symbol: String) -> UnsafeMutableRawPointer? {
    return c_dlsym(handle, symbol.withCString { $0 })
}

func dlerrorString() -> String? {
    if let err = c_dlerror() {
        return String(cString: err)
    }
    return nil
}

// nm availability
let nmPath = "/usr/bin/nm"
let hasNM = fileExists(nmPath)

// Search logic
print("Searching for symbols: \(symbols.joined(separator: ", "))")
print("Candidate paths to probe: \(candidatePaths.joined(separator: ", "))")
print("nm available: \(hasNM ? "yes" : "no")")
print("----\n")

for path in candidatePaths {
    print("Checking path: \(path)")
    if !fileExists(path) {
        print("  -> not found on disk")
        print("")
        continue
    }

    // Try dlopen
    if let handle = dlopenPath(path) {
        print("  dlopen succeeded for \(path)")
        for sym in symbols {
            if let ptr = dlsymSymbol(handle, sym) {
                print("    dlsym: symbol '\(sym)' FOUND at address \(ptr)")
            } else {
                let err = dlerrorString() ?? "<no dlerror>"
                print("    dlsym: symbol '\(sym)' NOT found (dlerror: \(err))")
            }
        }
        // Note: we intentionally do not dlclose(handle) to avoid unloading system frameworks
    } else {
        let err = dlerrorString() ?? "<no dlerror>"
        print("  dlopen failed: \(err)")
    }

    // If nm exists, run nm -gU to inspect exported symbols (may require root for some files)
    if hasNM {
        print("  Running nm -gU (may be slow)...")
        let (status, output) = runCommand(nmPath, ["-gU", path])
        if status == 0 {
            // For readability, only show lines that match any symbol
            var foundAny = false
            let lines = output.split(separator: "\n")
            for line in lines {
                for sym in symbols {
                    if line.contains(sym) {
                        if !foundAny {
                            print("    nm matches:")
                            foundAny = true
                        }
                        print("      \(line)")
                    }
                }
            }
            if !foundAny {
                print("    nm: no matching exported symbols found")
            }
        } else {
            print("    nm failed (status \(status)). Output:\n\(output.prefix(2000))")
        }
    } else {
        print("  nm not available; skipping nm check")
    }

    print("")
}

// Additionally, scan common private frameworks directory if exists
let privateFrameworksDir = "/System/Library/PrivateFrameworks"
if fileExists(privateFrameworksDir) {
    print("Scanning PrivateFrameworks directory for candidate binaries (this may take a while)...")
    if let enumerator = FileManager.default.enumerator(atPath: privateFrameworksDir) {
        var scanned = 0
        for case let item as String in enumerator {
            if item.hasSuffix(".framework") || item.hasSuffix(".dylib") {
                let full = privateFrameworksDir + "/" + item
                scanned += 1
                if scanned > 2000 { break } // safety cap
                // Try quick dlsym probe
                if let handle = dlopenPath(full) {
                    for sym in symbols {
                        if let ptr = dlsymSymbol(handle, sym) {
                            print("Found symbol '\(sym)' in \(full) at \(ptr)")
                        }
                    }
                }
            }
        }
    } else {
        print("  Unable to enumerate \(privateFrameworksDir)")
    }
} else {
    print("Private frameworks directory not present: \(privateFrameworksDir)")
}

print("\nSearch complete.")
