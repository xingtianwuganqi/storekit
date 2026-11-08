# ReusableStoreKit

可通过 Swift Package Manager 复用的 StoreKit 2 内购模块，最低 iOS 15（支持 macOS 12 以便本机测试），无第三方依赖。

支持消耗型单次购买、非消耗型永久购买、自动续期订阅。非自动续期订阅需要 App 自行定义有效期，本模块暂不支持。

## 接入

Xcode → Add Package Dependencies → Add Local，选择 `storekit-iOS`，添加 `ReusableStoreKit` 产品。跨仓库使用时可复制此目录，或将该目录独立发布为 Swift Package 仓库（当前仓库根目录不是 Package）。在 App Store Connect 配置商品，启用 In-App Purchase capability。

```swift
import ReusableStoreKit
import SwiftUI

@MainActor
final class AppPurchases {
    // 在整个 App 生命周期中保留同一个实例。
    let store = PurchaseManager(productIDs: [
        "com.example.app.lifetime", "com.example.app.monthly", "com.example.app.coins"
    ]) { transaction in
        // 推荐：上传 JWS 给自己的服务端，验签、验证 bundle / 商品 / 用户归属，
        // 以 transaction.id 为唯一键原子地落订单并发货。
        // 只有服务端确认到账（包括已处理的重复请求）才正常返回；失败必须 throw。
        try await YourAPI.deliver(
            transactionID: String(transaction.id),
            signedTransaction: transaction.jwsRepresentation,
            accountToken: transaction.appAccountToken
        )
    }
}

// App 启动：
// await purchases.store.start()
// try await purchases.store.loadProducts()
// 购买（token 必须是服务端为当前用户分配的稳定 UUID）：
// let result = try await purchases.store.purchase(productID, appAccountToken: userToken)
// 回到前台或网络恢复：
// await purchases.store.retryPendingPurchases()
// await purchases.store.refreshEntitlements()
// 用户点击恢复购买：
// try await purchases.store.restorePurchases()
```

`YourAPI` 是接入方实现的示意接口。无服务端的永久购买/订阅 App，可传入 `{ _ in }`，通过 `entitlements` 解锁本地功能。消耗品必须在 delivery 中持久化到账记录，不能只修改内存或非原子地增加余额。

SwiftUI 用 `@StateObject` / `@ObservedObject` 观察 `PurchaseManager`。使用 `products` 中的 `displayPrice` 展示本地化价格。`PurchaseOutcome` 分为已发货、等待补单、等待批准、用户取消；等待批准不是付款成功。`pendingDeliveryIDs` 用于展示已验证但尚未到账的订单。`lastError` 为最近一次诊断错误，成功操作不会自动清除历史错误。

## 补单语义

1. `start()` 先注册 `Transaction.updates` 监听，再扫描 `Transaction.unfinished`。
2. 所有已验证的购买、续费、批准交易进入同一发货入口，同一交易的并发处理合并。
3. delivery 成功后才 `finish()`；失败不结束交易，默认 2/5/10/30/60/300 秒退避，之后每 300 秒继续重试。仅 App 运行期间执行；系统挂起时不会后台保活。
4. 未完成交易由 StoreKit 保存，App 重启、崩溃后重新扫描。当前进程成功记录用于去重，跨进程以业务服务端/本地账本的交易 ID 唯一约束保证幂等。
5. “服务端到账后、finish 前”崩溃会再次调用 delivery，因此回调必须幂等。这是至少一次投递，不承诺跨网络恰好一次。
6. 仅处理配置中的商品；不验证通过的交易不发货、不 finish。扫描时跳过未验证项目，使其他订单仍能恢复；权益查询遇到验证失败则保留上次快照并暴露错误。

`start()` 可重复调用，不会创建多份监听。应在购买之前调用并始终保留实例；delivery 应设置网络超时，避免请求永久挂起。补单使用交易自身的 `appAccountToken` 核对用户，不能把旧用户的待处理订单发给当前登录用户。失败/切换账户时抛错保留订单，账户切换后由业务端重新查询余额和权益。

## 权益与订阅

`entitlements` 是 Apple `currentEntitlements` 的已验证快照，包含永久购买及有效自动续期订阅，不包含消耗品余额。以 Apple 当前权益集合为准，保留账单宽限期权益；过滤退款/撤销与已升级交易。关闭自动续费不会立即失去本期权益。空快照会清除已有权限；查询验证失败保留上次快照，`hasResolvedEntitlements` 表示至少成功查询过一次。

启动、购买、恢复和交易更新会刷新权益；运行期间每 60 秒刷新，前台切换应主动刷新，所以时间边界存在刷新延迟。不要将 UserDefaults 布尔值作为购买凭证。服务器订阅业务还应接入 App Store Server Notifications V2 处理退款、续费与撤销，本模块不代替服务端的订阅账本。已结束交易的退款事件由权益刷新处理，不通过 delivery 再次发货；远程权益撤销应由服务端通知处理。

## 验证

```sh
swift test --package-path storekit-iOS
```

单测覆盖发货失败不结束交易、重试成功、重启恢复、并发去重、权益查询失败与退款、待批准与取消、商品隔离。上线前还需要 Xcode StoreKit Testing / Sandbox 验证真实购买、续费、宽限期、退款、Ask to Buy、断网与杀进程补单；单测不代表 Apple 端到端验证完成。

## 参考

结构参考 MotionText 的 StoreKit 客户端抽象、交易监听和权益刷新，以及 PureRide 的购买服务和延迟结束交易。提取为无业务商品 ID、无试用/埋点/界面依赖的库，并新增统一发货、并发合并、未完成交易扫描及退避重试。

Apple 文档：[unfinished](https://developer.apple.com/documentation/storekit/transaction/unfinished)、[currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)。
