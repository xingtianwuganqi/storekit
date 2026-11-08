import XCTest
import StoreKit
@testable import ReusableStoreKit

@MainActor
final class PurchaseManagerTests: XCTestCase {
    func testFailedDeliveryStaysUnfinishedThenRetries() async throws {
        let client = StubClient()
        var finished = 0
        var deliveries = 0
        let t = transaction(finish: { await MainActor.run { finished += 1 } })
        client.orders = [t]
        let manager = PurchaseManager(productIDs: ["pro"], client: client) { _ in
            deliveries += 1
            if deliveries == 1 { throw Failure.offline }
        }
        await manager.retryPendingPurchases()
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(manager.pendingDeliveryIDs, [1])
        await manager.retryPendingPurchases()
        XCTAssertEqual(finished, 1)
        XCTAssertTrue(manager.pendingDeliveryIDs.isEmpty)
        await manager.retryPendingPurchases()
        XCTAssertEqual(deliveries, 2)
    }

    func testNewManagerRecoversUnfinishedOrder() async {
        let client = StubClient()
        client.orders = [transaction()]
        let first = PurchaseManager(productIDs: ["pro"], client: client) { _ in throw Failure.offline }
        await first.retryPendingPurchases()
        var delivered = false
        let restarted = PurchaseManager(productIDs: ["pro"], client: client) { _ in delivered = true }
        await restarted.retryPendingPurchases()
        XCTAssertTrue(delivered)
    }

    func testConcurrentDeliveryIsCoalesced() async throws {
        let client = StubClient()
        client.orders = [transaction()]
        var count = 0
        let manager = PurchaseManager(productIDs: ["pro"], client: client) { _ in
            count += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        async let purchase = manager.purchase("pro")
        async let recovery: Void = manager.retryPendingPurchases()
        _ = try await (purchase, recovery)
        XCTAssertEqual(count, 1)
    }

    func testEntitlementsClearOnRefundAndPreserveOnVerificationError() async {
        let client = StubClient()
        client.rights = [transaction()]
        let manager = PurchaseManager(productIDs: ["pro"], client: client) { _ in }
        await manager.refreshEntitlements()
        XCTAssertNotNil(manager.entitlements["pro"])
        client.failEntitlements = true
        await manager.refreshEntitlements()
        XCTAssertNotNil(manager.entitlements["pro"])
        XCTAssertNotNil(manager.lastError)
        client.failEntitlements = false
        client.rights = []
        await manager.refreshEntitlements()
        XCTAssertTrue(manager.entitlements.isEmpty)
    }

    func testPendingAndCancelledNeverDeliver() async throws {
        let client = StubClient()
        var count = 0
        let manager = PurchaseManager(productIDs: ["pro"], client: client) { _ in count += 1 }
        client.outcome = .pending
        let pending = try await manager.purchase("pro")
        XCTAssertEqual(pending, .pending)
        client.outcome = .cancelled
        let cancelled = try await manager.purchase("pro")
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(count, 0)
    }

    func testUnconfiguredOrdersAreNotFinishedOrDelivered() async {
        let client = StubClient()
        client.orders = [transaction()]
        var count = 0
        let manager = PurchaseManager(productIDs: ["other"], client: client) { _ in count += 1 }
        await manager.retryPendingPurchases()
        XCTAssertEqual(count, 0)
    }

    func testAutomaticRetryWithoutManualAction() async throws {
        let client = StubClient()
        client.orders = [transaction()]
        var attempts = 0
        let manager = PurchaseManager(productIDs: ["pro"], client: client, retryDelays: [0.01]) { _ in
            attempts += 1
            if attempts == 1 { throw Failure.offline }
        }
        await manager.start()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(manager.pendingDeliveryIDs.isEmpty)
    }

    func testSubscriptionRenewalsUseTransactionIDNotOriginalID() async {
        let client = StubClient()
        client.orders = [1, 2].map { id in
            PurchaseTransaction(id: UInt64(id), originalID: 1, productID: "pro",
                productType: .autoRenewable, purchaseDate: Date(),
                expirationDate: Date().addingTimeInterval(3600), jwsRepresentation: "test", finish: {})
        }
        client.rights = [client.orders[1]]
        var delivered: [UInt64] = []
        let manager = PurchaseManager(productIDs: ["pro"], client: client) { delivered.append($0.id) }
        await manager.retryPendingPurchases()
        await manager.refreshEntitlements()
        XCTAssertEqual(delivered, [1, 2])
        XCTAssertEqual(manager.entitlements["pro"]?.id, 2)
    }

    private func transaction(finish: @escaping @Sendable () async -> Void = {}) -> PurchaseTransaction {
        PurchaseTransaction(id: 1, originalID: 1, productID: "pro", productType: .nonConsumable,
                            purchaseDate: Date(), jwsRepresentation: "test", finish: finish)
    }
}
private enum Failure: Error { case offline }
@MainActor
private final class StubClient: StoreClient {
    var orders: [PurchaseTransaction] = []
    var rights: [PurchaseTransaction] = []
    var outcome: StorePurchaseResult?
    var failEntitlements = false
    func products(for ids: Set<String>) async throws -> [Product] { [] }
    func purchase(productID: String, appAccountToken: UUID?) async throws -> StorePurchaseResult {
        outcome ?? .verified(orders[0])
    }
    func unfinished() async throws -> [PurchaseTransaction] { orders }
    func entitlements() async throws -> [PurchaseTransaction] {
        if failEntitlements { throw Failure.offline }
        return rights
    }
    func updates() -> AsyncStream<Result<PurchaseTransaction, Error>> { AsyncStream { $0.finish() } }
    func sync() async throws {}
}
