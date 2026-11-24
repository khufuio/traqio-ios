import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// The IDFA — read ONLY when the host app opted in (`collectAdvertisingId: true`,
/// decision cmvjohk6), and only if the app ALREADY obtained App Tracking
/// Transparency. This SDK never shows the ATT prompt.
///
/// Both frameworks are reached through the Objective-C runtime, never linked: an
/// app that does not opt in ships no AdSupport / AppTrackingTransparency symbol
/// because of Traqio, and so has nothing to declare for us. An app that opts in
/// links AdSupport itself (most already do through their ad SDK — AppLovin MAX,
/// Unity Ads); without it the classes are absent and this answers nil.
///
/// Kept identical to packages/sdk/ios/TraqioAdvertisingId.swift (the Expo module).
enum TraqioAdvertisingId {
  private static let zero = "00000000-0000-0000-0000-000000000000"
  /// `ATTrackingAuthorizationStatus.authorized`.
  private static let authorized: UInt = 3

  static func read() -> String? {
    #if canImport(ObjectiveC)
    if #available(iOS 14, macOS 11, tvOS 14, *) {
      // No ATT class = framework not linked by the app = it never asked = no.
      guard trackingStatus() == authorized else { return nil }
    }
    guard let cls = NSClassFromString("ASIdentifierManager") as AnyObject?,
          let manager = cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue(),
          let uuid = manager.perform(NSSelectorFromString("advertisingIdentifier"))?.takeUnretainedValue() as? NSUUID
    else { return nil }
    let id = uuid.uuidString
    return id == zero ? nil : id
    #else
    return nil
    #endif
  }

  /// The ATT status the APP obtained — "not_determined" | "restricted" | "denied" |
  /// "authorized" — or nil when the app does not link AppTrackingTransparency (it
  /// never asked). Read by default and on every launch: it is a status, not an
  /// identifier, and reading it never prompts. The server needs it to tell Meta the
  /// truth (`advertiser_tracking_enabled`), which it otherwise claimed true for every
  /// iPhone (todo cmwl6oko).
  static func trackingAuthorization() -> String? {
    #if canImport(ObjectiveC)
    if #available(iOS 14, macOS 11, tvOS 14, *) {
      switch trackingStatus() {
      case 0: return "not_determined"
      case 1: return "restricted"
      case 2: return "denied"
      case 3: return "authorized"
      default: return nil
      }
    }
    // Before iOS 14 there was no ATT: tracking was governed by "Limit Ad Tracking".
    return nil
    #else
    return nil
    #endif
  }

  #if canImport(ObjectiveC)
  /// `ATTrackingManager.trackingAuthorizationStatus`, a class property returning an
  /// NSUInteger — called through its IMP because `perform` only returns objects.
  private static func trackingStatus() -> UInt? {
    let sel = NSSelectorFromString("trackingAuthorizationStatus")
    guard let cls = NSClassFromString("ATTrackingManager"), (cls as AnyObject).responds(to: sel) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
    let imp = (cls as AnyObject).method(for: sel)
    return unsafeBitCast(imp, to: Getter.self)(cls, sel)
  }
  #endif
}
