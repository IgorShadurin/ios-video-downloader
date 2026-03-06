import Foundation
import StoreKit

struct PurchasePlanOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let priceText: String
    let isAvailable: Bool
}

private struct ProductLookupResult {
    let byID: [String: Product]
    let missingProductIDs: [String]
    let storeKitErrorSummary: String?
}

enum PurchaseManagerError: LocalizedError {
    case productUnavailable(
        productID: String,
        missingProductIDs: [String],
        storeKitErrorSummary: String?
    )
    case purchaseFailed(productID: String, storeKitErrorSummary: String)
    case transactionUnverified(productID: String, verificationErrorSummary: String?)
    case pending

    var errorDescription: String? {
        switch self {
        case let .productUnavailable(productID, missingProductIDs, storeKitErrorSummary):
            var details: [String] = [
                L10n.tr("This purchase option is currently unavailable."),
                "Product ID: \(productID)"
            ]
            if !missingProductIDs.isEmpty {
                details.append("Missing from App Store response: \(missingProductIDs.joined(separator: ", "))")
            }
            if let storeKitErrorSummary, !storeKitErrorSummary.isEmpty {
                details.append("StoreKit request failed: \(storeKitErrorSummary)")
            }
            details.append("Check App Store Connect status (Ready for Sale), storefront availability, and Paid Applications agreement.")
            return details.joined(separator: "\n")
        case let .purchaseFailed(productID, storeKitErrorSummary):
            return """
            Purchase failed.
            Product ID: \(productID)
            StoreKit purchase error: \(storeKitErrorSummary)
            """
        case let .transactionUnverified(productID, verificationErrorSummary):
            var details: [String] = [
                "Purchase succeeded but the transaction could not be verified.",
                "Product ID: \(productID)"
            ]
            if let verificationErrorSummary, !verificationErrorSummary.isEmpty {
                details.append("Verification error: \(verificationErrorSummary)")
            }
            return details.joined(separator: "\n")
        case .pending:
            return L10n.tr("Purchase is pending approval.")
        }
    }
}

final class PurchaseManager {
    static let weeklyProductID = "org.icorpvideo.VideoDownloader.weekly"
    static let monthlyProductID = "org.icorpvideo.VideoDownloader.monthly"
    static let lifetimeProductID = "org.icorpvideo.VideoDownloader.lifetime"

    static let productOrder = [
        weeklyProductID,
        monthlyProductID,
        lifetimeProductID
    ]

    private static let fallbackPriceByProductID: [String: String] = [
        weeklyProductID: "$0.99",
        monthlyProductID: "$2.99",
        lifetimeProductID: "$29.90"
    ]

    func loadPlanOptions() async -> [PurchasePlanOption] {
        let lookupResult = await loadProductsByID(for: Self.productOrder)
        let byID = lookupResult.byID

        if !lookupResult.missingProductIDs.isEmpty {
            await AppDiagnostics.shared.log(
                level: "warning",
                category: "purchase",
                message: "storekit_products_missing",
                context: .diagnostics(
                    ("requestedProductIDs", Self.productOrder.joined(separator: ",")),
                    ("missingProductIDs", lookupResult.missingProductIDs.joined(separator: ",")),
                    ("storeKitError", lookupResult.storeKitErrorSummary)
                )
            )
        }

        return Self.productOrder.map { id in
            if let product = byID[id] {
                return PurchasePlanOption(
                    id: id,
                    title: title(for: id),
                    subtitle: subtitle(for: id),
                    priceText: displayPrice(for: id, product: product),
                    isAvailable: true
                )
            }

            return PurchasePlanOption(
                id: id,
                title: title(for: id),
                subtitle: subtitle(for: id),
                priceText: fallbackPrice(for: id),
                isAvailable: false
            )
        }
    }

    func hasActiveEntitlement() async -> Bool {
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else {
                continue
            }
            guard Self.productOrder.contains(transaction.productID) else {
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
            return true
        }

        return false
    }

    func purchase(productID: String) async throws -> Bool {
        let lookupResult = await loadProductsByID(for: [productID])
        guard let product = lookupResult.byID[productID] else {
            throw PurchaseManagerError.productUnavailable(
                productID: productID,
                missingProductIDs: lookupResult.missingProductIDs,
                storeKitErrorSummary: lookupResult.storeKitErrorSummary
            )
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    return true
                case .unverified(_, let verificationError):
                    throw PurchaseManagerError.transactionUnverified(
                        productID: productID,
                        verificationErrorSummary: verificationError.localizedDescription
                    )
                }
            case .pending:
                throw PurchaseManagerError.pending
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch let error as PurchaseManagerError {
            throw error
        } catch {
            throw PurchaseManagerError.purchaseFailed(
                productID: productID,
                storeKitErrorSummary: describeStoreKitError(error)
            )
        }
    }

    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()
        return await hasActiveEntitlement()
    }

    private func loadProductsByID(for requestedIDs: [String]) async -> ProductLookupResult {
        do {
            let products = try await Product.products(for: requestedIDs)
            let byID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            let missingProductIDs = requestedIDs.filter { byID[$0] == nil }
            return ProductLookupResult(
                byID: byID,
                missingProductIDs: missingProductIDs,
                storeKitErrorSummary: nil
            )
        } catch {
            return ProductLookupResult(
                byID: [:],
                missingProductIDs: requestedIDs,
                storeKitErrorSummary: describeStoreKitError(error)
            )
        }
    }

    private func title(for productID: String) -> String {
        switch productID {
        case Self.weeklyProductID:
            return L10n.tr("Weekly")
        case Self.monthlyProductID:
            return L10n.tr("Monthly")
        case Self.lifetimeProductID:
            return L10n.tr("Forever")
        default:
            return L10n.tr("Premium")
        }
    }

    private func subtitle(for productID: String) -> String {
        switch productID {
        case Self.weeklyProductID:
            return L10n.tr("Unlimited usage, billed weekly")
        case Self.monthlyProductID:
            return L10n.tr("Unlimited usage, billed monthly")
        case Self.lifetimeProductID:
            return L10n.tr("Unlimited usage forever")
        default:
            return L10n.tr("Unlimited usage")
        }
    }

    private func fallbackPrice(for productID: String) -> String {
        Self.fallbackPriceByProductID[productID] ?? "$0.00"
    }

    private func displayPrice(for productID: String, product: Product) -> String {
        if productID == Self.lifetimeProductID {
            return "$29.90"
        }
        return product.displayPrice
    }

    private func describeStoreKitError(_ error: Error) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return "\(nsError.domain) (\(nsError.code))"
        }
        return "\(nsError.domain) (\(nsError.code)): \(description)"
    }
}
