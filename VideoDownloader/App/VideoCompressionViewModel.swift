import AVFoundation
import Combine
import Foundation
import StoreKit

@MainActor
final class VideoDownloaderViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case validating
        case downloading(progress: Double)
        case saving
    }

    @Published var sourceURLText: String = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var statusMessage: String = "Paste a direct video link and tap Download."
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadedVideos: [StoredVideo] = []
    @Published private(set) var entitlements: SubscriptionEntitlementState
    @Published private(set) var isPaywallPresented: Bool = false
    @Published private(set) var purchaseOptions: [PurchasePlanOption] = []
    @Published private(set) var isPurchasingPlan: Bool = false
    @Published private(set) var isVaultUnlocked = false
    @Published var vaultPasscodeInput: String = ""
    @Published private(set) var vaultStatusMessage: String?

    let resolver = SupportedFormatResolver()
    private let store = VideoStorageStore()
    private let downloadService: VideoDownloadServiceProtocol
    private let metadataInspector = VideoMetadataInspector()
    private let accessPolicy = DownloadAccessPolicy()
    private let purchaseManager = PurchaseManager()

    init(downloadService: VideoDownloadServiceProtocol? = nil) {
        self.downloadService = downloadService ?? VideoDownloadService()
        self.entitlements = store.loadEntitlements()
        self.downloadedVideos = store.loadVideos()

        sanitizePersistedCatalog()
        Task {
            await refreshMonetizationState()
        }
    }

    var supportedFormatsText: String {
        resolver.supportedDownloadFormats().map(\.displayName).joined(separator: ", ")
    }

    var hasPaidAccess: Bool {
        entitlements.hasActivePaidAccess
    }

    var canDownload: Bool {
        if case .downloading = state { return false }
        return resolverURL != nil
    }

    var resolverURL: URL? {
        let trimmed = sourceURLText.trimmed()
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var resolverFormat: SupportedFormat? {
        guard let text = resolverURL?.absoluteString else { return nil }
        return try? resolver.validate(urlString: text)
    }

    var visibleVideos: [StoredVideo] {
        downloadedVideos.filter { !$0.isHidden }
    }

    var hiddenVideos: [StoredVideo] {
        downloadedVideos.filter { $0.isHidden }
    }

    var hasVaultPasscode: Bool {
        store.hasVaultPasscode()
    }

    var canShowHidden: Bool {
        hasVaultPasscode && isVaultUnlocked
    }

    var subscriptionText: String {
        if entitlements.hasLifetime {
            return "Lifetime unlocked"
        }
        if entitlements.hasMonthly {
            return "Monthly active"
        }
        if entitlements.hasWeekly {
            return "Weekly active"
        }

        let downloadDecision = accessPolicy.evaluate(entitlements: entitlements)
        let hideDecision = accessPolicy.evaluateHide(entitlements: entitlements)

        if downloadDecision.requiresPaywall && hideDecision.requiresPaywall {
            return "Daily free limits reached"
        }
        if !downloadDecision.requiresPaywall && !hideDecision.requiresPaywall {
            return "1 free download + 1 hide daily"
        }
        if downloadDecision.requiresPaywall {
            return "1 free hide remaining today"
        }
        return "1 free download remaining today"
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    var progress: Double {
        if case .downloading(let value) = state { return value }
        if case .saving = state { return 1 }
        return 0
    }

    func validateSource() -> SupportedFormat? {
        guard let url = resolverURL else {
            errorMessage = "Invalid URL format."
            return nil
        }

        do {
            let format = try resolver.validate(url: url)
            errorMessage = nil
            return format
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func downloadVideo() async {
        guard state == .idle else { return }

        guard let format = validateSource(), let sourceURL = resolverURL else {
            return
        }

        let accessDecision = accessPolicy.evaluate(entitlements: entitlements)
        if !accessDecision.isAllowed {
            openPaywall()
            errorMessage = "Daily free limit reached. Upgrade to continue."
            return
        }

        let fileName = makeFileName(from: sourceURL, format: format)

        state = .validating
        statusMessage = "Validating source URL..."
        errorMessage = nil

        do {
            state = .downloading(progress: 0)
            statusMessage = "Downloading..."

            let downloadedURL = try await downloadService.download(from: sourceURL, fileName: fileName) { [weak self] value in
                Task { @MainActor in
                    guard self != nil else { return }
                    self?.state = .downloading(progress: value)
                }
            }

            state = .saving
            statusMessage = "Verifying media..."

            let metadata = try await metadataInspector.inspect(url: downloadedURL)
            let fileSize = try metadataInspector.inspectFileSize(url: downloadedURL)

            let entry = StoredVideo(
                sourceURL: sourceURL.absoluteString,
                localFileName: fileName,
                title: sourceFilenameTitle(from: sourceURL),
                createdAt: .now,
                formatIdentifier: format.identifier,
                fileSizeBytes: fileSize,
                metadata: metadata,
                isHidden: false
            )

            downloadedVideos.removeAll { $0.localFileName == fileName }
            downloadedVideos.insert(entry, at: 0)
            saveVideos()
            sourceURLText = ""
            statusMessage = "Download completed."

            if accessDecision.shouldRecordFreeDownload {
                entitlements = accessPolicy.recordFreeDownloadIfNeeded(
                    decision: accessDecision,
                    current: entitlements
                )
                store.saveEntitlements(entitlements)
            }

            state = .idle
        } catch {
            try? FileManager.default.removeItem(at: DownloadDirectory.shared.videoDirectory.appendingPathComponent(fileName))

            if let error = error as? VideoDownloadServiceError, case .cancelled = error {
                statusMessage = "Download canceled."
            } else {
                statusMessage = "Download failed."
                errorMessage = error.localizedDescription
            }
            state = .idle
        }
    }

    func cancelDownload() {
        downloadService.cancel()
        state = .idle
        statusMessage = "Download canceled by user."
    }

    func delete(_ video: StoredVideo) {
        downloadedVideos.removeAll { $0.id == video.id }
        try? FileManager.default.removeItem(at: video.localURL)
        saveVideos()
    }

    func hide(_ video: StoredVideo) {
        let hideDecision = accessPolicy.evaluateHide(entitlements: entitlements)
        guard hideDecision.isAllowed else {
            openPaywall()
            errorMessage = "Daily free hide limit reached. Upgrade to continue."
            return
        }

        guard let index = downloadedVideos.firstIndex(where: { $0.id == video.id }) else { return }
        downloadedVideos[index].isHidden = true
        saveVideos()
        errorMessage = nil

        if hideDecision.shouldRecordFreeDownload {
            entitlements = accessPolicy.recordFreeHideIfNeeded(
                decision: hideDecision,
                current: entitlements
            )
            store.saveEntitlements(entitlements)
        }
    }

    func unhide(_ video: StoredVideo) {
        guard let index = downloadedVideos.firstIndex(where: { $0.id == video.id }) else { return }
        downloadedVideos[index].isHidden = false
        saveVideos()
    }

    func rename(_ video: StoredVideo, to title: String) {
        guard let index = downloadedVideos.firstIndex(where: { $0.id == video.id }) else { return }
        downloadedVideos[index].title = title.trimmed().isEmpty ? video.title : title.trimmed()
        saveVideos()
    }

    func requestUnlockVault() {
        vaultStatusMessage = nil
    }

    func lockVault() {
        isVaultUnlocked = false
        vaultStatusMessage = nil
    }

    func submitVaultPasscode() {
        let passcode = vaultPasscodeInput.trimmed()
        guard !passcode.isEmpty else {
            vaultStatusMessage = "Passcode cannot be empty."
            return
        }
        guard passcode.count >= 4 else {
            vaultStatusMessage = "Passcode must be at least 4 characters."
            return
        }

        if !store.hasVaultPasscode() {
            store.setVaultPasscode(passcode)
            isVaultUnlocked = true
            vaultStatusMessage = nil
            vaultPasscodeInput = ""
            return
        }

        if store.isPasscodeValid(passcode) {
            isVaultUnlocked = true
            vaultStatusMessage = nil
            vaultPasscodeInput = ""
        } else {
            vaultStatusMessage = "Incorrect passcode."
        }
    }

    func clearVaultPasscodeAndDeleteHiddenVideos() {
        let hiddenVideos = downloadedVideos.filter(\.isHidden)
        for hiddenVideo in hiddenVideos {
            try? FileManager.default.removeItem(at: hiddenVideo.localURL)
        }
        downloadedVideos.removeAll(where: \.isHidden)
        saveVideos()

        store.clearVaultPasscode()
        isVaultUnlocked = false
        vaultStatusMessage = nil
    }

    func openPaywall() {
        isPaywallPresented = true
        Task {
            await refreshMonetizationState()
        }
    }

    func dismissPaywall() {
        isPaywallPresented = false
    }

#if DEBUG
    func debugResetLimitsForTesting() {
        store.debugResetDailyFreeLimits()
        entitlements = store.loadEntitlements()
        errorMessage = nil
        statusMessage = "Debug: daily free limits reset."
    }
#endif

    func purchasePlan(planID: String) async {
        guard !isPurchasingPlan else { return }

        isPurchasingPlan = true
        errorMessage = nil

        do {
            let didPurchase = try await purchaseManager.purchase(productID: planID)
            if didPurchase {
                await refreshEntitlementsFromStoreKit()
                if hasPaidAccess {
                    statusMessage = L10n.tr("Premium unlocked. Unlimited usage enabled.")
                    isPaywallPresented = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isPurchasingPlan = false
        await refreshMonetizationState()
    }

    func restorePurchases() async {
        guard !isPurchasingPlan else { return }

        isPurchasingPlan = true
        errorMessage = nil

        do {
            let hasRestoredAccess = try await purchaseManager.restorePurchases()
            await refreshEntitlementsFromStoreKit()

            if hasRestoredAccess && hasPaidAccess {
                statusMessage = L10n.tr("Purchases restored. Unlimited usage enabled.")
                isPaywallPresented = false
            } else {
                statusMessage = L10n.tr("No active purchases found.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isPurchasingPlan = false
        await refreshMonetizationState()
    }

    func clearInput() {
        sourceURLText = ""
        statusMessage = "Paste a direct video link and tap Download."
        errorMessage = nil
    }

    private func saveVideos() {
        store.saveVideos(downloadedVideos)
        DownloadDirectory.shared.cleanupOrphans(for: downloadedVideos)
    }

    private func sanitizePersistedCatalog() {
        var valid: [StoredVideo] = []

        for item in downloadedVideos where FileManager.default.fileExists(atPath: item.localURL.path) {
            valid.append(item)
        }

        if valid.count != downloadedVideos.count {
            downloadedVideos = valid
            store.saveVideos(valid)
        }

        DownloadDirectory.shared.cleanupOrphans(for: valid)
    }

    private func sourceFilenameTitle(from url: URL) -> String {
        let trimmed = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed.replacingOccurrences(of: ".\(url.pathExtension)", with: "")
        }
        return "Downloaded video"
    }

    private func makeFileName(from sourceURL: URL, format: SupportedFormat) -> String {
        let host = sourceURL.host?.replacingOccurrences(of: ".", with: "_") ?? "video"
        return "\(host)_\(UUID().uuidString.prefix(8)).\(format.identifier)"
    }

    private func refreshMonetizationState() async {
        purchaseOptions = await purchaseManager.loadPlanOptions()
        await refreshEntitlementsFromStoreKit()
    }

    private func refreshEntitlementsFromStoreKit() async {
        var restored: Set<PurchasePlan> = []

        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else {
                continue
            }
            guard transaction.revocationDate == nil else {
                continue
            }
            if let expirationDate = transaction.expirationDate,
               expirationDate < Date()
            {
                continue
            }
            if let plan = PurchasePlan.from(productIdentifier: transaction.productID) {
                restored.insert(plan)
            }
        }

        entitlements = accessPolicy.applyingRestore(restoredPlans: restored, to: entitlements)
        store.saveEntitlements(entitlements)
    }
}
