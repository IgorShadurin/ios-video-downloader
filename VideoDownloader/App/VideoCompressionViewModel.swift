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
    @Published private(set) var statusMessage: String = L10n.tr("Paste a direct video link and tap Download.")
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
            return L10n.tr("Forever")
        }
        if entitlements.hasMonthly {
            return L10n.tr("Monthly")
        }
        if entitlements.hasWeekly {
            return L10n.tr("Weekly")
        }

        let downloadDecision = accessPolicy.evaluate(entitlements: entitlements)
        let hideDecision = accessPolicy.evaluateHide(entitlements: entitlements)

        if downloadDecision.requiresPaywall && hideDecision.requiresPaywall {
            return L10n.tr("Daily free limit reached.")
        }
        if !downloadDecision.requiresPaywall && !hideDecision.requiresPaywall {
            return L10n.tr("Free plan allows only 1 usage per day. Upgrade for unlimited usage.")
        }
        if downloadDecision.requiresPaywall {
            return L10n.tr("One usage left today.")
        }
        return L10n.tr("One usage left today.")
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
            errorMessage = nil
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
            errorMessage = L10n.tr("Daily free limit reached.")
            return
        }

        let fileName = makeFileName(from: sourceURL, format: format)

        state = .validating
        statusMessage = L10n.tr("Checking format compatibility...")
        errorMessage = nil

        do {
            state = .downloading(progress: 0)
            statusMessage = L10n.tr("Processing...")

            let downloadedURL = try await downloadService.download(from: sourceURL, fileName: fileName) { [weak self] value in
                Task { @MainActor in
                    guard self != nil else { return }
                    self?.state = .downloading(progress: value)
                }
            }

            state = .saving
            statusMessage = L10n.tr("Processing...")

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
            statusMessage = L10n.tr("Done.")

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
                statusMessage = L10n.tr("Conversion cancelled.")
            } else {
                statusMessage = L10n.tr("Conversion failed.")
                errorMessage = error.localizedDescription
            }
            state = .idle
        }
    }

    func cancelDownload() {
        downloadService.cancel()
        state = .idle
        statusMessage = L10n.tr("Conversion cancelled.")
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
            errorMessage = L10n.tr("Daily free limit reached.")
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
            vaultStatusMessage = nil
            return
        }
        guard passcode.count >= 4 else {
            vaultStatusMessage = nil
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
            vaultStatusMessage = L10n.tr("Incorrect passcode.")
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
        statusMessage = L10n.tr("Debug: free conversion limit reset for today.")
    }

    func debugApplyShowcase(
        sourceURL: String,
        state: State,
        videos: [StoredVideo],
        hasVaultPasscode: Bool,
        isVaultUnlocked: Bool
    ) {
        sourceURLText = sourceURL
        self.state = state
        downloadedVideos = videos
        self.isVaultUnlocked = isVaultUnlocked
        vaultPasscodeInput = ""
        vaultStatusMessage = nil
        errorMessage = nil

        switch state {
        case .idle:
            statusMessage = L10n.tr("Paste a direct video link and tap Download.")
        case .validating:
            statusMessage = L10n.tr("Checking format compatibility...")
        case .downloading:
            statusMessage = L10n.tr("Processing...")
        case .saving:
            statusMessage = L10n.tr("Processing...")
        }

        if hasVaultPasscode {
            store.setVaultPasscode("1234")
        } else {
            store.clearVaultPasscode()
        }
    }

    func debugMakeShowcaseVideos(totalCount: Int, hiddenCount: Int) -> [StoredVideo] {
        let count = max(0, totalCount)
        let hidden = max(0, min(hiddenCount, count))
        var videos: [StoredVideo] = []
        videos.reserveCapacity(count)

        for index in 0..<count {
            let video = StoredVideo(
                sourceURL: "https://yumcut.com/download-demo/six-seven-demo.MP4",
                localFileName: "showcase_video_\(index + 1).mp4",
                title: "Video \(index + 1)",
                createdAt: Date().addingTimeInterval(-Double(index) * 900),
                formatIdentifier: "mp4",
                fileSizeBytes: Int64(12_000_000 + (index * 1_800_000)),
                metadata: VideoMediaMetadata(
                    durationSeconds: 40 + Double(index * 12),
                    width: 1080,
                    height: 1920,
                    codec: "h264"
                ),
                isHidden: index < hidden
            )
            videos.append(video)
        }

        return videos
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
        statusMessage = L10n.tr("Paste a direct video link and tap Download.")
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
        return L10n.tr("New video")
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
