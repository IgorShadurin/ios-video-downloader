import CryptoKit
import Foundation

private struct VaultCredential: Codable {
    let hash: String
    let salt: String
}

final class VideoStorageStore {
    private let defaults: UserDefaults
    private let videosKey = "video_downloader_videos_v1"
    private let entitlementKey = "video_downloader_entitlements_v1"
    private let vaultKey = "video_downloader_vault_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadVideos() -> [StoredVideo] {
        guard let data = defaults.data(forKey: videosKey) else {
            return []
        }

        if let videos = try? JSONDecoder().decode([StoredVideo].self, from: data) {
            return videos.sorted { $0.createdAt > $1.createdAt }
        }

        return []
    }

    func saveVideos(_ videos: [StoredVideo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(videos) else {
            return
        }
        defaults.set(data, forKey: videosKey)
    }

    func loadEntitlements() -> SubscriptionEntitlementState {
        guard let data = defaults.data(forKey: entitlementKey),
              let entitlements = try? JSONDecoder().decode(SubscriptionEntitlementState.self, from: data)
        else {
            return SubscriptionEntitlementState()
        }

        return entitlements
    }

    func saveEntitlements(_ entitlements: SubscriptionEntitlementState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entitlements) else {
            return
        }
        defaults.set(data, forKey: entitlementKey)
    }

    func hasVaultPasscode() -> Bool {
        defaults.data(forKey: vaultKey) != nil
    }

    func isPasscodeValid(_ passcode: String) -> Bool {
        guard let stored = loadVaultCredential() else {
            return false
        }

        guard let saltData = Data(base64Encoded: stored.salt) else {
            return false
        }

        return hash(passcode, salt: saltData) == stored.hash
    }

    func setVaultPasscode(_ passcode: String) {
        let salt = randomSalt()
        let hash = hash(passcode, salt: salt)
        let credential = VaultCredential(hash: hash, salt: salt.base64EncodedString())

        if let data = try? JSONEncoder().encode(credential) {
            defaults.set(data, forKey: vaultKey)
        }
    }

    func clearVaultPasscode() {
        defaults.removeObject(forKey: vaultKey)
    }

    private func loadVaultCredential() -> VaultCredential? {
        guard let data = defaults.data(forKey: vaultKey) else {
            return nil
        }
        return try? JSONDecoder().decode(VaultCredential.self, from: data)
    }

    private func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private func hash(_ passcode: String, salt: Data) -> String {
        let data = Data(passcode.utf8) + salt
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }
}
