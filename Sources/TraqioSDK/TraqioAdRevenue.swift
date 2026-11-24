import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// Which ad SDKs `Traqio.start` listens to (HQ cmwfo9pd). Neither becomes a
/// dependency: both are found at run time, by class name.
///
/// - `admob`: every banner, interstitial, rewarded, rewarded interstitial, app open
///   and native ad of Google Mobile Ads (9.10 → 13.x), with no code per ad. Traqio
///   installs a paid event handler on each ad as it loads, and keeps the app's own
///   handler running when it sets one. `Traqio.watchAdMob(ad)` is the per-ad
///   alternative for an app that leaves this off.
/// - `applovinMax`: every MAX impression of every format, through AppLovin's own
///   "Impression-Level User Revenue API for MMPs" (`max_revenue_events`).
///
/// Turn one on and call nothing by hand for that SDK: once it is captured,
/// `trackAdRevenue` / `trackMaxAdRevenue` for it are ignored (one warning in the
/// log), so an impression can never be counted twice. `Traqio.watchAdMob(ad)`
/// stays harmless: an ad already reporting is never wrapped a second time.
public struct TraqioAdRevenueOptions {
  public var admob: Bool
  public var applovinMax: Bool

  public init(admob: Bool = false, applovinMax: Bool = false) {
    self.admob = admob
    self.applovinMax = applovinMax
  }
}

/// The rule against double counting (HQ cmwfq3ij), the same as @traqio/core's
/// `AdRevenueGate`: once `adRevenue` captures a network, a manual call for it is
/// ignored with one warning. Ignoring rather than deduplicating per impression:
/// neither `GADAdValue` nor `MAAd` carries an impression id, and a key made of
/// amount + ad unit + time would merge two real banners paying the same in the
/// same second — a silent undercount. Ignoring is deterministic and says so.
final class TraqioAdRevenueGate {
  static let admob = "admob"
  static let applovinMax = "applovinMax"

  private let lock = NSLock()
  private var captured = Set<String>()
  private var warned = Set<String>()
  private let warn: (String) -> Void

  init(warn: @escaping (String) -> Void = { NSLog("%@", $0) }) {
    self.warn = warn
  }

  /// The capture of `network` is live: its manual calls are refused from now on.
  func arm(_ network: String) {
    lock.lock()
    captured.insert(network)
    lock.unlock()
  }

  func captures(_ network: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return captured.contains(network)
  }

  /// A public manual tracker: allowed only for a network nothing captures.
  func allowsManual(_ network: String, call: String) -> Bool {
    lock.lock()
    let isCaptured = captured.contains(network)
    let firstWarning = isCaptured && warned.insert(network).inserted
    lock.unlock()
    if firstWarning {
      warn("[traqio] adRevenue.\(network) is on: manual \(call)() ignored — Traqio already captures this network, remove the call.")
    }
    return !isCaptured
  }
}

/// The pure half: mapping and batching rules, the same as @traqio/core's.
enum TraqioAdRevenueRules {
  static let sourceAdMob = "admob"
  static let sourceMax = "applovin_max"
  /// How an impression reached the queue — read by the server's dedup net.
  static let originAuto = "auto"
  static let originManual = "manual"
  static let maxAdBatch = 100
  static let maxAdQueue = 1000
  static let maxRevenueTopic = "max_revenue_events"

  private static let precisions = ["unknown", "estimated", "publisher_provided", "precise"]

  /// `GADAdValuePrecision` (Unknown = 0 … Precise = 3) → the server's name.
  static func precision(_ raw: Int) -> String {
    precisions.indices.contains(raw) ? precisions[raw] : "unknown"
  }

  private static let maxPrecisions = ["exact": "precise", "publisher_defined": "publisher_provided", "estimated": "estimated"]

