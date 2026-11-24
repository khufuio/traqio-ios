// swift-tools-version:5.7
import PackageDescription

// Product name is `TraqioSDK`, not `Traqio`: the Flutter plugin already publishes a
// pod called `traqio`, and CocoaPods trunk treats those as the same name. The suffix
// is also the Apple-side convention for a vendor SDK (AdjustSdk, BranchSDK).
let package = Package(
  name: "TraqioSDK",
  platforms: [.iOS(.v14)],
  products: [
    .library(name: "TraqioSDK", targets: ["TraqioSDK"]),
  ],
  targets: [
    .target(name: "TraqioSDK", path: "Sources/TraqioSDK"),
    // `swift test`: the pure ad revenue rules on any platform; the Google Mobile
    // Ads hooks (Objective-C runtime) on Apple platforms only.
    .testTarget(name: "TraqioSDKTests", dependencies: ["TraqioSDK"], path: "Tests/TraqioSDKTests"),
  ]
)
