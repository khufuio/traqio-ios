import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a link wants the app to land (docs/DEEP_LINKING.md).
///
/// Two moments, one callback:
///   - DIRECT: a universal link (`https://<your host>/c/<code>`) opened the
///     installed app. iOS never hit our server, so the SDK resolves the code —
///     which also records the click the OS skipped.
///   - DEFERRED: the app was installed FROM a link. On the first launch of a fresh
///     install the SDK asks once where that link wanted the user to land. iOS has
///     no Install Referrer: the server answers only when the app opted into the IP
///     match in the console (probabilistic, off by default, routing only).
public struct TraqioDeepLink: Codable, Equatable {
  /// How the link was resolved. `ipMatch` is a probabilistic guess — see the docs.
  public enum Via: String, Codable {
    case referrer
    case ipMatch = "ip_match"
    case link
  }

  /// The destination set on the link in the console — an in-app path
  /// ("/product/42") or an app URL ("myapp://product/42"). Nil when the link
  /// carries none: the app still learns WHICH link brought the user (`code`).
  public let deepLink: String?
  /// The link's slug (the `<code>` of `/c/<code>`).
  public let code: String?
  /// True when the link was tapped BEFORE the install; false when it opened the app.
  public let deferred: Bool
  public let via: Via
  /// The URL that opened the app (direct opens only).
  public let url: String?
}

/// Returned by `Traqio.onDeepLink`. Keep it for as long as you want links;
/// `cancel()` unsubscribes.
public final class TraqioDeepLinkSubscription {
  private let id: UUID
  init(id: UUID) { self.id = id }
  public func cancel() { TraqioDeepLinks.unsubscribe(id) }
}

/// The deep-link state machine behind `Traqio`. Same contract as @traqio/core
/// (packages/sdk-core/src/index.ts): the two POSTs and the same `/c/<code>` rule.
enum TraqioDeepLinks {
  /// The deferred answer, once the server has given one ("null" = "no link").
  /// Persisted so it is asked exactly once per install.
  static let linkKey = "traq_deferred_link"
  /// Set before the deferred request, so an install that was fresh when the
  /// request failed still asks on the next launch (its install flag is set by then).
  static let pendingKey = "traq_deferred_link_pending"

  private static let q = DispatchQueue(label: "io.khufu.traqio.deeplinks")
  private static var sdkKey = ""
  private static var endpoint = ""
  private static var enabled = false
  private static var debug = false
  private static var listeners: [(id: UUID, fn: (TraqioDeepLink) -> Void)] = []
  // Links resolved before anyone subscribed — a cold start resolves the opening
  // URL before the app has mounted the screen that registers `onDeepLink`.
  private static var undelivered: [TraqioDeepLink] = []
  private static var deferredDone = false
  private static var deferredLink: TraqioDeepLink?
  private static var deferredWaiters: [(TraqioDeepLink?) -> Void] = []

  // Mirrors `parseTrackingUrl` in apps/api/src/tracking/link-rules.ts. Checked on
  // the device so the app's OWN URLs (most of what opens an app) never leave it.
  private static let urlPattern = try! NSRegularExpression(pattern: "^https?://[^/?#]+(/[^?#]*)?", options: [.caseInsensitive])
  private static let pathPattern = try! NSRegularExpression(pattern: "^/c/[A-Za-z0-9_-]{1,50}/?$")

  static func isTrackingUrl(_ url: String) -> Bool {
    let range = NSRange(url.startIndex..., in: url)
    guard let m = urlPattern.firstMatch(in: url, range: range) else { return false }
    let pathRange = m.range(at: 1)
    let path = pathRange.location == NSNotFound ? "" : (url as NSString).substring(with: pathRange)
    return pathPattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
  }

  /// Called by `Traqio.start` when deep linking is on. `freshInstall` is read
  /// BEFORE the install is marked sent: an existing user updating to this SDK
  /// version must not be routed by somebody else's click from the same address.
  static func start(sdkKey: String, endpoint: String, freshInstall: Bool, debug: Bool) {
    q.async {
      self.sdkKey = sdkKey
      self.endpoint = endpoint
      self.debug = debug
      enabled = true
      resolveDeferredOnce(freshInstall: freshInstall)
    }
  }