  private static let maxFormats = [
    "BANNER": "banner", "LEADER": "banner", "LEADERBOARD": "banner", "MREC": "banner",
    "INTER": "interstitial", "INTERSTITIAL": "interstitial", "REWARDED": "rewarded",
    "REWARDED_INTER": "rewarded_interstitial", "NATIVE": "native", "APPOPEN": "app_open", "APP_OPEN": "app_open",
  ]

  static func maxFormat(_ label: String?) -> String? {
    label.flatMap { maxFormats[$0.uppercased()] }
  }

  /// An `NSDecimalNumber` amount in currency units → micros, exactly.
  static func micros(_ value: NSDecimalNumber) -> Int64? {
    if value == NSDecimalNumber.notANumber { return nil }
    let micros = value.multiplying(byPowerOf10: 6).int64Value
    return micros >= 0 ? micros : nil
  }

  /// One MAX impression → the queued shape. MAX reports USD; -1 means "no value"
  /// and is skipped rather than recorded as zero. Rounded to the micro, never earlier.
  static func fromMax(
    revenue: Double, precision: String?, adUnitId: String?, format: String?, networkName: String?
  ) -> [String: Any]? {
    guard revenue.isFinite, revenue >= 0 else { return nil }
    var item: [String: Any] = [
      "valueMicros": Int64((revenue * 1_000_000).rounded()),
      "currency": "USD",
      "precision": maxPrecisions[precision ?? ""] ?? "unknown",
    ]
    if let adUnitId = adUnitId, !adUnitId.isEmpty { item["adUnitId"] = adUnitId }
    if let format = maxFormat(format) { item["adFormat"] = format }
    if let networkName = networkName, !networkName.isEmpty { item["adSourceName"] = networkName }
    return item
  }

  /// A `max_revenue_events` message's data: `revenue`, `max_ad_unit_id`,
  /// `ad_format`, `network_name`. No precision in it — filed as `unknown`.
  static func fromMaxMessage(_ data: [String: Any]) -> [String: Any]? {
    let revenue: Double?
    switch data["revenue"] {
    case let n as NSNumber: revenue = n.doubleValue
    case let s as String: revenue = Double(s)
    default: revenue = nil
    }
    guard let revenue = revenue else { return nil }
    return fromMax(
      revenue: revenue, precision: nil, adUnitId: data["max_ad_unit_id"] as? String,
      format: data["ad_format"] as? String, networkName: data["network_name"] as? String
    )
  }

  static func isBillable(valueMicros: Int64, currency: String?) -> Bool {
    valueMicros >= 0 && !(currency ?? "").isEmpty
  }

  /// The run of the head's source, capped: the server files a batch under ONE source.
  static func nextBatchSize(sources: [String], max: Int = maxAdBatch) -> Int {
    guard let head = sources.first else { return 0 }
    var n = 0
    while n < sources.count, n < max, sources[n] == head { n += 1 }
    return n
  }
}

#if canImport(ObjectiveC)

extension Traqio {
  /// AdMob in one line, for an app that leaves `adRevenue.admob` off — call it on
  /// each ad once it is loaded (any format: `BannerView`, `InterstitialAd`,
  /// `RewardedAd`, `RewardedInterstitialAd`, `AppOpenAd`, `NativeAd`):
  ///
  ///   InterstitialAd.load(with: unitId, request: Request()) { ad, _ in Traqio.watchAdMob(ad) }
  ///
  /// Keeps any paid event handler the ad already has. Typed `NSObject` so this SDK
  /// never imports Google Mobile Ads.
  public static func watchAdMob(_ ad: NSObject?) {
    guard let ad = ad else { return }
    TraqioAdMobHooks.attach(to: ad)
  }
}

/// `Traqio.start(adRevenue:)` → the hooks. Installed once, whatever the options of
/// a second `start`.
enum TraqioAdRevenueCapture {
  private static let lock = NSLock()
  private static var admobInstalled = false
  private static var maxInstalled = false

