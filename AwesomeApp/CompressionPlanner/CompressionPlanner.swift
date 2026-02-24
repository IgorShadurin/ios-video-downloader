import Foundation

public enum DownloadValidationError: Error, Equatable, LocalizedError {
    case missingOrInvalidURL
    case missingFileExtension
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .missingOrInvalidURL:
            return "Enter a valid direct video URL (http or https)."
        case .missingFileExtension:
            return "The link must include a supported video file extension."
        case .unsupportedFormat(let value):
            return "The format \(value) is not supported for iOS playback."
        }
    }
}

public enum SupportedFormat: String, Codable, CaseIterable, Sendable {
    case mp4
    case mov
    case m4v
    case `3gp`
    case `3g2`

    public var identifier: String { rawValue }

    public var displayName: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .m4v: "M4V"
        case .`3gp`: "3GP"
        case .`3g2`: "3G2"
        }
    }

    public static let iosPlayable: [SupportedFormat] = [.mp4, .mov, .m4v, .`3gp`, .`3g2`]

    public static func from(pathExtension: String) -> SupportedFormat? {
        SupportedFormat(rawValue: pathExtension.lowercased().trimmed())
    }

    public var fileExtensions: [String] {
        [rawValue]
    }
}

public extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct DownloadAccessDecision: Equatable, Sendable {
    public let isAllowed: Bool
    public let shouldRecordFreeDownload: Bool
    public let requiresPaywall: Bool

    public init(isAllowed: Bool, shouldRecordFreeDownload: Bool, requiresPaywall: Bool) {
        self.isAllowed = isAllowed
        self.shouldRecordFreeDownload = shouldRecordFreeDownload
        self.requiresPaywall = requiresPaywall
    }
}

public struct SubscriptionEntitlementState: Equatable, Codable, Sendable {
    public var hasWeekly: Bool
    public var hasMonthly: Bool
    public var hasLifetime: Bool
    public var lastFreeDownloadAt: Date?

    public init(hasWeekly: Bool = false, hasMonthly: Bool = false, hasLifetime: Bool = false, lastFreeDownloadAt: Date? = nil) {
        self.hasWeekly = hasWeekly
        self.hasMonthly = hasMonthly
        self.hasLifetime = hasLifetime
        self.lastFreeDownloadAt = lastFreeDownloadAt
    }

    public var hasActivePaidAccess: Bool {
        hasWeekly || hasMonthly || hasLifetime
    }
}

public enum PurchasePlan: String, CaseIterable, Codable, Sendable {
    case weekly
    case monthly
    case lifetime

    public var productIdentifier: String {
        switch self {
        case .weekly:
            return "videodownloader_weekly"
        case .monthly:
            return "videodownloader_monthly"
        case .lifetime:
            return "videodownloader_lifetime"
        }
    }

    public var title: String {
        switch self {
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        case .lifetime:
            return "One-time"
        }
    }

    public var subtitle: String {
        switch self {
        case .weekly:
            return "Unlimited downloads for 7 days"
        case .monthly:
            return "Unlimited downloads for 30 days"
        case .lifetime:
            return "Unlimited downloads forever"
        }
    }

    public static func from(productIdentifier: String) -> PurchasePlan? {
        switch productIdentifier {
        case PurchasePlan.weekly.productIdentifier:
            return .weekly
        case PurchasePlan.monthly.productIdentifier:
            return .monthly
        case PurchasePlan.lifetime.productIdentifier:
            return .lifetime
        default:
            return nil
        }
    }
}

public struct DownloadAccessPolicy {
    public init() {}

    public func evaluate(
        entitlements: SubscriptionEntitlementState,
        now: Date = .init(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> DownloadAccessDecision {
        if entitlements.hasActivePaidAccess {
            return DownloadAccessDecision(isAllowed: true, shouldRecordFreeDownload: false, requiresPaywall: false)
        }

        guard let lastFreeDownloadAt = entitlements.lastFreeDownloadAt else {
            return DownloadAccessDecision(isAllowed: true, shouldRecordFreeDownload: true, requiresPaywall: false)
        }

        if calendar.isDate(lastFreeDownloadAt, inSameDayAs: now) {
            return DownloadAccessDecision(isAllowed: false, shouldRecordFreeDownload: false, requiresPaywall: true)
        }

        return DownloadAccessDecision(isAllowed: true, shouldRecordFreeDownload: true, requiresPaywall: false)
    }

    public func recordFreeDownloadIfNeeded(
        decision: DownloadAccessDecision,
        current: SubscriptionEntitlementState,
        at now: Date = .init()
    ) -> SubscriptionEntitlementState {
        guard decision.shouldRecordFreeDownload else { return current }

        var updated = current
        updated.lastFreeDownloadAt = now
        return updated
    }

    public func applyingPurchase(plan: PurchasePlan, to current: SubscriptionEntitlementState) -> SubscriptionEntitlementState {
        var updated = current
        updated.hasWeekly = false
        updated.hasMonthly = false
        updated.hasLifetime = false

        switch plan {
        case .weekly:
            updated.hasWeekly = true
        case .monthly:
            updated.hasMonthly = true
        case .lifetime:
            updated.hasLifetime = true
        }

        return updated
    }

    public func applyingRestore(restoredPlans: Set<PurchasePlan>, to current: SubscriptionEntitlementState) -> SubscriptionEntitlementState {
        var updated = current
        updated.hasWeekly = restoredPlans.contains(.weekly)
        updated.hasMonthly = restoredPlans.contains(.monthly)
        updated.hasLifetime = restoredPlans.contains(.lifetime)
        return updated
    }
}

public struct SupportedFormatResolver {
    public init() {}

    public func supportedDownloadFormats() -> [SupportedFormat] {
        SupportedFormat.iosPlayable
    }

    public func isLikelyPlayableURL(_ url: URL) -> Bool {
        guard let format = try? validate(url: url) else {
            return false
        }
        return true && supportedDownloadFormats().contains(format)
    }

    public func validate(url: URL) throws -> SupportedFormat {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw DownloadValidationError.missingOrInvalidURL
        }

        guard let ext = url.pathExtension.nilIfEmpty else {
            throw DownloadValidationError.missingFileExtension
        }

        let normalized = ext.lowercased()

        guard let format = SupportedFormat.from(pathExtension: normalized),
              supportedDownloadFormats().contains(format)
        else {
            throw DownloadValidationError.unsupportedFormat(ext)
        }

        return format
    }

    public func validate(urlString: String) throws -> SupportedFormat {
        guard let url = URL(string: urlString.trimmed()) else {
            throw DownloadValidationError.missingOrInvalidURL
        }
        return try validate(url: url)
    }
}

public extension URL {
    var lowercasePathExtension: String? {
        guard let ext = pathExtension.nilIfEmpty else {
            return nil
        }
        return ext.lowercased()
    }
}


private extension String {
    var nilIfEmpty: String? {
        let value = trimmed()
        return value.isEmpty ? nil : value
    }
}

