#!/usr/bin/env swift
// find_hid_symbols_full.swift
//
// Recursively scan the filesystem (or specified roots) for binaries that export one or more symbols.
// For each candidate binary it will attempt dlopen + dlsym and (if available) run `nm -gU` to verify exports.
// Usage:
//   swift find_hid_symbols_full.swift SYMBOL [SYMBOL ...]
//   swift find_hid_symbols_full.swift -r /path/to/scan SYMBOL ...
//   swift find_hid_symbols_full.swift --no-limit SYMBOL ...
//
// Notes:
// - Scanning the entire filesystem can be slow and may require elevated permissions for some paths.
// - By default the script skips a set of system/virtual directories that are not useful to scan.
// - You can pass `--no-limit` to remove the file-scan cap (use with caution).
// - The script prints detailed logs to stdout.

import Foundation

// MARK: - Arguments and options

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: \(args[0]) [--no-limit] [-r rootPath] SYMBOL [SYMBOL ...]")
    exit(1)
}

var symbols: [String] = []
var roots: [String] = ["/"]            // default root: filesystem root
var noLimit = false
var i = 1
while i < args.count {
    let a = args[i]
    if a == "--no-limit" {
        noLimit = true
        i += 1
        continue
    }
    if a == "-r" || a == "--root" {
        if i + 1 < args.count {
            roots = [args[i+1]]
            i += 2
            continue
        } else {
            print("Error: -r requires a path")
            exit(2)
        }
    }
    // remaining args are symbols
    symbols = Array(args[i...])
    break
}

guard !symbols.isEmpty else {
    print("Error: no symbols provided")
    exit(3)
}

print("Searching for symbols: \(symbols.joined(separator: ", "))")
print("Roots: \(roots.joined(separator: ", "))")
print("No-limit: \(noLimit)")
print("----\n")

// MARK: - Helpers: shell command runner

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

// MARK: - dlopen/dlsym/dlerror wrappers (use Darwin)
import Darwin

func dlopenHandle(_ path: String) -> UnsafeMutableRawPointer? {
    return Darwin.dlopen(path, RTLD_NOW)
}
func dlsymPtr(_ handle: UnsafeMutableRawPointer?, _ symbol: String) -> UnsafeMutableRawPointer? {
    return Darwin.dlsym(handle, symbol)
}
func dlerrorString() -> String? {
    if let err = Darwin.dlerror() {
        return String(cString: err)
    }
    return nil
}

// MARK: - File scanning

let fileManager = FileManager.default

// Exclude common virtual or irrelevant directories to avoid endless loops and permission noise.
// You can adjust this list if you want a truly exhaustive scan.
let defaultExclusions: Set<String> = [
    "/dev", "/proc", "/Volumes", "/Network", "/private/var/vm", "/private/var/run",
    "/private/var/folders", "/System/Volumes/Preboot", "/System/Volumes/Update",
    "/System/Volumes/VM", "/.fseventsd", "/cores"
]

// Candidate filename suffixes to consider as binaries
let candidateSuffixes = [".dylib", ".so", ".bundle", ".framework", ".a", ""] // include files without suffix (executables)

// Cap scanned files to avoid runaway scans (unless --no-limit)
let defaultFileCap = 20000
var scannedCount = 0
let fileCap = noLimit ? Int.max : defaultFileCap

// A thread-safe results collector
let resultsLock = NSLock()
var found: [(symbol: String, path: String, address: String)] = []

// Helper to test a single file path
func probeBinary(at fullPath: String) {
    // Quick filename filter
    let lower = fullPath.lowercased()
    var okSuffix = false
    for s in candidateSuffixes {
        if s.isEmpty {
            // treat files with no suffix but executable permission as candidates
            if fileManager.isExecutableFile(atPath: fullPath) {
                okSuffix = true
                break
            }
        } else if lower.hasSuffix(s) {
            okSuffix = true
            break
        }
    }
    if !okSuffix { return }

    // Attempt dlopen
    guard let handle = dlopenHandle(fullPath) else {
        // optional: print dlerror for debugging
        // let err = dlerrorString() ?? "<no dlerror>"
        // print("dlopen failed for \(fullPath): \(err)")
        return
    }

    // For each symbol, try dlsym
    for sym in symbols {
        if let ptr = dlsymPtr(handle, sym) {
            let addr = String(describing: ptr)
            resultsLock.lock()
            found.append((symbol: sym, path: fullPath, address: addr))
            resultsLock.unlock()
            // keep searching other symbols in same binary
        }
    }
    // Do not dlclose system libraries to avoid instability
}

// Enumerate roots
let queue = DispatchQueue(label: "scanner", attributes: .concurrent)
let group = DispatchGroup()

for root in roots {
    // If root is a file, probe directly
    var isDir: ObjCBool = false
    if fileManager.fileExists(atPath: root, isDirectory: &isDir), !isDir.boolValue {
        scannedCount += 1
        probeBinary(at: root)
        continue
    }

    // Walk directory
    let enumerator = fileManager.enumerator(atPath: root)
    if enumerator == nil {
        print("Unable to enumerate \(root) (permission or not found).")
        continue
    }

    for case let item as String in enumerator! {
        // Build full path
        let full = (root as NSString).appendingPathComponent(item)

        // Skip excluded prefixes
        var skip = false
        for ex in defaultExclusions {
            if full.hasPrefix(ex) {
                skip = true
                break
            }
        }
        if skip { continue }

        // Skip directories that are obviously not interesting
        if item.hasPrefix(".") { continue } // hidden files/dirs
        // Limit scanned files
        scannedCount += 1
        if scannedCount > fileCap {
            print("Reached file cap (\(fileCap)). Use --no-limit to scan everything.")
            break
        }

        // Probe asynchronously to utilize multiple cores
        group.enter()
        queue.async {
            probeBinary(at: full)
            group.leave()
        }
    }
    // wait for this root's tasks to finish before moving to next root
    group.wait()
    if scannedCount > fileCap { break }
}

// Wait for all tasks
group.wait()

// If nm is available, run nm -gU on matching files to show exported lines (slower, optional)
let nmPath = "/usr/bin/nm"
let hasNM = fileManager.fileExists(atPath: nmPath)

if found.isEmpty {
    print("No matches found via dlopen/dlsym in scanned paths.")
} else {
    print("dlopen/dlsym matches:")
    for r in found {
        print("  Symbol '\(r.symbol)' found in: \(r.path) at \(r.address)")
    }
}

// Optionally run nm for each unique path to show exported symbol lines
if hasNM && !found.isEmpty {
    print("\nRunning nm -gU on matched binaries (this may require permissions and be slow)...")
    let uniquePaths = Array(Set(found.map { $0.path }))
    for path in uniquePaths {
        print("\nnm -gU \(path) ->")
        let (status, output) = runCommand(nmPath, ["-gU", path])
        if status == 0 {
            // Print only lines that match any symbol
            let lines = output.split(separator: "\n")
            var printedAny = false
            for line in lines {
                for sym in symbols {
                    if line.contains(sym) {
                        if !printedAny {
                            printedAny = true
                        }
                        print("  \(line)")
                    }
                }
            }
            if !printedAny {
                print("  (nm did not show matching exported symbols)")
            }
        } else {
            print("  nm failed (status \(status)). Output:\n\(output.prefix(2000))")
        }
    }
}

print("\nScan complete. Scanned approx \(scannedCount) filesystem entries. Found \(found.count) matches.")
