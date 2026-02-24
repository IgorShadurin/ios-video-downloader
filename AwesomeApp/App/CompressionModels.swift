import Foundation
import StoreKit

struct VideoMediaMetadata: Codable, Equatable {
    let durationSeconds: Double?
    let width: Int?
    let height: Int?
    let codec: String?

    var resolutionText: String? {
        guard let width, let height else {
            return nil
        }
        return "\(width)x\(height)"
    }
}

struct StoredVideo: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceURL: String
    var localFileName: String
    var title: String
    var createdAt: Date
    var formatIdentifier: String
    var fileSizeBytes: Int64?
    var metadata: VideoMediaMetadata?
    var isHidden: Bool

    init(
        id: UUID = UUID(),
        sourceURL: String,
        localFileName: String,
        title: String,
        createdAt: Date = .now,
        formatIdentifier: String,
        fileSizeBytes: Int64? = nil,
        metadata: VideoMediaMetadata? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.localFileName = localFileName
        self.title = title
        self.createdAt = createdAt
        self.formatIdentifier = formatIdentifier
        self.fileSizeBytes = fileSizeBytes
        self.metadata = metadata
        self.isHidden = isHidden
    }

    var localURL: URL {
        DownloadDirectory.shared.videoDirectory.appendingPathComponent(localFileName)
    }

    var formatLabel: String {
        formatIdentifier.uppercased()
    }

    var sizeText: String {
        guard let fileSizeBytes else {
            return "—"
        }
        return byteCount(fileSizeBytes)
    }

    var resolutionText: String {
        metadata?.resolutionText ?? "Unknown"
    }

    var durationText: String {
        guard let seconds = metadata?.durationSeconds, seconds > 0 else {
            return "Unknown"
        }
        return formatSeconds(seconds)
    }
}

struct DownloadResult {
    let video: StoredVideo
    let sourceResponseHeaders: [String: String]
}

enum DownloadState: Equatable {
    case idle
    case validating
    case checkingAccess
    case downloading(progress: Double)
    case finalizing
    case completed(StoredVideo)
    case failed(String)
}

struct VaultSession {
    var isUnlocked: Bool
    var failedAttempts: Int
}

struct PurchasePlanPresentation: Identifiable {
    let plan: PurchasePlan
    let product: Product?

    var id: PurchasePlan { plan }

    var displayPrice: String {
        product?.displayPrice ?? "—"
    }
}

struct DownloadPlanSnapshot {
    var canEditSourceURL = true
    var isBusy = false
}

struct ActiveDownloadUIState {
    var sourceURL: String = ""
    var lastValidationMessage: String?
    var status: DownloadState = .idle
    var isCancelEnabled = false
    var isCanceling = false
}

func humanBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

func byteCount(_ value: Int64) -> String {
    humanBytes(value)
}

func formatSeconds(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else {
        return "0:00"
    }

    let rounded = Int(seconds.rounded())
    let minutes = rounded / 60
    let remainingSeconds = rounded % 60
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

struct AppErrorMessage: Identifiable {
    var id: UUID = UUID()
    let message: String
}
