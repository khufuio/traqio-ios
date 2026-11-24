import Foundation
import XCTest
@testable import TraqioSDK

/// HQ cmwux580: product analytics, on the contract of `@traqio/core` (analytics.ts).
final class AnalyticsTests: XCTestCase {
  private typealias R = TraqioAnalyticsRules
  private let min30: Int64 = 30 * 60 * 1000

  private func ids() -> () -> String {
    var n = 0
    return { n += 1; return "s\(n)" }
  }

  private func json(_ o: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
  }

  // ── names ──

  func testEventNames() {
    XCTAssertEqual(R.cleanEventName("  deck_built "), "deck_built")
    XCTAssertNil(R.cleanEventName(""))
    XCTAssertNil(R.cleanEventName("   "))
    XCTAssertNil(R.cleanEventName("$pageview"))
    XCTAssertEqual(R.cleanEventName(String(repeating: "a", count: 128))?.count, 128)
    XCTAssertNil(R.cleanEventName(String(repeating: "a", count: 129)))
  }

  func testScreenNames() {
    XCTAssertEqual(R.cleanScreenName(" Home "), "Home")
    XCTAssertNil(R.cleanScreenName(" "))
    XCTAssertEqual(R.cleanScreenName(String(repeating: "x", count: 600))?.count, 512)
  }

  // ── props ──

