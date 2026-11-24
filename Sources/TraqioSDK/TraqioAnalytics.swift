import Foundation

// Product analytics on iOS (HQ cmwux580) — `capture()`, `screen()`, `identify()` and
// super-properties, posted to `POST /ingest/analytics` with the app's key: the same
// contract as `@traqio/core` (packages/sdk-core/src/analytics.ts). The engine
// (queue, flush, retry, persistence) is `Traqio`'s; this file is the pure part —
// what an event is, what a session is — so every rule is tested without a device,
// a timer or a network.
//
// ⚠️ An analytics event is never a conversion: `track()` stays the conversion door
// (`/ingest`, metered, forwarded to ad networks); these go to their own route.

/// The server's caps and the shared rules (apps/api/src/product-analytics/screen.ts, identify.ts).
enum TraqioAnalyticsRules {
  static let path = "/ingest/analytics"
  /// 30 minutes without activity end a session — the web SDK's and PostHog's rule.
  static let sessionIdleMs: Int64 = 30 * 60 * 1000
  static let maxEventName = 128
  static let maxScreenName = 512
  static let maxPropsBytes = 4096
  static let maxTraits = 50
  static let maxTraitText = 200
  /// Per request (the server takes 100), and kept offline at most — the oldest go first.
  static let maxBatch = 50
  static let maxQueue = 1000

  private static let traitKey = try! NSRegularExpression(pattern: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")

  /// A custom event name the server will take, or nil: non-empty, ≤ 128, never `$…` (reserved) but the experiment exposure `$exposure`.
  static func cleanEventName(_ name: String) -> String? {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if n.isEmpty || n.utf16.count > maxEventName || (n.hasPrefix("$") && n != "$exposure") { return nil }
    return n
  }

  /// A screen name as stored in the `page` dimension, or nil.
  static func cleanScreenName(_ name: String) -> String? {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? nil : String(n.prefix(maxScreenName))
  }

  /// The serialised length JavaScript would measure (`JSON.stringify(x).length`), or nil when it does not serialise.
  static func jsonLength(_ object: Any) -> Int? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
          let s = String(data: data, encoding: .utf8) else { return nil }
    return s.utf16.count
  }

  /// Properties as they can travel: an object that survives JSON, non-empty, under the
  /// 4 KB cap — else none. Checked at capture time, so a value JSON cannot hold (a
  /// `Date`, NaN) never reaches the persisted queue.
  static func cleanProps(_ props: [String: Any]?) -> [String: Any]? {
    guard let props = props, !props.isEmpty, let len = jsonLength(props), len <= maxPropsBytes,
          let data = try? JSONSerialization.data(withJSONObject: props),
          let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return copy
  }

  /// A trait value as the server keeps it: text (trimmed, cut at 200), a finite number
  /// or a boolean — else nil. A JSON `true` read back is an NSNumber whose type is `c`.
  static func traitValue(_ raw: Any) -> Any? {
    if let s = raw as? String {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : String(t.prefix(maxTraitText))
    }
    if type(of: raw) == Bool.self { return raw }
    guard let n = raw as? NSNumber else { return nil }
    if String(cString: n.objCType) == "c" { return n.boolValue }
    return n.doubleValue.isFinite ? n : nil
  }

  /// Traits (identify's `set` / `setOnce`, and super-properties): valid keys, kept
  /// values, at most 50 — taken in key order, so the cut is the same on every run.
  static func cleanTraits(_ traits: [String: Any]?) -> [String: Any] {
    var out: [String: Any] = [:]
    guard let traits = traits else { return out }
    for key in traits.keys.sorted() {
      if out.count >= maxTraits { break }
      let range = NSRange(key.startIndex..<key.endIndex, in: key)
      guard traitKey.firstMatch(in: key, range: range) != nil, let v = traitValue(traits[key]!) else { continue }
      out[key] = v
    }
    return out
  }

  /// An event's properties with the super-properties under them: the event's own win.
  /// Over the 4 KB cap, the event's own properties alone.
  static func withSuperProps(_ own: [String: Any]?, _ sup: [String: Any]) -> [String: Any]? {
    if sup.isEmpty { return own }
    return cleanProps(sup.merging(own ?? [:]) { _, mine in mine }) ?? own
  }

