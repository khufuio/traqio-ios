import Foundation
import StoreKit

/// SKAN 4 coarse conversion value. Apple substitutes it for the fine value in low
/// postback data tiers and in the 2nd/3rd conversion windows, so an app that only
/// sets the fine value is invisible for most of its installs.
public enum TraqioCoarseValue: String {
  case low, medium, high
}

/// When one of Apple's three conversion windows is closed early. Mirrors
/// `PostbackWindow` in apps/api/src/skan/conversion-value.ts.
///
/// This used to be a parameter the HOST APP passed to `updateConversionValue`, so
/// changing when a campaign reports meant shipping an app release. It is
/// configuration now: the mapping carries it, the device obeys it.
struct TraqioPostbackWindow {
  /// 0 = day 0-2 (0→48 h, the only window with a FINE value), 1 = day 3-7
  /// (48→168 h), 2 = day 8-35 (168→840 h).
  let window: Int
  let lock: Bool
  /// Hours since install at which to lock. nil = lock on the next value update.
  let lockAfterHours: Double?

  /// Apple's window bounds, in hours since install.
  static let bounds: [(window: Int, startHours: Double, endHours: Double)] = [
    (0, 0, 48), (1, 48, 168), (2, 168, 840),
  ]

  static func forAge(_ hoursSinceInstall: Double) -> Int? {
    bounds.first { hoursSinceInstall >= $0.startHours && hoursSinceInstall < $0.endHours }?.window
  }

  /// Mirrors `shouldLockWindow` in the API and in packages/sdk/src/skan.ts. Locking
  /// closes the window immediately: the postback arrives sooner, at the cost of every
  /// conversion the rest of the window would have seen.
  static func shouldLock(_ windows: [TraqioPostbackWindow], hoursSinceInstall: Double) -> Bool {
    guard let current = forAge(hoursSinceInstall),
          let rule = windows.first(where: { $0.window == current }), rule.lock else { return false }
    guard let after = rule.lockAfterHours else { return true }
    return hoursSinceInstall >= after
  }
}

/// The conversion-value mapping published for this app, as returned by
/// `GET /skan/mapping/<sdkKey>`.
struct TraqioSkanMapping {
  enum Mode: String { case revenue, events }

  let mode: Mode
  /// revenue mode: ascending lower bounds, index = fine conversion value.
  let revenueBuckets: [Double]
  /// events mode: bit index → event name (max 6).
  let eventBits: [String]
  /// Optional SKAN 4 coarse tiers, as revenue thresholds.
  let coarseRevenue: [TraqioCoarseValue: Double]
  /// The postback schedule. Empty = Apple's own timing, nothing given up.
  let postbackWindows: [TraqioPostbackWindow]

