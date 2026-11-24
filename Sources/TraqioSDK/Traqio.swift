import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Traqio native iOS SDK. Install attribution is SKAN (aggregated, post-ATT) plus
/// Apple Ads through AdServices (deterministic, and the only iOS source that is) —
/// no Install Referrer, no pasteboard, no fingerprinting, and no IDFA BY DEFAULT: it
/// is sent only if the app opts in (`collectAdvertisingId`) and already holds ATT. Persisted offline
/// queue + batching + exponential-backoff retries. `deviceId` is a first-party UUID.
///
///   Traqio.start(sdkKey: "SDK_KEY", endpoint: "https://api.traqio.app", userId: id)
///   Traqio.track("purchase", value: 9.99, currency: "USD")
///   Traqio.onDeepLink { link in if let path = link.deepLink { router.open(path) } }
///
/// Deep links (docs/DEEP_LINKING.md) send nothing new: the URL that opened the app,
/// and on a fresh install one question — the iOS deferred IP match is the SERVER's,
/// opt-in per app, and it routes a first open, it never attributes an install.
public enum Traqio {
  private static let installSentKey = "traq_install_sent"
  private static let queueKey = "traq_queue"
  private static let deviceIdKey = "traq_device_id"
  private static let lastSessionKey = "traq_last_session"
  private static let consentKey = "traq_consent"
  /// The IDFA the server last acknowledged (todo cmwlauev), per mode like the install flag.
  private static let adIdSentKey = "traq_ad_id_sent"
  private static let adIdPath = "/ingest/advertising-id"
  // Ad impressions: their own queue, the batch id persisted beside it so a retry
  // after a crash reuses it and the server dedups instead of double-counting.
  private static let adQueueKey = "traq_ad_queue"
  private static let sdkVersion = "0.1.0"
  private static let maxBatch = 20
  private static let maxQueue = 500
  private static let baseRetry: TimeInterval = 1
  private static let maxRetry: TimeInterval = 5 * 60
  private static let flushDelay: TimeInterval = 3

  /// How long the app must have been away before coming back counts as a NEW
  /// session. 30 minutes is the near-universal convention (GA4, Adjust, AppsFlyer),
  /// and the point of it is that a user switching to Maps and back has not started
  /// a new session. It is also the debounce: without it every resume would post.
  private static let sessionTimeout: TimeInterval = 30 * 60

  private static let q = DispatchQueue(label: "io.khufu.traqio")
  private static var sdkKey = ""
  private static var endpoint = ""
  private static var userId: String?
  private static var started = false
  private static var flushScheduled = false
  private static var flushing = false
  private static var retry: TimeInterval = 1
  private static var context: [String: Any] = [:]
  private static var deepLinking = true
  private static var collectAdvertisingId = false
  private static var debug = false
  private static var testAds = false
  /// Once `adRevenue` captures a network, its manual calls are ignored (HQ cmwfq3ij).
  static let adGate = TraqioAdRevenueGate()

  /// Whether this install's traffic is flagged as debug — shown in the console's
  /// Debug view, never counted, attributed, forwarded to ad networks or billed.
  /// Resolved by `start`; false before it.
  public static var isDebug: Bool { q.sync { debug } }