  static func install(_ options: TraqioAdRevenueOptions) {
    lock.lock()
    defer { lock.unlock() }
    // The gate is armed only for a capture that is really live: with Google
    // Mobile Ads or AppLovin absent (or renamed), the manual calls stay counted.
    if options.admob && !admobInstalled {
      admobInstalled = true
      if TraqioAdMobHooks.install() { Traqio.adGate.arm(TraqioAdRevenueGate.admob) }
    }
    if options.applovinMax && !maxInstalled {
      maxInstalled = true
      if TraqioMaxSubscriber.subscribe() { Traqio.adGate.arm(TraqioAdRevenueGate.applovinMax) }
    }
  }
}

/// Google Mobile Ads, captured at the source. There is no app-wide paid event in
/// the SDK (no notification, no global delegate), so Traqio hooks the few public
/// Objective-C entry points every ad goes through:
///
/// 1. `+loadWithAdUnitID:request:completionHandler:` of the four full-screen
///    formats (and Ad Manager's interstitial): the ad gets a reporting handler
///    before the app's completion sees it.
/// 2. `-[GADBannerView loadRequest:]` and `-[GADNativeAdView setNativeAd:]`: the
///    banner / native ad gets one if it has none.
/// 3. `-setPaidEventHandler:` on every format: a handler the app sets later is
///    WRAPPED, not replaced — Traqio reports, then the app's handler runs.
///
/// Every lookup is by name and checked: a class or selector a future SDK renames
/// is skipped (no revenue through this path, never a crash), and the per-ad
/// `Traqio.watchAdMob(ad)` remains. Google Mobile Ads 13.12 deprecated
/// `paidEventHandler` for delegate callbacks; the property still exists and still
/// fires, and an app that moved to the delegate keeps receiving its callbacks —
/// the handler Traqio installs runs beside them.
enum TraqioAdMobHooks {
  typealias PaidHandler = @convention(block) (AnyObject) -> Void
  typealias LoadCompletion = @convention(block) (AnyObject?, AnyObject?) -> Void
  private typealias SetterIMP = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
  private typealias LoadIMP = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
  private typealias OneArgIMP = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

  /// Runtime class name → the server's format. Ad Manager subclasses inherit.
  static let formats: [(className: String, format: String)] = [
    ("GADBannerView", "banner"),
    ("GADRewardedInterstitialAd", "rewarded_interstitial"),
    ("GADRewardedAd", "rewarded"),
    ("GADInterstitialAd", "interstitial"),
    ("GADAppOpenAd", "app_open"),
    ("GADNativeAd", "native"),
  ]

  private static let setter = NSSelectorFromString("setPaidEventHandler:")
  private static let getterKey = "paidEventHandler"
  private static var oursKey: UInt8 = 0
  private static var hookedSetters = Set<UnsafeRawPointer>()

  /// True when at least one paid event handler setter was hooked: from then on
  /// every ad of that format reports by itself.
  @discardableResult
  static func install() -> Bool {
    var live = false
    for (className, _) in formats {
      guard let cls = NSClassFromString(className) else { continue }
      if hookSetter(cls) { live = true }
    }
    for (className, selector) in [
      ("GADInterstitialAd", "loadWithAdUnitID:request:completionHandler:"),
      ("GADRewardedAd", "loadWithAdUnitID:request:completionHandler:"),
      ("GADRewardedInterstitialAd", "loadWithAdUnitID:request:completionHandler:"),
      ("GADAppOpenAd", "loadWithAdUnitID:request:completionHandler:"),
      ("GAMInterstitialAd", "loadWithAdManagerAdUnitID:request:completionHandler:"),
    ] {
      if let cls = NSClassFromString(className) { hookLoad(cls, NSSelectorFromString(selector)) }
    }
    if let banner = NSClassFromString("GADBannerView") {
      hookBefore(banner, NSSelectorFromString("loadRequest:")) { view, _ in attachIfNone(view) }
    }
    if let nativeView = NSClassFromString("GADNativeAdView") {
      hookBefore(nativeView, NSSelectorFromString("setNativeAd:")) { _, nativeAd in
        if let nativeAd = nativeAd as? NSObject { attachIfNone(nativeAd) }
      }
    }
    return live
  }

