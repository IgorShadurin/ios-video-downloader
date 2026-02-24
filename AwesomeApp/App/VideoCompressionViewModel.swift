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
    @Published private(set) var products: [PurchasePlan: Product] = [:]
    @Published private(set) var isProductsLoading = false
    @Published private(set) var isRestoringPurchases = false
    @Published private(set) var isVaultUnlocked = false
    @Published var vaultPasscodeInput: String = ""
    @Published private(set) var vaultStatusMessage: String?

    let resolver = SupportedFormatResolver()
    private let store = VideoStorageStore()
    private let downloadService: VideoDownloadServiceProtocol
    private let metadataInspector = VideoMetadataInspector()
    private let accessPolicy = DownloadAccessPolicy()

    init(downloadService: VideoDownloadServiceProtocol? = nil) {
        self.downloadService = downloadService ?? VideoDownloadService()
        self.entitlements = store.loadEntitlements()
        self.downloadedVideos = store.loadVideos()

        sanitizePersistedCatalog()
        Task {
            await loadProducts()
            await refreshEntitlementsFromStoreKit()
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
        URL(string: sourceURLText.trimmed())
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

        let decision = accessPolicy.evaluate(entitlements: entitlements)
        return decision.requiresPaywall ? "Daily quota reached" : "1 free download remaining"
    }

    var plans: [PurchasePlanPresentation] {
        PurchasePlan.allCases.map { PurchasePlanPresentation(plan: $0, product: products[$0]) }
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
            isPaywallPresented = true
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
        statusMessage = "Deleted \(video.title)."
    }

    func hide(_ video: StoredVideo) {
        guard let index = downloadedVideos.firstIndex(where: { $0.id == video.id }) else { return }
        downloadedVideos[index].isHidden = true
        saveVideos()
        statusMessage = "\(video.title) moved to hidden."
    }

    func unhide(_ video: StoredVideo) {
        guard let index = downloadedVideos.firstIndex(where: { $0.id == video.id }) else { return }
        downloadedVideos[index].isHidden = false
        saveVideos()
        statusMessage = "\(video.title) unhidden."
    }

    func rename(_ video: StoredVideo, to title: String) {
        guard let index = downloadedVideos.firstIndex(where: { $0.id == video.id }) else { return }
        downloadedVideos[index].title = title.trimmed().isEmpty ? video.title : title.trimmed()
        saveVideos()
    }

    func requestUnlockVault() {
        if !store.hasVaultPasscode() {
            vaultStatusMessage = "Set a vault passcode before opening hidden videos."
        } else if isVaultUnlocked {
            isVaultUnlocked = false
            vaultStatusMessage = nil
        } else {
            vaultStatusMessage = "Enter vault passcode."
        }
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

    func clearVaultPasscode() {
        store.clearVaultPasscode()
        isVaultUnlocked = false
        vaultStatusMessage = "Vault passcode removed."
    }

    func openPaywall() {
        isPaywallPresented = true
    }

    func dismissPaywall() {
        isPaywallPresented = false
    }

    func purchase(plan: PurchasePlan) async -> String {
        guard let product = products[plan] else {
            return PurchaseError.unavailable.localizedDescription
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                entitlements = accessPolicy.applyingPurchase(plan: plan, to: entitlements)
                store.saveEntitlements(entitlements)
                dismissPaywall()
                return "Purchase completed."
            case .userCancelled:
                return "Purchase cancelled."
            case .pending:
                return "Purchase pending."
            @unknown default:
                return "Purchase incomplete."
            }
        } catch {
            return error.localizedDescription
        }
    }

    func restorePurchases() async -> String {
        isRestoringPurchases = true
        defer { isRestoringPurchases = false }

        var restored: Set<PurchasePlan> = []
        do {
            for await verification in Transaction.currentEntitlements {
                let transaction = try checkVerified(verification)
                guard let plan = PurchasePlan.from(productIdentifier: transaction.productID), transaction.revocationDate == nil else {
                    continue
                }
                restored.insert(plan)
            }
        } catch {
            return "Restore failed: \(error.localizedDescription)"
        }

        if restored.isEmpty {
            return "No purchases to restore."
        }

        entitlements = accessPolicy.applyingRestore(restoredPlans: restored, to: entitlements)
        store.saveEntitlements(entitlements)
        return "Purchases restored."
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

    private func loadProducts() async {
        isProductsLoading = true
        defer { isProductsLoading = false }

        do {
            let ids = Set(PurchasePlan.allCases.map(\.productIdentifier))
            let fetched = try await Product.products(for: ids)
            var dict: [PurchasePlan: Product] = [:]

            for product in fetched {
                if let plan = PurchasePlan.from(productIdentifier: product.id) {
                    dict[plan] = product
                }
            }

            products = dict
        } catch {
            products = [:]
        }
    }

    private func refreshEntitlementsFromStoreKit() async {
        var restored: Set<PurchasePlan> = []

        for await verification in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(verification),
               let plan = PurchasePlan.from(productIdentifier: transaction.productID),
               transaction.revocationDate == nil {
                restored.insert(plan)
            }
        }

        if !restored.isEmpty {
            entitlements = accessPolicy.applyingRestore(restoredPlans: restored, to: entitlements)
            store.saveEntitlements(entitlements)
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    private enum PurchaseError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Store item is unavailable."
        }
    }
}