  /// `DEBUG` is the configuration this package is compiled with; SwiftPM and
  /// CocoaPods build it with the host app's, so a Debug-scheme run is flagged and an
  /// App Store / TestFlight (Release) build is not. A simulator is never a real user.
  private static func detectDebug() -> Bool {
    #if DEBUG || targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  /// The install flag is kept per mode, so a release build installed over a debug
  /// build (or the reverse) still reports its own install.
  private static var installKey: String { debug ? installSentKey + "_debug" : installSentKey }
  private static var adIdKey: String { debug ? adIdSentKey + "_debug" : adIdSentKey }

  /// - Parameters:
  ///   - deepLinking: default true. On the first launch of a fresh install, asks
  ///     once where the link that brought the user wanted them to land, and hands it
  ///     to `onDeepLink`. Universal links that open the app are passed in by the
  ///     host with `handleUserActivity(_:)` / `handleUrl(_:)`. False turns all of it off.
  ///   - consent: the user's answer to the app's own consent prompt, when it already
  ///     has one — see `setConsent(_:)`. Nil sends nothing.
  ///   - collectAdvertisingId: default FALSE (decision cmvjohk6). True sends the IDFA
  ///     — only once the app obtained App Tracking Transparency (this SDK never
  ///     prompts) and links AdSupport. With the install when ATT was already granted;
  ///     otherwise once, at the first start or return to the foreground after the
  ///     user allowed tracking (todo cmwlauev), so ATT may be asked whenever the
  ///     onboarding wants. It sharpens attribution for the networks that attribute by
  ///     IDFA (Unity Ads, AppLovin) and is sent to Meta as `madid` with the device's
  ///     later conversions; it is never used as the user's identity.
  ///   - debug: nil (default) detects a development build — compiled in the DEBUG
  ///     configuration, or running in a simulator. True / false overrides it. Debug
  ///     traffic is kept out of stats, attribution and billing.
  ///   - testAds: true while the app serves AdMob / MAX TEST ad units — their revenue
  ///     is logged by the API (proof the pipe works) but never counted.
  ///   - adRevenue: capture ad revenue with no code per ad (HQ cmwfo9pd) — see
  ///     `TraqioAdRevenueOptions`. Neither ad SDK becomes a dependency.
  public static func start(
    sdkKey: String, endpoint: String, userId: String? = nil, deepLinking: Bool = true, consent: Bool? = nil,
    collectAdvertisingId: Bool = false, debug: Bool? = nil, testAds: Bool = false,
    adRevenue: TraqioAdRevenueOptions = TraqioAdRevenueOptions()
  ) {
    // On the caller's thread, before any ad can load: the hooks must be in place
    // before the app's first `load`, and AppLovin wants its subscriber at launch.
    TraqioAdRevenueCapture.install(adRevenue)
    q.async {
      if started { return }
      started = true
      self.sdkKey = sdkKey
      self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
      self.userId = userId
      self.deepLinking = deepLinking
      self.collectAdvertisingId = collectAdvertisingId
      self.debug = debug ?? detectDebug()
      self.testAds = testAds
      if let consent = consent { storeConsent(consent) }
      buildContext()
      // Registers the install with SKAdNetwork and loads the app's
      // conversion-value mapping (aggregated + delayed by design — see
      // TraqioSkan for what iOS can and cannot tell us).
      TraqioSkan.start(sdkKey: sdkKey, endpoint: self.endpoint)
      // Apple Ads self-attribution: the one DETERMINISTIC iOS source. The token is
      // valid 24h, so this runs on every cold start until one is handed over — see
      // TraqioAdServices.
      TraqioAdServices.start(
        sdkKey: sdkKey, endpoint: self.endpoint, deviceId: deviceId(), userId: userId, debug: self.debug
      )
      // Read BEFORE the install is marked sent: only a fresh install may ask for a
      // deferred link.
      let freshInstall = !UserDefaults.standard.bool(forKey: installKey)
      sendInstallOnce()
      // An IDFA the install could not carry (ATT granted at an earlier launch, after it).
      syncAdvertisingId()
      if deepLinking {
        TraqioDeepLinks.start(sdkKey: sdkKey, endpoint: self.endpoint, freshInstall: freshInstall, debug: self.debug)
      }
      // Always, not debounced: start() means the app was opened, and the first open
      // of a day is the one the whole retention number rests on.
      startSession(force: true)
      wireLifecycle()
      if !loadQueue().isEmpty || !loadAdItems().isEmpty { scheduleFlush(0) }
    }
  }

  // Flush when the app enters the background; record a session when it comes back.
  private static func wireLifecycle() {
    #if canImport(UIKit)
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
    ) { _ in
      q.async { scheduleFlush(0) }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { _ in
      // Debounced inside by `sessionTimeout`, so a flick to another app and
      // straight back posts nothing. The IDFA check is not debounced: the ATT alert
      // itself resigns the app active, so this fires right after the user answers it.
      q.async {
        startSession()
        syncAdvertisingId()
      }
    }
    #endif
  }

  /// Tell the SDK the app came back to the foreground. UIKit hosts are wired
  /// automatically; anything else (a SwiftUI-only target on another platform, a
  /// custom shell) has to call this or its users look like they never came back.
  public static func appOpened() {
    q.async {
      guard started else { return }
      startSession()
      syncAdvertisingId()
    }
  }

  public static func setUserId(_ id: String) {
    q.async { userId = id }
  }

  /// The user's consent to SHARING their data with ad networks (Meta, TikTok,
  /// outbound postbacks). Not a consent platform: the app's own consent UI calls
  /// this with the answer. Persisted, and sent with every install, event batch and
  /// session from then on (read at send time, so queued events follow the latest
  /// answer). `false` keeps first-party measurement — installs, events, revenue —
  /// but the server forwards nothing to any network. Never called = never sent,
  /// and the app's console setting decides.
  public static func setConsent(_ granted: Bool) {
    q.async { storeConsent(granted) }
  }

  // ── deep links (docs/DEEP_LINKING.md) ──────────────────

  /// Subscribe to deep links — direct opens AND the one deferred link of a fresh
  /// install. Links resolved before the first subscriber are delivered to it on
  /// subscription, so a cold start does not lose the link that opened the app.
  /// Called on the main queue.
  ///
  ///   let sub = Traqio.onDeepLink { link in if let path = link.deepLink { router.open(path) } }
  ///
  /// Keep the returned subscription; `cancel()` unsubscribes.
  @discardableResult
  public static func onDeepLink(_ listener: @escaping (TraqioDeepLink) -> Void) -> TraqioDeepLinkSubscription {
    TraqioDeepLinks.subscribe(listener)
  }

  /// A URL opened the app. Only our tracking URLs (`https://<host>/c/<code>`)
  /// leave the device; the app's own URLs resolve to nil without a request.
  /// Resolving also records the click, which iOS skipped by opening the app.
  /// The link also goes to every `onDeepLink` listener. `completion` runs on the
  /// main queue.
  ///
  /// No swizzling — call it from wherever the app receives URLs:
  ///
  ///   // UIApplicationDelegate
  ///   func application(_ app: UIApplication, continue activity: NSUserActivity,
  ///                    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
  ///     Traqio.handleUserActivity(activity)
  ///   }
  ///   // UISceneDelegate: warm open, then cold start
  ///   func scene(_ scene: UIScene, continue activity: NSUserActivity) { Traqio.handleUserActivity(activity) }
  ///   func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
  ///     options.userActivities.forEach { Traqio.handleUserActivity($0) }
  ///   }
  ///   // SwiftUI
  ///   .onOpenURL { Traqio.handleUrl($0) }
  ///   .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Traqio.handleUserActivity($0) }
  public static func handleUrl(_ url: URL, completion: ((TraqioDeepLink?) -> Void)? = nil) {
    q.async {
      let finish: (TraqioDeepLink?) -> Void = { link in
        if let completion = completion { DispatchQueue.main.async { completion(link) } }
      }
      guard started, deepLinking else { finish(nil); return }
      TraqioDeepLinks.open(url.absoluteString, done: finish)
    }
  }

  // NSUserActivity is Darwin Foundation only (swift-corelibs has none).
  #if canImport(ObjectiveC)
  /// `handleUrl` for a universal link's `NSUserActivity`. Returns whether it was
  /// one of our tracking URLs — i.e. whether Traqio is taking care of it; the app's
  /// own links return false and are the app's to route.
  @discardableResult
  public static func handleUserActivity(_ activity: NSUserActivity) -> Bool {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL,
          isTrackingUrl(url.absoluteString) else { return false }
    handleUrl(url)
    return true
  }
  #endif

  /// True when `url` is one of our tracking links (`http(s)://<host>/c/<code>`).
  public static func isTrackingUrl(_ url: String) -> Bool {
    TraqioDeepLinks.isTrackingUrl(url)
  }

  /// The deferred deep link of this install, if it came from one — resolved once,
  /// on the first launch, and remembered. Nil on every install that did not come
  /// from a link, and unless the IP match is on for this app in the console (iOS
  /// has no Install Referrer). `completion` runs on the main queue.
  public static func getDeferredDeepLink(_ completion: @escaping (TraqioDeepLink?) -> Void) {
    q.async {
      let finish: (TraqioDeepLink?) -> Void = { link in DispatchQueue.main.async { completion(link) } }
      guard started, deepLinking else { finish(nil); return }
      TraqioDeepLinks.deferred(done: finish)
    }
  }

  public static func track(_ name: String, value: Double? = nil, currency: String? = nil) {
    q.async {
      guard started else { return }
      var e: [String: Any] = ["name": name, "eventId": UUID().uuidString]
      if let value = value { e["value"] = value }
      if let currency = currency { e["currency"] = currency }
      var arr = loadQueue()
      arr.append(e)
      if arr.count > maxQueue { arr.removeFirst(arr.count - maxQueue) }
      saveQueue(arr)
      scheduleFlush()

      // Same event, second job: it also moves the SKAN conversion value.
      TraqioSkan.markEvent(name)
      if let value = value { TraqioSkan.addRevenue(value) }
    }
  }

  // ── ad revenue (HQ cmwfo9pd) ───────────────────────────

  /// Report one AdMob impression by hand, from your own paid event handler. With
  /// `adRevenue: .init(admob: true)` — or `Traqio.watchAdMob(ad)` — it is done for you,
  /// and once the option captures AdMob this call is ignored (one warning in the log):
  /// the impression is already counted.
  ///
  ///   ad.paidEventHandler = { value in
  ///     Traqio.trackAdRevenue(valueMicros: value.value.multiplying(byPowerOf10: 6).int64Value,
  ///       currency: value.currencyCode, precision: "estimated", adUnitId: ad.adUnitID, adFormat: "rewarded")
  ///   }
  ///
  /// Batched to `/ingest/ad-revenue`, deduplicated by batch, matched to this install.
  public static func trackAdRevenue(
    valueMicros: Int64, currency: String, precision: String = "unknown", adUnitId: String? = nil,
    adFormat: String? = nil, adSourceName: String? = nil
  ) {
    var item: [String: Any] = ["valueMicros": valueMicros, "currency": currency, "precision": precision]
    if let adUnitId = adUnitId { item["adUnitId"] = adUnitId }
    if let adFormat = adFormat { item["adFormat"] = adFormat }
    if let adSourceName = adSourceName { item["adSourceName"] = adSourceName }
    guard adGate.allowsManual(TraqioAdRevenueGate.admob, call: "trackAdRevenue") else { return }
    queueAdRevenue(item, source: TraqioAdRevenueRules.sourceAdMob, origin: TraqioAdRevenueRules.originManual)
  }

  /// Report one AppLovin MAX impression by hand, from `didPayRevenue(for ad: MAAd)`:
  ///
  ///   Traqio.trackMaxAdRevenue(revenue: ad.revenue, revenuePrecision: ad.revenuePrecision,
  ///     adUnitId: ad.adUnitIdentifier, format: ad.format.label, networkName: ad.networkName)
  ///
  /// Unneeded — and ignored, with one warning — once `adRevenue: .init(applovinMax: true)`
  /// captures MAX.
  public static func trackMaxAdRevenue(
    revenue: Double, revenuePrecision: String? = nil, adUnitId: String? = nil, format: String? = nil,
    networkName: String? = nil
  ) {
    guard let item = TraqioAdRevenueRules.fromMax(
      revenue: revenue, precision: revenuePrecision, adUnitId: adUnitId, format: format, networkName: networkName
    ) else { return }
    guard adGate.allowsManual(TraqioAdRevenueGate.applovinMax, call: "trackMaxAdRevenue") else { return }
    queueAdRevenue(item, source: TraqioAdRevenueRules.sourceMax, origin: TraqioAdRevenueRules.originManual)
  }

  static func queueAdRevenue(_ impression: [String: Any], source: String, origin: String) {
    q.async {
      guard started, let micros = impression["valueMicros"] as? Int64,
            TraqioAdRevenueRules.isBillable(valueMicros: micros, currency: impression["currency"] as? String)
      else { return }
      var item = impression
      item["source"] = source
      item["origin"] = origin
      item["impressionId"] = UUID().uuidString
      if item["ts"] == nil { item["ts"] = Int(Date().timeIntervalSince1970) }
      var items = loadAdItems()
      items.append(item)
      if items.count > TraqioAdRevenueRules.maxAdQueue { items.removeFirst(items.count - TraqioAdRevenueRules.maxAdQueue) }
      saveAdQueue(items: items, batchId: loadAdBatchId())
      // Ad revenue is revenue: it moves the SKAN conversion value like a purchase,
      // in the currency the mapping is written in (SKAN carries none).
      TraqioSkan.addRevenue(Double(micros) / 1_000_000)
      scheduleFlush()
    }
  }

  private static func loadAdState() -> [String: Any] {
    guard let data = UserDefaults.standard.data(forKey: adQueueKey),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return state
  }

  private static func loadAdItems() -> [[String: Any]] { loadAdState()["items"] as? [[String: Any]] ?? [] }

  private static func loadAdBatchId() -> String? { loadAdState()["batchId"] as? String }

  private static func saveAdQueue(items: [[String: Any]], batchId: String?) {
    var state: [String: Any] = ["items": items]
    if let batchId = batchId { state["batchId"] = batchId }
    if let data = try? JSONSerialization.data(withJSONObject: state) {
      UserDefaults.standard.set(data, forKey: adQueueKey)
    }
  }

  /// Sends the head of the ad queue — one source per batch — then the rest.
  /// Called on q with `flushing` already set; clears it when done.
  private static func flushAds() {
    let items = loadAdItems()
    if items.isEmpty { flushing = false; return }
    let sources = items.map { $0["source"] as? String ?? TraqioAdRevenueRules.sourceAdMob }
    let count = TraqioAdRevenueRules.nextBatchSize(sources: sources)
    let impressions: [[String: Any]] = items.prefix(count).map { var i = $0; i["source"] = nil; return i }
    // Minted BEFORE the request and persisted: a crash mid-flight retries under the
    // same id, and the server dedups instead of counting it twice.
    let batchId = loadAdBatchId() ?? {
      let id = UUID().uuidString
      saveAdQueue(items: items, batchId: id)
      return id
    }()
    var body: [String: Any] = [
      "sdkKey": sdkKey, "batchId": batchId, "source": sources[0],
      "environment": testAds ? "TEST" : "PRODUCTION", "deviceId": deviceId(), "impressions": impressions,
    ]
    if let userId = userId { body["appUserId"] = userId }
    post(body, path: "/ingest/ad-revenue", consent: false) { ok in
      q.async {
        guard ok else {
          flushing = false
          retry = min(retry * 2, maxRetry)
          scheduleFlush(retry)
          return
        }
        var current = loadAdItems()
        current.removeFirst(min(count, current.count))
        saveAdQueue(items: current, batchId: nil)
        retry = baseRetry
        flushAds()
      }
    }
  }

  // ── internals (all on q) ───────────────────────────────
  private static func storeConsent(_ granted: Bool) {
    UserDefaults.standard.set(granted ? "granted" : "denied", forKey: consentKey)
  }

  private static func loadQueue() -> [[String: Any]] {
    guard let data = UserDefaults.standard.data(forKey: queueKey),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return arr
  }

  private static func saveQueue(_ arr: [[String: Any]]) {
    if let data = try? JSONSerialization.data(withJSONObject: arr) {
      UserDefaults.standard.set(data, forKey: queueKey)
    }
  }

  private static func buildContext() {
    var info = utsname()
    uname(&info)
    let machine = withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "" }
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var c: [String: Any] = [
      "deviceId": deviceId(),
      "deviceModel": machine,
      "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      "locale": Locale.current.identifier,
      "sdkVersion": sdkVersion,
    ]
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { c["appVersion"] = v }
    context = c
  }

