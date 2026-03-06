import Foundation

public enum DownloadValidationError: Error, Equatable, LocalizedError {
    case missingOrInvalidURL
    case missingFileExtension
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .missingOrInvalidURL:
            return L10n.tr("Paste a direct video link and tap Download.")
        case .missingFileExtension:
            return L10n.tr("Selected format is not available for this source video.")
        case .unsupportedFormat(let value):
            return L10n.fmt("%@ (unavailable for this video)", value.uppercased())
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
    public var lastFreeHideAt: Date?

    public init(
        hasWeekly: Bool = false,
        hasMonthly: Bool = false,
        hasLifetime: Bool = false,
        lastFreeDownloadAt: Date? = nil,
        lastFreeHideAt: Date? = nil
    ) {
        self.hasWeekly = hasWeekly
        self.hasMonthly = hasMonthly
        self.hasLifetime = hasLifetime
        self.lastFreeDownloadAt = lastFreeDownloadAt
        self.lastFreeHideAt = lastFreeHideAt
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
            return "org.icorpvideo.VideoDownloader.weekly"
        case .monthly:
            return "org.icorpvideo.VideoDownloader.monthly"
        case .lifetime:
            return "org.icorpvideo.VideoDownloader.lifetime"
        }
    }

    public var title: String {
        switch self {
        case .weekly:
            return L10n.tr("Weekly")
        case .monthly:
            return L10n.tr("Monthly")
        case .lifetime:
            return L10n.tr("One-time")
        }
    }

    public var subtitle: String {
        switch self {
        case .weekly:
            return L10n.tr("Unlimited usage, billed weekly")
        case .monthly:
            return L10n.tr("Unlimited usage, billed monthly")
        case .lifetime:
            return L10n.tr("Unlimited usage forever")
        }
    }

    public var fallbackDisplayPrice: String {
        switch self {
        case .weekly:
            return "$0.99"
        case .monthly:
            return "$2.99"
        case .lifetime:
            return "$29.90"
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

    public func evaluateHide(
        entitlements: SubscriptionEntitlementState,
        now: Date = .init(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> DownloadAccessDecision {
        if entitlements.hasActivePaidAccess {
            return DownloadAccessDecision(isAllowed: true, shouldRecordFreeDownload: false, requiresPaywall: false)
        }

        guard let lastFreeHideAt = entitlements.lastFreeHideAt else {
            return DownloadAccessDecision(isAllowed: true, shouldRecordFreeDownload: true, requiresPaywall: false)
        }

        if calendar.isDate(lastFreeHideAt, inSameDayAs: now) {
            return DownloadAccessDecision(isAllowed: false, shouldRecordFreeDownload: false, requiresPaywall: true)
        }

        return DownloadAccessDecision(isAllowed: true, shouldRecordFreeDownload: true, requiresPaywall: false)
    }

    public func recordFreeHideIfNeeded(
        decision: DownloadAccessDecision,
        current: SubscriptionEntitlementState,
        at now: Date = .init()
    ) -> SubscriptionEntitlementState {
        guard decision.shouldRecordFreeDownload else { return current }

        var updated = current
        updated.lastFreeHideAt = now
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