  init?(json: Any?) {
    guard let dict = json as? [String: Any] else { return nil }
    mode = Mode(rawValue: dict["mode"] as? String ?? "revenue") ?? .revenue
    revenueBuckets = (dict["revenueBuckets"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    eventBits = (dict["eventBits"] as? [Any])?.compactMap { $0 as? String } ?? []
    var tiers: [TraqioCoarseValue: Double] = [:]
    for (key, value) in (dict["coarseRevenue"] as? [String: Any]) ?? [:] {
      if let tier = TraqioCoarseValue(rawValue: key), let n = (value as? NSNumber)?.doubleValue {
        tiers[tier] = n
      }
    }
    coarseRevenue = tiers
    // A malformed entry is DROPPED rather than defaulted to "lock": reading junk as a
    // lock would silently throw away most of the customer's measurement.
    postbackWindows = ((dict["postbackWindows"] as? [Any]) ?? []).compactMap { entry in
      guard let e = entry as? [String: Any],
            let window = (e["window"] as? NSNumber)?.intValue,
            (0...2).contains(window) else { return nil }
      return TraqioPostbackWindow(
        window: window,
        lock: (e["lock"] as? NSNumber)?.boolValue ?? false,
        lockAfterHours: (e["lockAfterHours"] as? NSNumber)?.doubleValue
      )
    }
  }
}

/// iOS SKAdNetwork conversion values.
///
/// What SKAN can and cannot do, so nobody builds on a wrong assumption: it gives
/// Apple SIX BITS about this install, delivered to the ad network (and to Traqio's
/// postback endpoint) at least 24h after the conversion window closes, and
/// withheld entirely when the campaign is too small for Apple's crowd-anonymity
/// threshold. It is aggregated, coarse and late by construction — never
/// device-level. No IDFA, no pasteboard, no fingerprinting.
///
/// The mapping is fetched from the API rather than hardcoded: the server decodes
/// postbacks with the mapping it published, so a hardcoded copy in the app drifts
/// silently and you only find out 24h later when the values come back meaning the
/// wrong thing.
public enum TraqioSkan {
  private static let lastFineKey = "traq_skan_fine"
  private static let revenueKey = "traq_skan_revenue"
  private static let eventsKey = "traq_skan_events"
  /// Unix seconds of the first launch we saw. The window schedule is expressed in
  /// hours SINCE INSTALL and nothing on the device tells us the install time, so this
  /// is our stand-in — written once, never moved. It is later than the true install by
  /// however long the user took to open the app, which makes a lock fire slightly LATE
  /// rather than early: the safe direction, since an early lock throws measurement
  /// away and a late one only delays the postback.
  private static let firstSeenKey = "traq_skan_first_seen"
  private static let maxFineValue = 63

  private static let q = DispatchQueue(label: "io.khufu.traqio.skan")
  private static var mapping: TraqioSkanMapping?

  /// Register the install and load the app's mapping. Called by `Traqio.start`.
  /// Without the registration Apple has no conversion to attribute and the ad
  /// network never receives a postback.
  static func start(sdkKey: String, endpoint: String) {
    q.async {
      if UserDefaults.standard.object(forKey: firstSeenKey) == nil {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: firstSeenKey)
      }
    }
    registerForAttribution()
    fetchMapping(sdkKey: sdkKey, endpoint: endpoint) { loaded in
      q.async {
        mapping = loaded
        // A mapping published (or changed) after the install still applies from
        // here on: re-encode the total we already have so the first conversion
        // window isn't wasted.
        if loaded != nil { push() }
      }
    }
  }

  public static func registerForAttribution() {
    if #available(iOS 16.1, *) {
      SKAdNetwork.updatePostbackConversionValue(0, coarseValue: .low, lockWindow: false) { _ in }
    } else if #available(iOS 15.4, *) {
      SKAdNetwork.updatePostbackConversionValue(0) { _ in }
    } else {
      SKAdNetwork.registerAppForAdNetworkAttribution()
    }
  }

  /// Add revenue this install produced. SKAN encodes a LIFETIME total, not one
  /// purchase, so amounts accumulate — passing a single sale twice double-counts
  /// it. Persisted, so an app restart mid-window doesn't reset it down a bucket.
  public static func addRevenue(_ amount: Double) {
    guard amount.isFinite, amount > 0 else { return }
    q.async {
      let total = UserDefaults.standard.double(forKey: revenueKey) + amount
      UserDefaults.standard.set(total, forKey: revenueKey)
      push()
    }
  }

  /// Mark a milestone reached (events mode). Repeats are idempotent.
  public static func markEvent(_ name: String) {
    q.async {
      var reached = UserDefaults.standard.stringArray(forKey: eventsKey) ?? []
      guard !reached.contains(name) else { return }
      reached.append(name)
      UserDefaults.standard.set(reached, forKey: eventsKey)
      push()
    }
  }

  /// Set the conversion value directly, for apps that own their own schema
  /// instead of using the mapping published in the dashboard. Most apps should
  /// NOT call this alongside `Traqio.track` — two things fighting over six bits.
  ///
  /// `lockWindow: true` closes the current conversion window immediately: the
  /// postback arrives sooner, at the cost of ignoring the rest of the window.
  public static func updateConversionValue(
    _ fineValue: Int,
    coarse: TraqioCoarseValue? = nil,
    lockWindow: Bool = false
  ) {
    q.async { send(fineValue, coarse: coarse ?? coarseFor(fineValue: fineValue), lockWindow: lockWindow) }
  }

  // ── internals (all on q) ───────────────────────────────
  private static func push() {
    guard let mapping = mapping else { return } // no mapping → nothing to encode
    let defaults = UserDefaults.standard

    let fine: Int
    var coarse: TraqioCoarseValue?
    switch mapping.mode {
    case .events:
      guard !mapping.eventBits.isEmpty else { return }
      let reached = Set(defaults.stringArray(forKey: eventsKey) ?? [])
      fine = fineValue(forEvents: reached, bits: mapping.eventBits)
    case .revenue:
      guard !mapping.revenueBuckets.isEmpty else { return }
      let total = defaults.double(forKey: revenueKey)
      fine = fineValue(forRevenue: total, buckets: mapping.revenueBuckets)
      coarse = coarseFor(revenue: total, tiers: mapping.coarseRevenue)
    }

    // Value 0 is already on the device from `registerForAttribution`. Re-sending
    // it would burn the first, most valuable conversion window on "nothing yet".
    if defaults.object(forKey: lastFineKey) == nil, fine == 0 { return }
    send(fine, coarse: coarse ?? coarseFor(fineValue: fine), lockWindow: lockWindowNow(mapping))
  }

  /// Whether this update closes the current conversion window, per the schedule the
  /// mapping published. No schedule, or no rule for the window we are in → false,
  /// which is Apple's own timing and gives nothing up.
  private static func lockWindowNow(_ mapping: TraqioSkanMapping) -> Bool {
    guard !mapping.postbackWindows.isEmpty else { return false }
    let firstSeen = UserDefaults.standard.double(forKey: firstSeenKey)
    guard firstSeen > 0 else { return false }
    let hours = (Date().timeIntervalSince1970 - firstSeen) / 3600
    return TraqioPostbackWindow.shouldLock(mapping.postbackWindows, hoursSinceInstall: hours)
  }

  private static func send(_ fineValue: Int, coarse: TraqioCoarseValue, lockWindow: Bool) {
    guard fineValue >= 0, fineValue <= maxFineValue else { return } // Apple ignores out-of-range anyway
    // Only ever send an increasing fine value. On SKAN 3 and earlier the rolling
    // 24h measurement timer restarts only for a value GREATER than the previous
    // one, so a lower value both fails to extend the window and can regress what
    // the postback ends up reporting.
    let defaults = UserDefaults.standard
    if defaults.object(forKey: lastFineKey) != nil, fineValue <= defaults.integer(forKey: lastFineKey) { return }
    defaults.set(fineValue, forKey: lastFineKey)

    if #available(iOS 16.1, *) {
      SKAdNetwork.updatePostbackConversionValue(fineValue, coarseValue: coarse.skCoarse, lockWindow: lockWindow) { _ in }
    } else if #available(iOS 15.4, *) {
      SKAdNetwork.updatePostbackConversionValue(fineValue) { _ in }
    } else {
      SKAdNetwork.updateConversionValue(fineValue)
    }
  }

  /// Highest bucket whose lower bound the revenue has reached. Mirrors
  /// `fineValueForRevenue` in apps/api/src/skan/conversion-value.ts — the encode
  /// and decode sides of one mapping must never disagree.
  static func fineValue(forRevenue revenue: Double, buckets: [Double]) -> Int {
    var value = 0
    for (index, lowerBound) in buckets.prefix(maxFineValue + 1).enumerated() where revenue >= lowerBound {
      value = index
    }
    return value
  }

  /// Milestone names → the 6-bit mask, in the bit order the mapping declares.
  static func fineValue(forEvents events: Set<String>, bits: [String]) -> Int {
    var value = 0
    for (index, name) in bits.prefix(6).enumerated() where events.contains(name) {
      value |= 1 << index
    }
    return value
  }

  /// Highest configured coarse tier the revenue has reached.
  private static func coarseFor(revenue: Double, tiers: [TraqioCoarseValue: Double]) -> TraqioCoarseValue? {
    tiers.filter { revenue >= $0.value }.max(by: { $0.value < $1.value })?.key
  }

  /// Fallback when the app published no coarse tiers: split the fine range in
  /// thirds. Crude, but a rough coarse value still beats none, which is what most
  /// low-tier postbacks would otherwise carry.
  private static func coarseFor(fineValue: Int) -> TraqioCoarseValue {
    let third = maxFineValue / 3
    return fineValue <= third ? .low : (fineValue <= 2 * third ? .medium : .high)
  }

  private static func fetchMapping(
    sdkKey: String,
    endpoint: String,
    done: @escaping (TraqioSkanMapping?) -> Void
  ) {
    let escaped = sdkKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sdkKey
    guard let url = URL(string: "\(endpoint)/skan/mapping/\(escaped)") else { done(nil); return }
    URLSession.shared.dataTask(with: url) { data, _, _ in
      // Offline at launch is normal, and so is an app with no mapping published:
      // we simply never set a value, and the install is still registered.
      done(data.flatMap { TraqioSkanMapping(json: try? JSONSerialization.jsonObject(with: $0)) })
    }.resume()
  }
}

@available(iOS 16.1, *)
extension TraqioCoarseValue {
  fileprivate var skCoarse: SKAdNetwork.CoarseConversionValue {
    switch self {
    case .low: return .low
    case .medium: return .medium
    case .high: return .high
    }
  }
}
