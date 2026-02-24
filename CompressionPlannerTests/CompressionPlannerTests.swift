import Foundation
import Testing
@testable import CompressionPlanner

struct CompressionPlannerTests {
    private let accessPolicy = DownloadAccessPolicy()
    private let resolver = SupportedFormatResolver()

    @Test
    func supportsExpectedPlayableExtensions() {
        #expect(resolver.supportedDownloadFormats().map(\.identifier).contains("mp4"))
        #expect(resolver.supportedDownloadFormats().map(\.identifier).contains("mov"))
        #expect(resolver.supportedDownloadFormats().map(\.identifier).contains("m4v"))
        #expect(resolver.supportedDownloadFormats().map(\.identifier).contains("3gp"))
        #expect(resolver.supportedDownloadFormats().map(\.identifier).contains("3g2"))
    }

    @Test
    func validatesSupportedUrlFormat() throws {
        let mp4 = try resolver.validate(urlString: "https://cdn.example.com/video.mp4")
        let mov = try resolver.validate(urlString: "https://cdn.example.com/video.MOV")
        let withQuery = try resolver.validate(urlString: "https://cdn.example.com/path/video.MOV?token=abc123")

        #expect(mp4.identifier == "mp4")
        #expect(mov.identifier == "mov")
        #expect(withQuery.identifier == "mov")
    }

    @Test
    func rejectsUnsupportedOrInvalidUrl() {
        #expect(throws: DownloadValidationError.missingFileExtension) {
            _ = try resolver.validate(urlString: "https://cdn.example.com/video")
        }

        #expect(throws: DownloadValidationError.unsupportedFormat("avi")) {
            _ = try resolver.validate(urlString: "https://cdn.example.com/video.avi")
        }

        #expect(throws: DownloadValidationError.missingOrInvalidURL) {
            _ = try resolver.validate(urlString: "not a url")
        }
    }

    @Test
    func indicatesPlayableFormatsFromResolver() {
        #expect(resolver.isLikelyPlayableURL(URL(string: "https://cdn.example.com/video.MOV")!))
        #expect(!resolver.isLikelyPlayableURL(URL(string: "https://cdn.example.com/archive.zip")!))
    }

    @Test
    func oneFreeDownloadPerDayForUnpaidUsers() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let neverDownloaded = SubscriptionEntitlementState()
        let first = accessPolicy.evaluate(entitlements: neverDownloaded, now: now)
        #expect(first.isAllowed)
        #expect(first.shouldRecordFreeDownload)
        #expect(!first.requiresPaywall)

        let consumedState = accessPolicy.recordFreeDownloadIfNeeded(
            decision: first,
            current: neverDownloaded,
            at: now
        )

        let second = accessPolicy.evaluate(entitlements: consumedState, now: now)
        #expect(!second.isAllowed)
        #expect(!second.shouldRecordFreeDownload)
        #expect(second.requiresPaywall)
    }

    @Test
    func paidPlansUnlockAllDownloads() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let base = SubscriptionEntitlementState(lastFreeDownloadAt: now)
        let upgraded = accessPolicy.applyingPurchase(plan: .lifetime, to: base)

        let decision = accessPolicy.evaluate(entitlements: upgraded, now: now)
        #expect(decision.isAllowed)
        #expect(!decision.shouldRecordFreeDownload)
        #expect(!decision.requiresPaywall)
    }

    @Test
    func restorePrefersLatestPlanState() {
        let restored = accessPolicy.applyingRestore(restoredPlans: [.lifetime], to: SubscriptionEntitlementState(hasWeekly: true))

        #expect(restored.hasLifetime)
        #expect(!restored.hasMonthly)
        #expect(!restored.hasWeekly)
    }
}