  /// The session this activity belongs to: the current one, touched, or a new one after 30 idle minutes.
  static func touchSession(_ current: TraqioAnalyticsSession?, now: Int64, newId: () -> String) -> TraqioAnalyticsSession {
    if let c = current, now - c.last <= sessionIdleMs, now >= c.last - 60_000 {
      return TraqioAnalyticsSession(id: c.id, last: max(now, c.last))
    }
    return TraqioAnalyticsSession(id: newId(), last: now)
  }

  // ── Groups (B2B accounts, HQ cmwux5jo) ──
  // A user belongs to accounts (`company`, `workspace`…): every analytics event
  // carries the groups held when it was queued, so the console counts accounts.

  /// Group types held at once (the server's cap): a NEW 6th type is ignored.
  static let maxGroupTypes = 5
  static let maxGroupKey = 256
  private static let groupTypePattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{0,29}$")

  /// A group type the server will take (trimmed, lowercase: `company`, `workspace`), or nil.
  static func cleanGroupType(_ type: String) -> String? {
    let t = type.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = NSRange(t.startIndex..<t.endIndex, in: t)
    return groupTypePattern.firstMatch(in: t, range: range) != nil ? t : nil
  }

  /// A group key — the customer's own account id, never an email — trimmed, 1–256 chars, or nil.
  static func cleanGroupKey(_ key: String) -> String? {
    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return k.isEmpty || k.utf16.count > maxGroupKey ? nil : k
  }

  /// The groups held after `group(type, key)`, or nil when the call is ignored: an
  /// invalid type or key, or a NEW type beyond the 5th (an existing type may change key).
  static func withGroup(_ current: [String: String], type: String, key: String) -> [String: String]? {
    guard let t = cleanGroupType(type), let k = cleanGroupKey(key) else { return nil }
    if current[t] == nil && current.count >= maxGroupTypes { return nil }
    var next = current
    next[t] = k
    return next
  }

  /// Whether a `group()` call queues a group entry: when the key of that type changed,
  /// or traits came with it — a call at every launch with the same key sends nothing.
  static func shouldSendGroup(previousKey: String?, key: String, traits: [String: Any]) -> Bool {
    previousKey != key || !traits.isEmpty
  }

  /// A group entry: the account's properties — never an analytics row, never a visit.
  /// `sessionId` is the current session's or "" (it neither opens nor prolongs one).
  static func groupEntry(type: String, key: String, set: [String: Any], sessionId: String, now: Int64) -> [String: Any] {
    var e: [String: Any] = ["kind": "group", "ts": now, "sessionId": sessionId, "groupType": type, "groupKey": key]
    if !set.isEmpty { e["set"] = set }
    return e
  }

  /// Stored groups, read back and re-screened: bad pairs dropped, at most 5 types
  /// (taken in type order, so the cut is the same on every run).
  static func cleanGroups(_ raw: Any?) -> [String: String] {
    var out: [String: String] = [:]
    guard let o = raw as? [String: Any] else { return out }
    for type in o.keys.sorted() {
      guard let key = o[type] as? String, let next = withGroup(out, type: type, key: key) else { continue }
      out = next
    }
    return out
  }

  /// What a flush does with a batch after the server's answer.
  enum Outcome: Equatable { case sent, refused, retry }

  /// 2xx sent; 400/413/422 refused for good (the same body gets the same answer);
  /// anything else — network, 5xx, 429, a key fixed later (401/403) — retried.
  static func outcome(status: Int?) -> Outcome {
    guard let status = status else { return .retry }
    if (200..<300).contains(status) { return .sent }
    return [400, 413, 422].contains(status) ? .refused : .retry
  }

  /// The request body (the SDK adds `debug` like on every post).
  static func body(sdkKey: String, anonymousId: String, userId: String?, events: [[String: Any]]) -> [String: Any] {
    var body: [String: Any] = ["sdkKey": sdkKey, "anonymousId": anonymousId, "platform": "ios", "events": events]
    if let userId = userId, !userId.isEmpty { body["userId"] = userId }
    return body
  }
}

struct TraqioAnalyticsSession: Equatable {
  var id: String
  /// Last activity, epoch ms.
  var last: Int64

  var json: [String: Any] { ["id": id, "last": last] }

  /// A persisted session, read back — anything malformed is no session.
  init?(json: Any?) {
    guard let o = json as? [String: Any], let id = o["id"] as? String, let last = (o["last"] as? NSNumber)?.int64Value else { return nil }
    self.id = id
    self.last = last
  }

