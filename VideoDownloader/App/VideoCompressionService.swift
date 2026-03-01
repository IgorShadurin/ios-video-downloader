import Foundation

struct DownloadDirectory {
    static let shared = DownloadDirectory()

    private let fileManager = FileManager.default

    var videoDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Videos", isDirectory: true)

        if !fileManager.fileExists(atPath: docs.path) {
            try? fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
        }
        return docs
    }

    func cleanupOrphans(for videos: [StoredVideo]) {
        let managed = Set(videos.map(\.localFileName))
        let all = (try? fileManager.contentsOfDirectory(atPath: videoDirectory.path)) ?? []

        for file in all where !managed.contains(file) {
            try? fileManager.removeItem(at: videoDirectory.appendingPathComponent(file))
        }
    }
}

enum VideoDownloadServiceError: LocalizedError {
    case cancelled
    case invalidHTTPResponse
    case invalidStatus(Int)
    case emptyDestination
    case moveFailed

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Download cancelled."
        case .invalidHTTPResponse:
            return "Server response is invalid."
        case .invalidStatus(let code):
            return "Download blocked by server: status \(code)."
        case .emptyDestination:
            return "Unable to resolve download destination."
        case .moveFailed:
            return "Unable to store the downloaded file."
        }
    }
}

protocol VideoDownloadServiceProtocol {
    func download(
        from sourceURL: URL,
        fileName: String,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL

    func cancel()
    var isRunning: Bool { get }
}

final class VideoDownloadService: NSObject, URLSessionDownloadDelegate, VideoDownloadServiceProtocol {
    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destinationURL: URL?
    private var onProgress: ((Double) -> Void)?

    private(set) var isRunning = false

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    deinit {
        cancel()
    }

    func download(
        from sourceURL: URL,
        fileName: String,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        cancel()

        let destination = DownloadDirectory.shared.videoDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.destinationURL = destination
            self.onProgress = progressHandler
            self.isRunning = true

            let request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            let task = session.downloadTask(with: request)
            activeTask = task
            task.resume()
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
        onProgress = nil

        if let continuation {
            continuation.resume(throwing: VideoDownloadServiceError.cancelled)
            self.continuation = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard downloadTask === activeTask else { return }
        guard expected > 0 else { return }
        let clamped = max(0, min(1, Double(totalBytesWritten) / Double(expected)))
        onProgress?(clamped)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard task === activeTask else { return }
        guard let error else { return }

        if (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: VideoDownloadServiceError.cancelled)
        } else {
            continuation?.resume(throwing: error)
        }

        resetState()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask === activeTask else { return }

        defer { resetState() }

        guard let response = downloadTask.response as? HTTPURLResponse else {
            continuation?.resume(throwing: VideoDownloadServiceError.invalidHTTPResponse)
            return
        }

        guard (200...299).contains(response.statusCode) else {
            continuation?.resume(throwing: VideoDownloadServiceError.invalidStatus(response.statusCode))
            return
        }

        guard let destination = destinationURL else {
            continuation?.resume(throwing: VideoDownloadServiceError.emptyDestination)
            return
        }

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: VideoDownloadServiceError.moveFailed)
        }
    }

    private func resetState() {
        activeTask = nil
        continuation = nil
        destinationURL = nil
        onProgress = nil
        isRunning = false
    }
}
