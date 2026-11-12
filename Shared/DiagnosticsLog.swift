import Foundation
import os.log

/// Ring-buffer diagnostics shared by the menubar agent (and reusable patterns for extensions).
public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()

    public static let subsystem = AppConstants.appBundleID
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "App")
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 200
    private let iso = ISO8601DateFormatter()

    public var onChange: (() -> Void)?

    private init() {
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func info(_ message: String) {
        append(level: "INFO", message)
        logger.info("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        append(level: "ERROR", message)
        logger.error("\(message, privacy: .public)")
    }

    public func error(_ error: Error, context: String) {
        let ns = error as NSError
        let detail = "\(context): \(ns.domain) code=\(ns.code) — \(ns.localizedDescription)"
        self.error(detail)
        if !ns.userInfo.isEmpty {
            self.error("userInfo: \(ns.userInfo)")
        }
    }

    public func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    public func copyToPasteboard() {
        #if canImport(AppKit)
        // App target only; extension won't call this.
        #endif
    }

    public func persistToDisk() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClassicAFP", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("classicafp-\(Int(Date().timeIntervalSince1970)).log")
        try snapshot().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(level: String, _ message: String) {
        let stamp = iso.string(from: Date())
        let line = "[\(stamp)] \(level) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
        // Always mirror to a rolling file for sessions without the UI open.
        appendToRollingFile(line)
    }

    private func appendToRollingFile(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClassicAFP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("latest.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        if let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