  init(id: String, last: Int64) {
    self.id = id
    self.last = last
  }
}

/// The analytics state between two calls — session, screen in view, super-properties —
/// and what each public call turns into on the wire. Pure: the clock and the id are
/// passed in, persistence is the caller's.
struct TraqioAnalyticsState {
  var session: TraqioAnalyticsSession?
  var currentScreen: String?
  var superProps: [String: Any] = [:]
  /// The groups the user belongs to — type → key (`group`). Copied onto every event when queued.
  var groups: [String: String] = [:]

  /// A custom event, or nil when the name is refused. Carries the screen in view.
  mutating func capture(_ name: String, props: [String: Any]?, now: Int64, newId: () -> String) -> [String: Any]? {
    guard let n = TraqioAnalyticsRules.cleanEventName(name) else { return nil }
    var e: [String: Any] = ["kind": "custom", "name": n]
    if let screen = currentScreen { e["screen"] = screen }
    return stamp(e, props: props, now: now, newId: newId)
  }

  /// A screen view, or nil when the name is refused or it is the screen already in
  /// view inside the same session (a re-render is not a second visit).
  mutating func screen(_ name: String, props: [String: Any]?, now: Int64, newId: () -> String) -> [String: Any]? {
    guard let s = TraqioAnalyticsRules.cleanScreenName(name) else { return nil }
    let sameVisit = session.map { now - $0.last <= TraqioAnalyticsRules.sessionIdleMs } ?? false
    if s == currentScreen && sameVisit { return nil }
    currentScreen = s
    return stamp(["kind": "pageview", "screen": s], props: props, now: now, newId: newId)
  }

  /// A user's properties, or nil when no trait is left. Not activity: the session is
  /// neither opened nor prolonged.
  func identify(userId: String, traits: [String: Any]?, traitsOnce: [String: Any]?, now: Int64) -> [String: Any]? {
    let set = TraqioAnalyticsRules.cleanTraits(traits)
    let setOnce = TraqioAnalyticsRules.cleanTraits(traitsOnce)
    if set.isEmpty && setOnce.isEmpty { return nil }
    var e: [String: Any] = ["kind": "identify", "ts": now, "sessionId": session?.id ?? "", "userId": userId]
    if !set.isEmpty { e["set"] = set }
    if !setOnce.isEmpty { e["setOnce"] = setOnce }
    return e
  }

  /// Joins a group (B2B account): held from now on and attached to every following
  /// event. Returns the group entry to queue, or nil when nothing is sent (an ignored
  /// call, or the same key again without traits). Not activity, like identify.
  mutating func group(type: String, key: String, traits: [String: Any]?, now: Int64) -> [String: Any]? {
    guard let next = TraqioAnalyticsRules.withGroup(groups, type: type, key: key),
          let t = TraqioAnalyticsRules.cleanGroupType(type), let k = next[t] else { return nil }
    let set = TraqioAnalyticsRules.cleanTraits(traits)
    let previous = groups[t]
    groups = next
    guard TraqioAnalyticsRules.shouldSendGroup(previousKey: previous, key: k, traits: set) else { return nil }
    return TraqioAnalyticsRules.groupEntry(type: t, key: k, set: set, sessionId: session?.id ?? "", now: now)
  }

  /// Leaves every group (sign-out).
  mutating func resetGroups() {
    groups = [:]
  }

  mutating func register(_ props: [String: Any]) {
    superProps = TraqioAnalyticsRules.cleanTraits(superProps.merging(TraqioAnalyticsRules.cleanTraits(props)) { _, new in new })
  }

  mutating func unregister(_ key: String) {
    superProps[key] = nil
  }

  private mutating func stamp(_ event: [String: Any], props: [String: Any]?, now: Int64, newId: () -> String) -> [String: Any] {
    let s = TraqioAnalyticsRules.touchSession(session, now: now, newId: newId)
    session = s
    var e = event
    e["ts"] = now
    e["sessionId"] = s.id
    if let p = TraqioAnalyticsRules.withSuperProps(TraqioAnalyticsRules.cleanProps(props), superProps) { e["props"] = p }
    if !groups.isEmpty { e["groups"] = groups }
    return e
  }
}