  private static func deviceId() -> String {
    if let id = UserDefaults.standard.string(forKey: deviceIdKey) { return id }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: deviceIdKey)
    return id
  }

  /// Report one app open — the signal that makes "did the user come back on day n"
  /// answerable at all (docs/SESSIONS.md).
  ///
  /// NO QUEUE, deliberately. The marker is written only on success, so a failed post
  /// is retried by the next foreground. The signal is read at DAY granularity, so a
  /// post lost at 09:00 is recovered by any open before midnight — a far smaller
  /// failure than a persisted queue that can replay yesterday's sessions into today.
  private static func startSession(force: Bool = false) {
    let defaults = UserDefaults.standard
    let now = Date().timeIntervalSince1970
    if !force {
      let last = defaults.double(forKey: lastSessionKey)
      if last > 0, now - last < sessionTimeout { return }
    }
    var body: [String: Any] = [
      "sdkKey": sdkKey,
      "deviceId": deviceId(),
      "sessionId": UUID().uuidString,
      "ts": Int(now),
      "context": context,
    ]
    if let userId = userId { body["appUserId"] = userId }
    post(body, path: "/ingest/session") { ok in
      if ok { q.async { defaults.set(now, forKey: lastSessionKey) } }
    }
  }

  private static func sendInstallOnce() {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: installKey) { return }
    var install: [String: Any] = ["platform": "ios", "context": context]
    if let userId = userId { install["appUserId"] = userId }
    let idfa = collectAdvertisingId ? TraqioAdvertisingId.read() : nil
    if let idfa = idfa { install["advertisingId"] = idfa }
    post(["sdkKey": sdkKey, "install": install]) { ok in
      guard ok else { return }
      q.async {
        defaults.set(true, forKey: installKey)
        if let idfa = idfa { defaults.set(idfa, forKey: adIdKey) }
      }
    }
  }

  private static var syncingAdId = false

  /// The IDFA the install could not carry (todo cmwlauev): the install leaves at
  /// first launch, before the app shows its own ATT prompt. Re-read at every start
  /// and foreground — reading never prompts (decision cmvjohk6) — and posted ONCE
  /// when it differs from the one the server last acknowledged. Only after the
  /// install is reported; a failed post is retried at the next foreground.
  private static func syncAdvertisingId() {
    if syncingAdId { return }
    let defaults = UserDefaults.standard
    guard let idfa = TraqioAdvertisingIdSync.toPost(
      collect: collectAdvertisingId,
      installSent: defaults.bool(forKey: installKey),
      current: collectAdvertisingId ? TraqioAdvertisingId.read() : nil,
      acknowledged: defaults.string(forKey: adIdKey)
    ) else { return }
    syncingAdId = true
    var body: [String: Any] = ["sdkKey": sdkKey, "deviceId": deviceId(), "advertisingId": idfa]
    if let userId = userId { body["appUserId"] = userId }
    post(body, path: adIdPath) { ok in
      q.async {
        syncingAdId = false
        if ok { defaults.set(idfa, forKey: adIdKey) }
      }
    }
  }

  private static func scheduleFlush(_ delay: TimeInterval = flushDelay) {
    if flushScheduled { return }
    flushScheduled = true
    q.asyncAfter(deadline: .now() + delay) { flush() }
  }

  private static func flush() {
    flushScheduled = false
    if flushing { return }
    let arr = loadQueue()
    if arr.isEmpty {
      // Events first, then ad impressions: the ad queue never holds an event back.
      if !loadAdItems().isEmpty { flushing = true; flushAds() }
      return
    }
    flushing = true
    let batch = Array(arr.prefix(maxBatch))
    // Identity travels with every batch, not just the install: it is how the API
    // attaches these events (and their revenue) to this device's install, and Meta/
    // TikTok reject forwarded events that carry no user id. First-party only.
    var body: [String: Any] = ["sdkKey": sdkKey, "events": batch, "deviceId": deviceId()]
    if let userId = userId { body["appUserId"] = userId }
    post(body) { ok in
      q.async {
        flushing = false
        if !ok {
          retry = min(retry * 2, maxRetry)
          scheduleFlush(retry)
          return
        }
        var current = loadQueue()
        current.removeFirst(min(batch.count, current.count))
        saveQueue(current)
        retry = baseRetry
        if !current.isEmpty || !loadAdItems().isEmpty { scheduleFlush(0) }
      }
    }
  }

  private static func post(
    _ body: [String: Any], path: String = "/ingest", consent withConsent: Bool = true, done: @escaping (Bool) -> Void
  ) {
    var body = body
    // Read at SEND time, not enqueue time: a batch queued before the user said no
    // leaves with the no. (Not on ad revenue: the API does not read it there.)
    if withConsent, let consent = UserDefaults.standard.string(forKey: consentKey) { body["consent"] = consent }
    // The ATT status the APP obtained, read at send time and never requested (decision
    // cmvjohk6): Meta hears `advertiser_tracking_enabled: true` only for `authorized`
    // (todo cmwl6oko), and the server keeps an IDFA only under it (todo cmwlauev).
    if path == "/ingest" || path == adIdPath, let att = TraqioAdvertisingId.trackingAuthorization() { body["att"] = att }
    // Omitted in production, so a release body stays the same as before.
    if debug { body["debug"] = true }
    guard let url = URL(string: "\(endpoint)\(path)"),
          let data = try? JSONSerialization.data(withJSONObject: body) else { done(false); return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    URLSession.shared.dataTask(with: req) { _, response, _ in
      let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
      done(ok)
    }.resume()
  }
}

/// When the IDFA has to be posted after the install (todo cmwlauev) — pure, so it is
/// tested without a device. Nil = nothing to send.
enum TraqioAdvertisingIdSync {
  static func toPost(collect: Bool, installSent: Bool, current: String?, acknowledged: String?) -> String? {
    guard collect, installSent, let current = current, current != acknowledged else { return nil }
    return current
  }
}
