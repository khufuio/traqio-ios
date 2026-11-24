import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Apple Ads (Search Ads) attribution — the device half.
///
/// What this buys: the ONE deterministic attribution iOS still allows. Everything
/// else on iOS is SKAdNetwork — aggregated, six bits, 24h+ late. Apple Search Ads
/// self-attributes through the AdServices framework, and any developer may resolve
/// their own app's tokens with no partner programme and no allowlist.
///
/// What it is NOT: an identifier. `AAAttribution.attributionToken()` returns an
/// opaque, single-purpose claim ticket that is valid for **24 hours** and says
/// nothing about the user. No IDFA, no ATT prompt of our own, no fingerprinting.
/// Apple decides how much of the answer to give back based on the ATT status the
/// user already chose for this app — detailed with consent, standard without — and
/// both halves are useful.
///
/// Flow: token → our server → Apple's attribution endpoint. The server resolves it
/// because Apple answers 404 until the token is known on its side, and that retry
/// has to outlive the app process.
///
/// https://developer.apple.com/documentation/adservices
public enum TraqioAdServices {
  /// Set once we have handed a token over. The token is single-use for us: a second
  /// post of the same string is deduped server-side anyway, but asking the framework
  /// again on every launch is work with no answer to it.
  private static let sentKey = "traq_adservices_sent"
  /// How many launches we keep trying before giving up on this install.
  private static let maxAttempts = 5
  private static let attemptsKey = "traq_adservices_attempts"

  private static let q = DispatchQueue(label: "io.khufu.traqio.adservices")

  /// Ask AdServices for a token and post it. Called by `Traqio.start`.
  ///
  /// Silent on every failure by design: there is no user-visible consequence, and an
  /// app that logs an error on a device with no Search Ads install (which is most of
  /// them) is noise. `attributionToken()` throws on a device where the framework has
  /// nothing to give — a simulator, a device with no attribution record at all.
  static func start(sdkKey: String, endpoint: String, deviceId: String, userId: String?, debug: Bool) {
    q.async {
      let defaults = UserDefaults.standard
      if defaults.bool(forKey: sentKey) { return }

      guard let token = attributionToken() else {
        // No token on this device/launch. Bounded retry: the framework can answer
        // later in an install's life, but a device where it never will must not ask
        // forever.
        let attempts = defaults.integer(forKey: attemptsKey) + 1
        defaults.set(attempts, forKey: attemptsKey)
        if attempts >= maxAttempts { defaults.set(true, forKey: sentKey) }
        return
      }

      var body: [String: Any] = ["sdkKey": sdkKey, "token": token, "deviceId": deviceId]
      if let userId = userId { body["appUserId"] = userId }
      if debug { body["debug"] = true }
      post(endpoint: endpoint, body: body) { ok in
        // Only mark sent on success, so a failed post retries on the next launch —
        // inside the 24h window, which is what makes the retry worth anything.
        if ok { q.async { defaults.set(true, forKey: sentKey) } }
      }
    }
  }

  /// The raw token, for a host app that wants to resolve it itself. Nil when the
  /// framework has nothing (pre-iOS 14.3, simulator, no attribution record).
  public static func attributionToken() -> String? {
    #if canImport(AdServices)
    if #available(iOS 14.3, *) {
      // Throws `AAAttribution.AttributionError` — including `.networkError` on a
      // device that cannot reach Apple right now, which is retryable, and
      // `.platformNotSupported`, which is not. We do not branch on it: the caller's
      // bounded retry covers the first and wastes four launches on the second, which
      // is cheaper than a second state machine.
      return try? AAAttribution.attributionToken()
    }
    #endif
    return nil
  }

  private static func post(endpoint: String, body: [String: Any], done: @escaping (Bool) -> Void) {
    guard let url = URL(string: "\(endpoint)/ingest/adservices"),
          let data = try? JSONSerialization.data(withJSONObject: body) else { done(false); return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    URLSession.shared.dataTask(with: req) { _, response, _ in
      done((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
    }.resume()
  }
}