  /// `Traqio.watchAdMob`: wraps whatever handler the ad has now.
  static func attach(to ad: NSObject) {
    guard ad.responds(to: setter) else { return }
    let current = ad.value(forKey: getterKey) as AnyObject?
    // Through the (possibly hooked) setter: a hooked one sees our own handler
    // and passes it through unwrapped.
    ad.perform(setter, with: wrap(current, ad: ad))
  }

  private static func attachIfNone(_ ad: NSObject) {
    guard ad.responds(to: setter), ad.value(forKey: getterKey) == nil else { return }
    ad.perform(setter, with: wrap(nil, ad: ad))
  }

  /// The handler Traqio installs: report, then run the app's (if any). Marked, so
  /// it is never wrapped twice when an app reads the property and sets it back.
  static func wrap(_ handler: AnyObject?, ad: NSObject) -> AnyObject {
    if let handler = handler, objc_getAssociatedObject(handler, &oursKey) != nil { return handler }
    let appHandler = handler.map { unsafeBitCast($0, to: PaidHandler.self) }
    let format = format(of: ad)
    let ours: PaidHandler = { [weak ad] value in
      if let ad = ad { report(value, ad: ad, format: format) }
      appHandler?(value)
    }
    let block = unsafeBitCast(ours, to: AnyObject.self)
    objc_setAssociatedObject(block, &oursKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return block
  }

  static func format(of ad: NSObject) -> String? {
    formats.first { NSClassFromString($0.className).map(ad.isKind(of:)) ?? false }?.format
  }

  /// `GADAdValue` (`value` NSDecimalNumber in units, `precision`, `currencyCode`).
  static func report(_ value: AnyObject, ad: NSObject, format: String?) {
    guard let value = value as? NSObject,
          let amount = read(value, "value") as? NSDecimalNumber,
          let micros = TraqioAdRevenueRules.micros(amount),
          let currency = read(value, "currencyCode") as? String else { return }
    let precision = (read(value, "precision") as? NSNumber)?.intValue ?? 0
    let source = read(read(read(ad, "responseInfo"), "loadedAdNetworkResponseInfo"), "adSourceName") as? String
    var item: [String: Any] = [
      "valueMicros": micros, "currency": currency, "precision": TraqioAdRevenueRules.precision(precision),
    ]
    if let unit = read(ad, "adUnitID") as? String, !unit.isEmpty { item["adUnitId"] = unit }
    if let format = format { item["adFormat"] = format }
    if let source = source, !source.isEmpty { item["adSourceName"] = source }
    // Not through the public `trackAdRevenue`: that one is the manual path the
    // capture closes (HQ cmwfq3ij).
    Traqio.queueAdRevenue(item, source: TraqioAdRevenueRules.sourceAdMob, origin: TraqioAdRevenueRules.originAuto)
  }

  /// KVC that never raises: only keys the object answers to.
  static func read(_ object: Any?, _ key: String) -> Any? {
    guard let object = object as? NSObject, object.responds(to: NSSelectorFromString(key)) else { return nil }
    return object.value(forKey: key)
  }

  /// True when the setter of `cls` is (now or already) hooked.
  private static func hookSetter(_ cls: AnyClass) -> Bool {
    guard let method = class_getInstanceMethod(cls, setter) else { return false }
    // Formats may share one implementation through a common superclass: hook it once.
    let key = UnsafeRawPointer(method)
    guard hookedSetters.insert(key).inserted else { return true }
    let original = unsafeBitCast(method_getImplementation(method), to: SetterIMP.self)
    let sel = setter
    let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { ad, handler in
      guard let ad = ad as? NSObject else { return original(ad, sel, handler) }
      // A nil from the app means "no handler of mine": Traqio keeps reporting.
      original(ad, sel, wrap(handler, ad: ad))
    }
    method_setImplementation(method, imp_implementationWithBlock(unsafeBitCast(replacement, to: AnyObject.self)))
    return true
  }

  private static func hookLoad(_ cls: AnyClass, _ selector: Selector) {
    guard let method = class_getClassMethod(cls, selector) else { return }
    let original = unsafeBitCast(method_getImplementation(method), to: LoadIMP.self)
    let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { me, unit, request, completion in
      let appCompletion = completion.map { unsafeBitCast($0, to: LoadCompletion.self) }
      let ours: LoadCompletion = { ad, error in
        if let ad = ad as? NSObject { attachIfNone(ad) }
        appCompletion?(ad, error)
      }
      original(me, selector, unit, request, unsafeBitCast(ours, to: AnyObject.self))
    }
    method_setImplementation(method, imp_implementationWithBlock(unsafeBitCast(replacement, to: AnyObject.self)))
  }

  /// Runs `before` with the receiver and the argument, then the original method.
  private static func hookBefore(_ cls: AnyClass, _ selector: Selector, _ before: @escaping (NSObject, AnyObject?) -> Void) {
    guard let method = class_getInstanceMethod(cls, selector) else { return }
    let original = unsafeBitCast(method_getImplementation(method), to: OneArgIMP.self)
    let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { me, arg in
      if let me = me as? NSObject { before(me, arg) }
      original(me, selector, arg)
    }
    method_setImplementation(method, imp_implementationWithBlock(unsafeBitCast(replacement, to: AnyObject.self)))
  }
}

/// AppLovin's "Impression-Level User Revenue API for MMPs": an in-process
/// pub/sub (`ALCCommunicator`) on which MAX publishes every impression's revenue
/// under `max_revenue_events`. Subscribed at launch, by name — no import.
/// support.applovin.com/en/max/ios/overview/impression-level-user-revenue-api-for-mmps
final class TraqioMaxSubscriber: NSObject {
  private static var shared: TraqioMaxSubscriber?

