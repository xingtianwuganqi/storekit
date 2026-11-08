// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReusableStoreKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ReusableStoreKit", targets: ["ReusableStoreKit"])],
    targets: [
        .target(name: "ReusableStoreKit"),
        .testTarget(name: "ReusableStoreKitTests", dependencies: ["ReusableStoreKit"])
    ]
)
