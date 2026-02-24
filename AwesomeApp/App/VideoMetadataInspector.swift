import AVFoundation
import Foundation

struct VideoMetadataInspector {
    func isPlayableURL(_ url: URL) async -> Bool {
        guard (url.isFileURL) else {
            return false
        }

        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            let hasVideoTrack = tracks.contains { $0.mediaType == .video }
            let isPlayable = try await asset.load(.isPlayable)
            return hasVideoTrack && isPlayable
        } catch {
            return false
        }
    }

    func inspect(url: URL) async throws -> VideoMediaMetadata {
        let asset = AVURLAsset(url: url)

        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw MediaInspectionError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let dimensions = naturalSize.applying(try await videoTrack.load(.preferredTransform))
        let width = Int(abs(dimensions.width).rounded())
        let height = Int(abs(dimensions.height).rounded())

        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let codec = formatDescriptions
            .compactMap(codecFromFormatDescription)
            .first

        return VideoMediaMetadata(
            durationSeconds: duration.seconds,
            width: max(1, width),
            height: max(1, height),
            codec: codec
        )
    }

    func inspectFileSize(url: URL) throws -> Int64 {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(resourceValues.fileSize ?? 0)
    }
}

enum MediaInspectionError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Downloaded file does not contain a video stream."
        }
    }
}

private func codecFromFormatDescription(_ value: CMFormatDescription) -> String {
    let subtype = CMFormatDescriptionGetMediaSubType(value)
    let raw = [0, 8, 16, 24].map {
        UInt8((subtype >> $0) & 0xFF)
    }

    let chars = raw.compactMap { Character(UnicodeScalar($0)) }
    return String(chars)
}
