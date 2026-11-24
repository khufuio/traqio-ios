import XCTest
@testable import TraqioSDK

/// Todo cmwlauev: the IDFA the install could not carry, posted once ATT is granted later.
final class AdvertisingIdSyncTests: XCTestCase {
  private let idfa = "6D92078A-8246-4BA4-AE5B-76104861E7DC"

  func testPostsANewIdOnceTheInstallIsReported() {
    XCTAssertEqual(TraqioAdvertisingIdSync.toPost(collect: true, installSent: true, current: idfa, acknowledged: nil), idfa)
  }

  func testNothingWhenAlreadyAcknowledged() {
    XCTAssertNil(TraqioAdvertisingIdSync.toPost(collect: true, installSent: true, current: idfa, acknowledged: idfa))
  }

  func testNothingBeforeTheInstallOrWithoutTheOptInOrWithoutATT() {
    XCTAssertNil(TraqioAdvertisingIdSync.toPost(collect: true, installSent: false, current: idfa, acknowledged: nil))
    XCTAssertNil(TraqioAdvertisingIdSync.toPost(collect: false, installSent: true, current: idfa, acknowledged: nil))
    // No ATT = `TraqioAdvertisingId.read()` answers nil.
    XCTAssertNil(TraqioAdvertisingIdSync.toPost(collect: true, installSent: true, current: nil, acknowledged: nil))
  }

  func testAResetIdIsPostedAgain() {
    XCTAssertEqual(
      TraqioAdvertisingIdSync.toPost(collect: true, installSent: true, current: idfa, acknowledged: "11111111-2222-3333-4444-555555555555"),
      idfa
    )
  }
}
