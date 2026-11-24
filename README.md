# TraqioSDK — the Traqio iOS SDK

The [Traqio](https://traqio.app) SDK for native iOS apps in Swift. iOS gives apps no
install referrer, so it measures with Apple's own channels: it registers each install
with **SKAdNetwork** and sets its conversion value from the mapping you publish in the
Traqio console, and it reports the **Apple Ads** attribution token (AdServices). It
queues your events offline, records app opens and resolves universal links. No IDFA by
default (opt-in, below), no App Tracking Transparency prompt, no pasteboard.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/khufuio/traqio-ios", from: "0.1.0")
```

or CocoaPods: `pod 'TraqioSDK', '~> 0.1'`.

In `Info.plist`, declare Traqio as the SKAdNetwork postback endpoint:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://api.traqio.app</string>
```

## Initialize

```swift
import TraqioSDK

@main
struct MyApp: App {
    init() {
        Traqio.start(sdkKey: "YOUR_SDK_KEY", endpoint: "https://api.traqio.app")
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { Traqio.handleUrl($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Traqio.handleUserActivity($0) }
        }
    }
}
```

## Track events

```swift
Traqio.setUserId(user.id)   // the same id you give RevenueCat (app_user_id)
Traqio.track("purchase", value: 9.99, currency: "EUR")   // also moves the SKAN conversion value
```

## Advertising id (opt-in)

Off by default — the SDK reads no IDFA unless you turn it on, and **never shows the
App Tracking Transparency prompt**. Turn it on when you buy on a network that
attributes by IDFA (**Unity Ads**, **AppLovin**): their click carries it, and Traqio
matches it — hashed — to the install, then sends Unity its install postback.

```swift
// 1. Your app asks ATT itself, whenever its onboarding does — before or after start.
// 2. Link AdSupport in your target (most ad SDKs already do).
Traqio.start(sdkKey: "SDK_KEY", endpoint: "https://api.traqio.app", collectAdvertisingId: true)
```

The IDFA is sent only if the user granted ATT: with the install when they already had,
otherwise once, at the first start or return to the foreground after they allowed it
(`POST /ingest/advertising-id`). Traqio keeps it on that install and sends it to Meta as
`madid` (with `advertiser_tracking_enabled: true`) and to TikTok with the device's later
conversions; it is dropped if the user withdraws ATT or denies consent. It is never used
as the user's identity — that stays the SDK's first-party device id and your user id.

## Ad revenue (AdMob, AppLovin MAX)

```swift
Traqio.start(sdkKey: "SDK_KEY", endpoint: "https://api.traqio.app",
             adRevenue: TraqioAdRevenueOptions(admob: true, applovinMax: true))
```

- **Google Mobile Ads (9.10 → 13.x)**: **automatic**, every format. Each ad gets Traqio's paid event handler as it loads, and a handler you set yourself keeps running (wrapped, not replaced). This goes through the SDK's public Objective-C entry points, looked up by name: Google Mobile Ads is not a dependency, and a renamed entry point is skipped, never a crash. With the option off, the per-ad alternative is `Traqio.watchAdMob(ad)`.
- **AppLovin MAX**: **automatic**, every format, through AppLovin's "Impression-Level User Revenue API for MMPs" (`max_revenue_events`).
- **Turn the option on, then call nothing by hand for that network.** Once Traqio captures it, the manual calls for it (`trackAdRevenue`, `trackMaxAdRevenue`) are ignored with one warning in the log, so an impression can never be counted twice. `Traqio.watchAdMob(ad)` stays harmless: an ad already reporting is never wrapped twice.
- Manual, with the option off: `Traqio.trackAdRevenue(valueMicros:currency:…)` / `Traqio.trackMaxAdRevenue(revenue:…)`. `testAds: true` while on test ad units.

Details, the manual fallback and the automation level of every platform: https://traqio.app/docs/integrations/admob

## Debug builds

A build compiled in the **Debug** configuration (SwiftPM and CocoaPods build the SDK
with your app's configuration) or running in a **simulator** is flagged as debug
traffic. TestFlight and App Store builds are Release, so they are not. Override the
detection with `debug:`, and read the result with `Traqio.isDebug`:

```swift
Traqio.start(sdkKey: "SDK_KEY", endpoint: "https://api.traqio.app", debug: false)
```

Debug traffic shows in the console's **Debug** view, but it is never counted,
attributed, forwarded to ad networks or billed. The install is remembered per mode,
so a release build installed over a debug one still reports its own install.

## Requirements

- iOS 14+ (Apple Ads attribution needs iOS 14.3+), Swift 5.7.
- StoreKit, UIKit; AdServices weakly linked.

## Documentation

**https://traqio.app/docs/sdks/ios** — universal links, conversion values, the full API.

## License

MIT