  @objc var communicatorIdentifier: String { "traqio" }

  @objc func didReceiveMessage(_ message: NSObject) {
    if let topic = TraqioAdMobHooks.read(message, "topic") as? String, topic != TraqioAdRevenueRules.maxRevenueTopic { return }
    guard let data = TraqioAdMobHooks.read(message, "data") as? [String: Any],
          let item = TraqioAdRevenueRules.fromMaxMessage(data) else { return }
    Traqio.queueAdRevenue(item, source: TraqioAdRevenueRules.sourceMax, origin: TraqioAdRevenueRules.originAuto)
  }

  /// True once subscribed: every MAX impression then reaches Traqio by itself.
  @discardableResult
  static func subscribe() -> Bool {
    if shared != nil { return true }
    guard let cls = NSClassFromString("ALCCommunicator") as? NSObject.Type else { return false }
    let defaultSel = NSSelectorFromString("defaultCommunicator")
    let subscribeSel = NSSelectorFromString("subscribe:forTopic:")
    guard cls.responds(to: defaultSel),
          let communicator = cls.perform(defaultSel)?.takeUnretainedValue() as? NSObject,
          communicator.responds(to: subscribeSel) else { return false }
    // The subscriber is typed `id<ALCSubscriber>`: declare the conformance at run time.
    if let proto = objc_getProtocol("ALCSubscriber") { class_addProtocol(TraqioMaxSubscriber.self, proto) }
    let subscriber = TraqioMaxSubscriber()
    shared = subscriber // AppLovin may hold it weakly
    communicator.perform(subscribeSel, with: subscriber, with: TraqioAdRevenueRules.maxRevenueTopic)
    return true
  }
}

#else

/// Off Darwin (swift-corelibs) there is no Objective-C runtime and no ad SDK.
enum TraqioAdRevenueCapture {
  static func install(_ options: TraqioAdRevenueOptions) {}
}

#endif
