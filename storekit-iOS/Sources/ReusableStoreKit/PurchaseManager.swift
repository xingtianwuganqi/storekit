import Combine
import Foundation
import StoreKit

/// Keep one instance alive for the app's lifetime; call start() during launch.
@MainActor
public final class PurchaseManager: ObservableObject {
    public typealias Delivery = @MainActor (PurchaseTransaction) async throws -> Void
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var entitlements: [String: PurchaseTransaction] = [:]
    @Published public private(set) var pendingDeliveryIDs: Set<UInt64> = []
    @Published public private(set) var isPurchasing = false
    @Published public private(set) var lastError: Error?
    @Published public private(set) var hasResolvedEntitlements = false

    private let productIDs: Set<String>
    private let client: any StoreClient
    private let delivery: Delivery
    private let retryDelays: [TimeInterval]
    private var listener: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var inFlight: [UInt64: Task<Bool, Never>] = [:]
    private var acknowledged: Set<UInt64> = []
    private var attempts: [UInt64: Int] = [:]
    private var nextAttempt: [UInt64: Date] = [:]
    private var refreshing: Task<Void, Never>?

    public init(productIDs: Set<String>, client: (any StoreClient)? = nil,
                retryDelays: [TimeInterval] = [2, 5, 10, 30, 60, 300],
                delivery: @escaping Delivery) {
        precondition(!productIDs.isEmpty)
        precondition(!retryDelays.isEmpty && retryDelays.allSatisfy { $0.isFinite && $0 > 0 })
        self.productIDs = productIDs
        self.client = client ?? SystemStoreClient()
        self.retryDelays = retryDelays
        self.delivery = delivery
    }

    deinit { listener?.cancel(); maintenance?.cancel() }

    public func start() async {
        if listener == nil {
            let stream = client.updates()
            listener = Task { [weak self] in
                for await result in stream {
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .success(let transaction):
                        _ = await self?.process(transaction)
                        await self?.refreshEntitlements()
                    case .failure(let error): self?.lastError = error
                    }
                }
            }
            maintenance = Task { [weak self] in
                var ticks = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    catch { return }
                    await self?.recover(force: false)
                    ticks += 1
                    if ticks >= 60 {
                        await self?.refreshEntitlements()
                        ticks = 0
                    }
                }
            }
        }
        await retryPendingPurchases()
        await refreshEntitlements()
    }

    public func loadProducts() async throws {
        products = try await client.products(for: productIDs)
            .filter { supports($0.type) }
            .sorted { $0.price < $1.price }
    }

    public func purchase(_ productID: String, appAccountToken: UUID? = nil) async throws -> PurchaseOutcome {
        guard productIDs.contains(productID) else { throw PurchaseError.unknownProduct }
        guard !isPurchasing else { throw PurchaseError.busy }
        isPurchasing = true
        defer { isPurchasing = false }
        switch try await client.purchase(productID: productID, appAccountToken: appAccountToken) {
        case .pending: return .pending
        case .cancelled: return .cancelled
        case .verified(let transaction):
            guard transaction.productID == productID, supports(transaction.productType) else {
                throw PurchaseError.unknownProduct
            }
            let delivered = await process(transaction)
            await refreshEntitlements()
            return delivered ? .delivered(transaction.id) : .awaitingDelivery(transaction.id)
        }
    }

    /// Call on foreground entry / network recovery as well as via a manual retry button.
    public func retryPendingPurchases() async { await recover(force: true) }

    /// User-initiated only: AppStore.sync() may show an authentication prompt.
    public func restorePurchases() async throws {
        try await client.sync()
        await retryPendingPurchases()
        await refreshEntitlements()
    }

    public func refreshEntitlements() async {
        if let refreshing { await refreshing.value; return }
        let task = Task { [self] in
            do {
                let transactions = try await client.entitlements()
                var snapshot: [String: PurchaseTransaction] = [:]
                for t in transactions where productIDs.contains(t.productID)
                    && t.productType != .consumable && supports(t.productType)
                    && t.revocationDate == nil && !t.isUpgraded {
                    // currentEntitlements also includes billing grace period access.
                    if let previous = snapshot[t.productID], previous.purchaseDate > t.purchaseDate { continue }
                    snapshot[t.productID] = t
                }
                entitlements = snapshot
                hasResolvedEntitlements = true
            } catch { lastError = error }
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func supports(_ type: Product.ProductType) -> Bool {
        type == .consumable || type == .nonConsumable || type == .autoRenewable
    }

    private var recovering = false
    private func recover(force: Bool) async {
        guard !recovering else { return }
        recovering = true
        defer { recovering = false }
        do {
            for transaction in try await client.unfinished() {
                guard force || nextAttempt[transaction.id, default: .distantPast] <= Date() else { continue }
                _ = await process(transaction)
            }
        } catch { lastError = error }
    }

    private func process(_ transaction: PurchaseTransaction) async -> Bool {
        guard productIDs.contains(transaction.productID), supports(transaction.productType) else { return false }
        if let task = inFlight[transaction.id] { return await task.value }
        // Revocations are reflected by refreshing Apple's entitlements, never by granting again.
        if acknowledged.contains(transaction.id) || transaction.revocationDate != nil || transaction.isUpgraded {
            await transaction.finish()
            return true
        }
        let task = Task { [self] in
            do {
                try await delivery(transaction)
                acknowledged.insert(transaction.id)
                await transaction.finish()
                pendingDeliveryIDs.remove(transaction.id)
                attempts.removeValue(forKey: transaction.id)
                nextAttempt.removeValue(forKey: transaction.id)
                return true
            } catch {
                lastError = error
                pendingDeliveryIDs.insert(transaction.id)
                let attempt = attempts[transaction.id, default: 0]
                nextAttempt[transaction.id] = Date().addingTimeInterval(retryDelays[min(attempt, retryDelays.count - 1)])
                attempts[transaction.id] = min(attempt + 1, retryDelays.count - 1)
                // Do not finish: Apple's unfinished queue survives process termination.
                return false
            }
        }
        inFlight[transaction.id] = task
        let success = await task.value
        inFlight.removeValue(forKey: transaction.id)
        return success
    }
}
