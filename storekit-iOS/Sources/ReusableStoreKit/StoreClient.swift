import Foundation
import StoreKit

public enum PurchaseOutcome: Equatable, Sendable {
    case delivered(UInt64)
    case awaitingDelivery(UInt64)
    case pending
    case cancelled
}

public enum PurchaseError: Error {
    case unknownProduct, busy, verificationFailed, unknownResult
}

/// Only constructed from verified StoreKit results by the system client.
public struct PurchaseTransaction: Sendable {
    public let id: UInt64
    public let originalID: UInt64
    public let productID: String
    public let productType: Product.ProductType
    public let purchaseDate: Date
    public let expirationDate: Date?
    public let revocationDate: Date?
    public let isUpgraded: Bool
    public let appAccountToken: UUID?
    public let jwsRepresentation: String
    private let finishAction: @Sendable () async -> Void

    public init(id: UInt64, originalID: UInt64, productID: String,
                productType: Product.ProductType, purchaseDate: Date,
                expirationDate: Date? = nil, revocationDate: Date? = nil,
                isUpgraded: Bool = false, appAccountToken: UUID? = nil,
                jwsRepresentation: String,
                finish: @escaping @Sendable () async -> Void) {
        self.id = id; self.originalID = originalID; self.productID = productID
        self.productType = productType; self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate; self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded; self.appAccountToken = appAccountToken
        self.jwsRepresentation = jwsRepresentation; self.finishAction = finish
    }

    public func finish() async { await finishAction() }
}

public enum StorePurchaseResult: Sendable {
    case verified(PurchaseTransaction), pending, cancelled
}

@MainActor
public protocol StoreClient: AnyObject {
    func products(for ids: Set<String>) async throws -> [Product]
    func purchase(productID: String, appAccountToken: UUID?) async throws -> StorePurchaseResult
    func unfinished() async throws -> [PurchaseTransaction]
    func entitlements() async throws -> [PurchaseTransaction]
    func updates() -> AsyncStream<Result<PurchaseTransaction, Error>>
    func sync() async throws
}

@MainActor
public final class SystemStoreClient: StoreClient {
    public init() {}
    public func products(for ids: Set<String>) async throws -> [Product] {
        try await Product.products(for: ids)
    }
    public func purchase(productID: String, appAccountToken: UUID?) async throws -> StorePurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            throw PurchaseError.unknownProduct
        }
        var options = Set<Product.PurchaseOption>()
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }
        switch try await product.purchase(options: options) {
        case .success(let result): return .verified(try snapshot(result))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw PurchaseError.unknownResult
        }
    }
    public func unfinished() async throws -> [PurchaseTransaction] {
        var transactions: [PurchaseTransaction] = []
        // Skip an unverified item without preventing recovery of other orders.
        for await result in Transaction.unfinished {
            if case .verified = result { transactions.append(try snapshot(result)) }
        }
        return transactions
    }
    public func entitlements() async throws -> [PurchaseTransaction] {
        var transactions: [PurchaseTransaction] = []
        for await result in Transaction.currentEntitlements {
            transactions.append(try snapshot(result))
        }
        return transactions
    }
    public func updates() -> AsyncStream<Result<PurchaseTransaction, Error>> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    do { continuation.yield(.success(try self.snapshot(result))) }
                    catch { continuation.yield(.failure(error)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func sync() async throws { try await AppStore.sync() }

    private func snapshot(_ result: VerificationResult<Transaction>) throws -> PurchaseTransaction {
        guard case .verified(let t) = result else { throw PurchaseError.verificationFailed }
        return PurchaseTransaction(id: t.id, originalID: t.originalID, productID: t.productID,
            productType: t.productType, purchaseDate: t.purchaseDate,
            expirationDate: t.expirationDate, revocationDate: t.revocationDate,
            isUpgraded: t.isUpgraded, appAccountToken: t.appAccountToken,
            jwsRepresentation: result.jwsRepresentation, finish: { await t.finish() })
    }
}