  func testPropsSurviveJsonUnderTheCap() {
    XCTAssertEqual(json(R.cleanProps(["a": 1, "b": "x", "c": ["d": true]])!), #"{"a":1,"b":"x","c":{"d":true}}"#)
    XCTAssertNil(R.cleanProps(nil))
    XCTAssertNil(R.cleanProps([:]))
    XCTAssertNil(R.cleanProps(["when": Date()]), "not JSON → dropped")
    XCTAssertNil(R.cleanProps(["x": Double.nan]))
    // {"k":"…"} is 8 characters around the value.
    XCTAssertNotNil(R.cleanProps(["k": String(repeating: "a", count: 4088)]))
    XCTAssertNil(R.cleanProps(["k": String(repeating: "a", count: 4089)]))
  }

  // ── traits ──

  func testTraits() {
    let t = R.cleanTraits([
      "plan": " pro ", "seats": 12, "ratio": 1.5, "beta": true, "empty": "  ", "bad key": "x", "$set": "x",
      "nested": ["a": 1], "list": [1], "long": String(repeating: "z", count: 300), "nan": Double.nan,
    ])
    XCTAssertEqual(Set(t.keys), ["plan", "seats", "ratio", "beta", "long"])
    XCTAssertEqual(t["plan"] as? String, "pro")
    XCTAssertEqual((t["long"] as? String)?.count, 200)
    XCTAssertEqual(json(["beta": t["beta"]!, "seats": t["seats"]!]), #"{"beta":true,"seats":12}"#)
  }

  func testTraitsReadBackFromJsonKeepTheirTypes() {
    let data = #"{"on":true,"n":1,"x":1.5}"#.data(using: .utf8)!
    let t = R.cleanTraits(try! JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json(t), #"{"n":1,"on":true,"x":1.5}"#)
  }

  func testTraitsCappedAt50() {
    var many: [String: Any] = [:]
    for i in 0..<80 { many[String(format: "k%02d", i)] = i }
    let t = R.cleanTraits(many)
    XCTAssertEqual(t.count, 50)
    XCTAssertNotNil(t["k00"])
    XCTAssertNil(t["k50"])
  }

  // ── super-properties ──

  func testSuperPropsUnderTheEventsOwn() {
    XCTAssertEqual(json(R.withSuperProps(["theme": "light", "a": 1], ["theme": "dark", "flavor": "beta"])!), #"{"a":1,"flavor":"beta","theme":"light"}"#)
    XCTAssertEqual(json(R.withSuperProps(nil, ["flavor": "beta"])!), #"{"flavor":"beta"}"#)
    XCTAssertNil(R.withSuperProps(nil, [:]))
    // Over 4 KB together → the event's own alone.
    let own: [String: Any] = ["k": String(repeating: "a", count: 4000)]
    XCTAssertEqual(json(R.withSuperProps(own, ["s": String(repeating: "b", count: 199)])!), json(own))
  }

  func testRegisterAndUnregister() {
    var s = TraqioAnalyticsState()
    s.register(["flavor": "beta", "bad key": 1])
    s.register(["theme": "dark", "flavor": "prod"])
    XCTAssertEqual(json(s.superProps), #"{"flavor":"prod","theme":"dark"}"#)
    s.unregister("flavor")
    XCTAssertEqual(json(s.superProps), #"{"theme":"dark"}"#)
    let e = s.capture("x", props: nil, now: 1_000, newId: ids())!
    XCTAssertEqual(json(e["props"]!), #"{"theme":"dark"}"#)
  }

  // ── sessions ──

  func testSessionRule() {
    let next = ids()
    let a = R.touchSession(nil, now: 1_000, newId: next)
    XCTAssertEqual(a, TraqioAnalyticsSession(id: "s1", last: 1_000))
    let b = R.touchSession(a, now: 1_000 + min30, newId: next)
    XCTAssertEqual(b, TraqioAnalyticsSession(id: "s1", last: 1_000 + min30))
    let c = R.touchSession(b, now: b.last + min30 + 1, newId: next)
    XCTAssertEqual(c.id, "s2")
    // A clock gone back more than a minute is a new session; less keeps it and its `last`.
    XCTAssertEqual(R.touchSession(c, now: c.last - 30_000, newId: next), c)
    XCTAssertEqual(R.touchSession(c, now: c.last - 60_001, newId: next).id, "s3")
  }

  func testSessionJsonRoundTrip() {
    let s = TraqioAnalyticsSession(id: "abc", last: 1_732_000_000_000)
    let data = try! JSONSerialization.data(withJSONObject: s.json)
    XCTAssertEqual(TraqioAnalyticsSession(json: try! JSONSerialization.jsonObject(with: data)), s)
    XCTAssertNil(TraqioAnalyticsSession(json: ["id": 1]))
    XCTAssertNil(TraqioAnalyticsSession(json: nil))
  }

  // ── events on the wire ──

  func testCaptureCarriesTheScreenInViewAndTheSession() {
    var s = TraqioAnalyticsState()
    let next = ids()
    XCTAssertNil(s.capture("$reserved", props: nil, now: 1, newId: next))
    let v = s.screen(" Home ", props: ["tab": "decks"], now: 1_000, newId: next)!
    XCTAssertEqual(json(v), #"{"kind":"pageview","props":{"tab":"decks"},"screen":"Home","sessionId":"s1","ts":1000}"#)
    let e = s.capture("deck_built", props: ["cards": 40], now: 2_000, newId: next)!
    XCTAssertEqual(json(e), #"{"kind":"custom","name":"deck_built","props":{"cards":40},"screen":"Home","sessionId":"s1","ts":2000}"#)
  }

  func testSameScreenTwiceInASessionCountsOnce() {
    var s = TraqioAnalyticsState()
    let next = ids()
    XCTAssertNotNil(s.screen("Home", props: nil, now: 1_000, newId: next))
    XCTAssertNil(s.screen("Home", props: nil, now: 2_000, newId: next))
    XCTAssertNotNil(s.screen("Deck", props: nil, now: 3_000, newId: next))
    XCTAssertNotNil(s.screen("Home", props: nil, now: 4_000, newId: next))
    // Back after the session ended: a new visit of the same screen counts.
    let late = s.screen("Home", props: nil, now: 4_000 + min30 + 1, newId: next)!
    XCTAssertEqual(late["sessionId"] as? String, "s2")
  }

  func testIdentifyIsNotActivity() {
    var s = TraqioAnalyticsState()
    XCTAssertNil(s.identify(userId: "u1", traits: ["bad key": 1], traitsOnce: nil, now: 1))
    let early = s.identify(userId: "u1", traits: ["plan": "pro"], traitsOnce: nil, now: 5)!
    XCTAssertEqual(json(early), #"{"kind":"identify","sessionId":"","set":{"plan":"pro"},"ts":5,"userId":"u1"}"#)
    _ = s.capture("x", props: nil, now: 10, newId: ids())
    let i = s.identify(userId: "u1", traits: nil, traitsOnce: ["signup_platform": "ios"], now: 20)!
    XCTAssertEqual(json(i), #"{"kind":"identify","sessionId":"s1","setOnce":{"signup_platform":"ios"},"ts":20,"userId":"u1"}"#)
    XCTAssertEqual(s.session?.last, 10, "identify does not prolong the session")
  }

  func testBatchBody() {
    let body = R.body(sdkKey: "tq_live_x", anonymousId: "dev-1", userId: "u1", events: [["kind": "custom", "name": "a", "ts": 1, "sessionId": "s1"]])
    XCTAssertEqual(json(body), #"{"anonymousId":"dev-1","events":[{"kind":"custom","name":"a","sessionId":"s1","ts":1}],"platform":"ios","sdkKey":"tq_live_x","userId":"u1"}"#)
    XCTAssertNil(R.body(sdkKey: "k", anonymousId: "d", userId: nil, events: [])["userId"])
  }

  func testOutcomes() {
    XCTAssertEqual(R.outcome(status: 200), .sent)
    XCTAssertEqual(R.outcome(status: 202), .sent)
    for s in [400, 413, 422] { XCTAssertEqual(R.outcome(status: s), .refused) }
    for s in [401, 403, 429, 500, 503] { XCTAssertEqual(R.outcome(status: s), .retry) }
    XCTAssertEqual(R.outcome(status: nil), .retry)
  }

  // ── groups (B2B accounts, HQ cmwux5jo) ──

  func testGroupTypesAndKeysAreCleanedAtMostFiveTypes() {
    XCTAssertEqual(R.cleanGroupType(" company "), "company")
    for bad in ["", "Company", "1team", "team-a", String(repeating: "a", count: 31)] { XCTAssertNil(R.cleanGroupType(bad), bad) }
    XCTAssertEqual(R.cleanGroupKey("  acme "), "acme")
    for bad in ["", "   ", String(repeating: "k", count: 257)] { XCTAssertNil(R.cleanGroupKey(bad)) }
    var g: [String: String] = [:]
    for i in 1...5 { g = R.withGroup(g, type: "t\(i)", key: "k\(i)")! }
    // A new 6th type is ignored; an existing type may change its key.
    XCTAssertNil(R.withGroup(g, type: "t6", key: "k6"))
    XCTAssertEqual(R.withGroup(g, type: "t1", key: "k9")?["t1"], "k9")
    XCTAssertNil(R.withGroup(g, type: "t1", key: ""))
  }

  func testAGroupEntryIsSentWhenTheKeyChangesOrTraitsCome() {
    XCTAssertTrue(R.shouldSendGroup(previousKey: nil, key: "acme", traits: [:]))
    XCTAssertTrue(R.shouldSendGroup(previousKey: "old", key: "acme", traits: [:]))
    XCTAssertFalse(R.shouldSendGroup(previousKey: "acme", key: "acme", traits: [:]))
    XCTAssertTrue(R.shouldSendGroup(previousKey: "acme", key: "acme", traits: ["plan": "pro"]))
    XCTAssertEqual(json(R.groupEntry(type: "company", key: "acme", set: [:], sessionId: "", now: 5)),
                   #"{"groupKey":"acme","groupType":"company","kind":"group","sessionId":"","ts":5}"#)
  }

  func testStoredGroupsAreReScreened() {
    XCTAssertEqual(R.cleanGroups(["company": "acme", "Bad": "x", "team": 3, "empty": " "]), ["company": "acme"])
    XCTAssertEqual(R.cleanGroups(nil), [:])
    var many: [String: Any] = [:]
    for i in 1...7 { many["t\(i)"] = "k\(i)" }
    XCTAssertEqual(R.cleanGroups(many).count, 5)
  }

  func testGroupsRideOnEventsNotOnIdentifyOrGroupEntries() {
    var s = TraqioAnalyticsState()
    let next = ids()
    XCTAssertNil(s.group(type: "Company", key: "acme", traits: nil, now: 1))
    let g = s.group(type: "company", key: " acme ", traits: ["plan": "pro", "seats": 12, "bad key": 1], now: 1)!
    XCTAssertEqual(json(g), #"{"groupKey":"acme","groupType":"company","kind":"group","sessionId":"","set":{"plan":"pro","seats":12},"ts":1}"#)
    XCTAssertNil(s.session, "a group call is not activity")
    // Same key, no traits: nothing new to send.
    XCTAssertNil(s.group(type: "company", key: "acme", traits: nil, now: 2))
    XCTAssertEqual(s.groups, ["company": "acme"])
    let e = s.capture("a", props: nil, now: 3, newId: next)!
    XCTAssertEqual(json(e), #"{"groups":{"company":"acme"},"kind":"custom","name":"a","sessionId":"s1","ts":3}"#)
    let v = s.screen("Home", props: ["tab": "x"], now: 4, newId: next)!
    XCTAssertEqual(json(v), #"{"groups":{"company":"acme"},"kind":"pageview","props":{"tab":"x"},"screen":"Home","sessionId":"s1","ts":4}"#)
    XCTAssertNil(s.identify(userId: "u1", traits: ["plan": "pro"], traitsOnce: nil, now: 5)!["groups"])
    let moved = s.group(type: "company", key: "globex", traits: nil, now: 6)!
    XCTAssertEqual(json(moved), #"{"groupKey":"globex","groupType":"company","kind":"group","sessionId":"s1","ts":6}"#)
    s.resetGroups()
    XCTAssertTrue(s.groups.isEmpty)
    XCTAssertNil(s.capture("b", props: nil, now: 7, newId: next)!["groups"])
  }
}
