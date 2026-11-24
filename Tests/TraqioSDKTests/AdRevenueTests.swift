import Foundation
import XCTest
@testable import TraqioSDK

final class AdRevenueRulesTests: XCTestCase {
  func testPrecisionMapping() {
    XCTAssertEqual(TraqioAdRevenueRules.precision(0), "unknown")
    XCTAssertEqual(TraqioAdRevenueRules.precision(1), "estimated")
    XCTAssertEqual(TraqioAdRevenueRules.precision(2), "publisher_provided")
    XCTAssertEqual(TraqioAdRevenueRules.precision(3), "precise")
    XCTAssertEqual(TraqioAdRevenueRules.precision(9), "unknown")
  }

  /// GADAdValue.value is an NSDecimalNumber in currency units: exact to the micro.
  func testDecimalUnitsToMicros() {
    XCTAssertEqual(TraqioAdRevenueRules.micros(NSDecimalNumber(string: "0.000021")), 21)
    XCTAssertEqual(TraqioAdRevenueRules.micros(NSDecimalNumber(string: "1.5")), 1_500_000)
    XCTAssertNil(TraqioAdRevenueRules.micros(NSDecimalNumber(string: "-0.1")))
    XCTAssertNil(TraqioAdRevenueRules.micros(NSDecimalNumber.notANumber))
  }

  func testMaxImpression() {
    let item = TraqioAdRevenueRules.fromMax(revenue: 0.0123, precision: "exact", adUnitId: "u", format: "INTER", networkName: "AppLovin")
    XCTAssertEqual(item?["valueMicros"] as? Int64, 12_300)
    XCTAssertEqual(item?["currency"] as? String, "USD")
    XCTAssertEqual(item?["precision"] as? String, "precise")
    XCTAssertEqual(item?["adFormat"] as? String, "interstitial")
    XCTAssertNil(TraqioAdRevenueRules.fromMax(revenue: -1, precision: nil, adUnitId: nil, format: nil, networkName: nil))
  }

  /// AppLovin's "Impression-Level User Revenue API for MMPs" message keys.
  func testMaxRevenueEventMessage() {
    let item = TraqioAdRevenueRules.fromMaxMessage([
      "revenue": NSNumber(value: 0.0005), "country_code": "FR", "network_name": "Google AdMob",
      "max_ad_unit_id": "abc", "third_party_ad_placement_id": "ca-app-pub-1/2", "ad_format": "REWARDED", "id": "i",
    ])
    XCTAssertEqual(item?["valueMicros"] as? Int64, 500)
    XCTAssertEqual(item?["precision"] as? String, "unknown")
    XCTAssertEqual(item?["adUnitId"] as? String, "abc")
    XCTAssertEqual(item?["adFormat"] as? String, "rewarded")
    XCTAssertNil(TraqioAdRevenueRules.fromMaxMessage(["ad_format": "INTER"]))
  }

  func testBatchesOneSourceAtATime() {
    XCTAssertEqual(TraqioAdRevenueRules.nextBatchSize(sources: ["admob", "admob", "applovin_max"]), 2)
    XCTAssertEqual(TraqioAdRevenueRules.nextBatchSize(sources: Array(repeating: "admob", count: 250)), 100)
    XCTAssertEqual(TraqioAdRevenueRules.nextBatchSize(sources: []), 0)
  }
}

#if canImport(ObjectiveC)
import ObjectiveC

// Stand-ins with Google Mobile Ads' Objective-C surface. Registered under the real
// runtime names so the hooks find them exactly as they would find the SDK's.
@objc(GADAdValue) final class FakeAdValue: NSObject {
  @objc let value: NSDecimalNumber
  @objc let precision: Int
  @objc let currencyCode: String
  init(_ value: String, _ currency: String) {
    self.value = NSDecimalNumber(string: value)
    precision = 1
    currencyCode = currency
  }
}

@objc(GADInterstitialAd) final class FakeInterstitialAd: NSObject {
  @objc var paidEventHandler: (@convention(block) (FakeAdValue) -> Void)?
  @objc var adUnitID: String = "ca-app-pub-1/2"
  func pay(_ value: FakeAdValue) { paidEventHandler?(value) }
}

final class AdMobHookTests: XCTestCase {
  func testWrapsTheAppHandlerAndRunsIt() {
    let ad = FakeInterstitialAd()
    var appSaw = 0
    ad.paidEventHandler = { _ in appSaw += 1 }
    Traqio.watchAdMob(ad)
    ad.pay(FakeAdValue("0.01", "USD"))
    XCTAssertEqual(appSaw, 1)
    XCTAssertEqual(TraqioAdMobHooks.format(of: ad), "interstitial")
  }

  func testNeverWrapsItsOwnHandlerTwice() {
    let ad = FakeInterstitialAd()
    Traqio.watchAdMob(ad)
    let first = ad.value(forKey: "paidEventHandler") as AnyObject?
    Traqio.watchAdMob(ad)
    XCTAssertTrue(first === (ad.value(forKey: "paidEventHandler") as AnyObject?))
  }

  func testReadNeverRaisesOnAMissingKey() {
    XCTAssertNil(TraqioAdMobHooks.read(NSObject(), "adUnitID"))
  }
}
#endif

// HQ cmwfq3ij — once the option captures a network, a manual call cannot double an impression.
final class AdRevenueGateTests: XCTestCase {
  func testLetsManualCallsThroughWhileNothingIsCaptured() {
    var warnings: [String] = []
    let gate = TraqioAdRevenueGate { warnings.append($0) }
    XCTAssertTrue(gate.allowsManual(TraqioAdRevenueGate.admob, call: "trackAdRevenue"))
    XCTAssertTrue(gate.allowsManual(TraqioAdRevenueGate.applovinMax, call: "trackMaxAdRevenue"))
    XCTAssertTrue(warnings.isEmpty)
  }

  func testIgnoresManualCallsOfACapturedNetworkWarningOnce() {
    var warnings: [String] = []
    let gate = TraqioAdRevenueGate { warnings.append($0) }
    gate.arm(TraqioAdRevenueGate.applovinMax)
    XCTAssertFalse(gate.allowsManual(TraqioAdRevenueGate.applovinMax, call: "trackMaxAdRevenue"))
    XCTAssertFalse(gate.allowsManual(TraqioAdRevenueGate.applovinMax, call: "trackMaxAdRevenue"))
    XCTAssertTrue(gate.allowsManual(TraqioAdRevenueGate.admob, call: "trackAdRevenue"), "AdMob is not captured: still manual")
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].contains("adRevenue.applovinMax is on: manual trackMaxAdRevenue() ignored"))
  }
}
