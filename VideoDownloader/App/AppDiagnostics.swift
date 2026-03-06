import Foundation

actor AppDiagnostics {
    static let shared = AppDiagnostics()

    static let logDirectoryName = "Diagnostics"
    static let logFileName = "conversion-diagnostics.jsonl"
    static let logRelativePath = "Documents/\(logDirectoryName)/\(logFileName)"

    private let fileManager = FileManager.default
    private let iso8601: ISO8601DateFormatter
    private let logFileURL: URL
    private let maxLogSizeBytes: Int64 = 2 * 1024 * 1024

    private init() {
        iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let diagnosticsDirectoryURL = documentsURL.appendingPathComponent(Self.logDirectoryName, isDirectory: true)
        logFileURL = diagnosticsDirectoryURL.appendingPathComponent(Self.logFileName, isDirectory: false)
    }

    func log(
        level: String = "info",
        category: String,
        message: String,
        context: [String: String] = [:]
    ) {
        do {
            try prepareDirectoryIfNeeded()
            try rotateIfNeeded()

            let event: [String: Any] = [
                "timestamp": iso8601.string(from: Date()),
                "level": level,
                "category": category,
                "message": message,
                "context": context
            ]
            let data = try JSONSerialization.data(withJSONObject: event, options: [])
            try appendLine(data)
        } catch {
            // Intentionally swallow diagnostics failures.
        }
    }

    private func prepareDirectoryIfNeeded() throws {
        let directoryURL = logFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func rotateIfNeeded() throws {
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            return
        }
        let values = try logFileURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
        let size = Int64(values.fileSize ?? values.fileAllocatedSize ?? 0)
        guard size >= maxLogSizeBytes else {
            return
        }

        let rotatedURL = logFileURL.deletingLastPathComponent().appendingPathComponent("conversion-diagnostics.previous.jsonl")
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try? fileManager.removeItem(at: rotatedURL)
        }
        try fileManager.moveItem(at: logFileURL, to: rotatedURL)
    }

    private func appendLine(_ data: Data) throws {
        let lineBreak = Data([0x0A])
        if !fileManager.fileExists(atPath: logFileURL.path) {
            var firstLine = data
            firstLine.append(lineBreak)
            try firstLine.write(to: logFileURL, options: [.atomic])
            return
        }

        let handle = try FileHandle(forWritingTo: logFileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: lineBreak)
    }
}

extension Dictionary where Key == String, Value == String {
    static func diagnostics(_ pairs: (String, String?)...) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in pairs {
            if let value {
                result[key] = value
            }
        }
        return result
    }
}