  static func open(_ url: String, done: @escaping (TraqioDeepLink?) -> Void) {
    q.async {
      guard enabled, isTrackingUrl(url) else { done(nil); return }
      postJson(["sdkKey": sdkKey, "url": url], path: "/deeplink/open") { answer in
        q.async {
          let link = toDeepLink(answer, deferred: false, url: url)
          if let link = link { emit(link) }
          done(link)
        }
      }
    }
  }

  static func deferred(done: @escaping (TraqioDeepLink?) -> Void) {
    q.async {
      if !enabled || deferredDone { done(deferredLink); return }
      deferredWaiters.append(done)
    }
  }

  static func subscribe(_ fn: @escaping (TraqioDeepLink) -> Void) -> TraqioDeepLinkSubscription {
    let id = UUID()
    q.async {
      listeners.append((id, fn))
      let pending = undelivered
      undelivered.removeAll()
      if !pending.isEmpty { DispatchQueue.main.async { pending.forEach(fn) } }
    }
    return TraqioDeepLinkSubscription(id: id)
  }

  static func unsubscribe(_ id: UUID) {
    q.async { listeners.removeAll { $0.id == id } }
  }

  // ── internals (all on q) ───────────────────────────────
  private static func resolveDeferredOnce(freshInstall: Bool) {
    let defaults = UserDefaults.standard
    if let cached = defaults.string(forKey: linkKey) {
      if cached == "null" { finishDeferred(nil); return }
      if let data = cached.data(using: .utf8), let link = try? JSONDecoder().decode(TraqioDeepLink.self, from: data) {
        finishDeferred(link)
        return
      }
      // corrupt — ask again if still a fresh install
    }
    if !freshInstall && defaults.string(forKey: pendingKey) == nil { finishDeferred(nil); return }

    defaults.set("1", forKey: pendingKey)
    postJson(["sdkKey": sdkKey, "platform": "ios"], path: "/deeplink/deferred") { answer in
      q.async {
        // Unreachable — the pending flag makes the next launch retry.
        guard let answer = answer else { finishDeferred(nil); return }
        let link = toDeepLink(answer, deferred: true, url: nil)
        let stored = link.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        UserDefaults.standard.set(stored ?? "null", forKey: linkKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        if let link = link { emit(link) }
        finishDeferred(link)
      }
    }
  }

  private static func finishDeferred(_ link: TraqioDeepLink?) {
    deferredDone = true
    deferredLink = link
    let waiters = deferredWaiters
    deferredWaiters.removeAll()
    waiters.forEach { $0(link) }
  }

  private static func emit(_ link: TraqioDeepLink) {
    if listeners.isEmpty {
      undelivered.append(link)
      return
    }
    let fns = listeners.map { $0.fn }
    DispatchQueue.main.async { fns.forEach { $0(link) } }
  }

  private struct Answer: Decodable {
    let matched: Bool
    let via: String?
    let code: String?
    let deepLink: String?
  }

  /// An API answer → the callback's shape, or nil when nothing matched.
  private static func toDeepLink(_ answer: Answer?, deferred: Bool, url: String?) -> TraqioDeepLink? {
    guard let answer = answer, answer.matched, let via = answer.via.flatMap(TraqioDeepLink.Via.init(rawValue:)) else {
      return nil
    }
    return TraqioDeepLink(deepLink: answer.deepLink, code: answer.code, deferred: deferred, via: via, url: url)
  }

  /// The two calls whose ANSWER matters. Nil on any failure.
  private static func postJson(_ body: [String: Any], path: String, done: @escaping (Answer?) -> Void) {
    var body = body
    if debug { body["debug"] = true }
    guard let url = URL(string: "\(endpoint)\(path)"),
          let data = try? JSONSerialization.data(withJSONObject: body) else { done(nil); return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    URLSession.shared.dataTask(with: req) { data, response, _ in
      guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status), let data = data else {
        done(nil)
        return
      }
      done(try? JSONDecoder().decode(Answer.self, from: data))
    }.resume()
  }
}
