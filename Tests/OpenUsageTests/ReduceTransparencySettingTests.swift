import XCTest
@testable import OpenUsage

/// Covers the "on by default" semantics: an unset key reads as `true` (fresh installs and existing
/// users who never touched the toggle get the solid surface), while an explicit choice is preserved
/// in both directions. `current` reads `UserDefaults.standard` directly, so each test saves and
/// restores the real key to stay hermetic.
final class ReduceTransparencySettingTests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: ReduceTransparencySetting.key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: ReduceTransparencySetting.key)
        } else {
            UserDefaults.standard.removeObject(forKey: ReduceTransparencySetting.key)
        }
        super.tearDown()
    }

    func testDefaultsToTrueWhenUnset() {
        UserDefaults.standard.removeObject(forKey: ReduceTransparencySetting.key)
        XCTAssertTrue(ReduceTransparencySetting.current)
    }

    func testExplicitFalseIsPreserved() {
        UserDefaults.standard.set(false, forKey: ReduceTransparencySetting.key)
        XCTAssertFalse(ReduceTransparencySetting.current)
    }

    func testExplicitTrueIsPreserved() {
        UserDefaults.standard.set(true, forKey: ReduceTransparencySetting.key)
        XCTAssertTrue(ReduceTransparencySetting.current)
    }
}
