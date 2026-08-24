import XCTest
import SwiftUI
@testable import OpenUsage

/// Settings is expensive to mount (each menu picker builds an `NSPopUpButton`), so after its first
/// visit it lives in a sibling overlay that survives navigation instead of being rebuilt inside the
/// screen pager. These cover the geometry that keeps that overlay lined up with its pager slot, and
/// the gate that stops the parked copy from keeping a second footer and shortcut recorder alive.
///
/// Upstream carries these in `ReduceAnimationsSettingTests`; that setting isn't on this branch, so
/// they live here instead.
@MainActor
final class DashboardSettingsOverlayTests: XCTestCase {
    func testSettingsOverlayFollowsItsPagerSlotDuringASlide() {
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard, .settings],
                slideOffset: 0,
                pageWidth: 320
            ),
            320
        )
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard, .settings],
                slideOffset: -320,
                pageWidth: 320
            ),
            0
        )
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.settings],
                slideOffset: 0,
                pageWidth: 320
            ),
            0
        )
    }

    func testSettingsOverlayParksOffscreenWhenNotInThePager() {
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard],
                slideOffset: 0,
                pageWidth: 320
            ),
            640
        )
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard, .customize],
                slideOffset: -160,
                pageWidth: 320
            ),
            640
        )
    }

    func testSettingsChromeOnlyMountsWhileItsPageIsVisibleOrSliding() {
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: [.settings]))
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: [.dashboard, .settings]))
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: [.customize, .settings]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.dashboard]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.customize]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.dashboard, .customize]))
    }

}
