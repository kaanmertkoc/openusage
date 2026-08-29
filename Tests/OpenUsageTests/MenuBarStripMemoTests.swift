import XCTest
@testable import OpenUsage

/// Covers the strip renderer's single-entry memo (#18): equal (content, style) inputs return the
/// previously rendered `NSImage` instance — so the hundreds of observation-loop re-renders between
/// real data changes never re-run `ImageRenderer`, and `StatusItemImageUpdater` can skip `apply`
/// on that same instance — while a changed value or style renders fresh.
@MainActor
final class MenuBarStripMemoTests: XCTestCase {
    func testEqualContentReturnsSameImageInstance() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        let second = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        XCTAssertIdentical(first, second)
    }

    func testChangedValueRendersFreshImage() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        let changed = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "43%"), style: .text))
        XCTAssertNotIdentical(first, changed)
    }

    func testChangedStyleRendersFreshImage() throws {
        let content = makeContent(value: "42%")
        let text = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .text))
        let bars = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .bars))
        XCTAssertNotIdentical(text, bars)
    }

    func testUnchangedMemoizedImageIsNotApplied() throws {
        var applied: [NSImage] = []
        var gate = StatusItemImageUpdater.ApplyGate()
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        let second = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        gate.apply(first, using: { applied.append($0); return true })
        gate.apply(second, using: { applied.append($0); return true })
        XCTAssertIdentical(first, second)
        XCTAssertEqual(applied.count, 1)
        XCTAssertIdentical(applied[0], first)
    }

    func testChangedImageIsApplied() throws {
        var applied: [NSImage] = []
        var gate = StatusItemImageUpdater.ApplyGate()
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        let changed = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "43%"), style: .text))
        gate.apply(first, using: { applied.append($0); return true })
        gate.apply(changed, using: { applied.append($0); return true })
        gate.apply(changed, using: { applied.append($0); return true })
        XCTAssertNotIdentical(first, changed)
        XCTAssertEqual(applied.count, 2)
        XCTAssertIdentical(applied[0], first)
        XCTAssertIdentical(applied[1], changed)
    }

    /// The gate must not record an image the apply never delivered. The real apply is
    /// `statusItem.button?.image = image`, which silently no-ops while the status item has no button
    /// (a culled/relocated item on a crowded menu bar). Because every image the updater can produce is
    /// a stable instance — the renderer memoizes by content, and the icon fallbacks are `static let` —
    /// a dropped apply that the gate recorded anyway wedges the strip: every later render of the same
    /// content returns that same instance, the gate skips it as "already shown", and the menu bar stays
    /// stale until the value happens to change while a button exists. The dashboard, which re-renders
    /// off its own live countdown, keeps showing the current numbers the whole time.
    func testApplyDroppedByAMissingButtonIsRetriedOnTheNextRender() throws {
        var hasButton = false
        var applied: [NSImage] = []
        let deliver: (NSImage) -> Bool = { image in
            guard hasButton else { return false }
            applied.append(image)
            return true
        }
        var gate = StatusItemImageUpdater.ApplyGate()

        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        gate.apply(first, using: deliver)
        XCTAssertTrue(applied.isEmpty, "no button yet, so nothing reached the status item")

        // The button comes back and the content is unchanged, so the renderer hands back the very same
        // memoized instance. The strip is still showing the pre-drop image, so this must be applied.
        hasButton = true
        let memoized = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        XCTAssertIdentical(first, memoized)
        gate.apply(memoized, using: deliver)

        XCTAssertEqual(applied.count, 1, "a dropped apply must be retried once the button exists")
    }

    /// Only a successful render is memoized. A `nil` render — nothing pinned, or a transient
    /// `ImageRenderer` failure — must not take the single memo slot: caching a failure would pin the
    /// strip to the fallback app icon for as long as the values stayed put, because the memo is keyed
    /// on content. Observable as the successful render surviving a `nil` one.
    func testFailedRenderDoesNotDisplaceTheMemoizedImage() throws {
        let content = makeContent(value: "77%")
        let rendered = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .text))

        XCTAssertNil(
            MenuBarStripRenderer.image(for: MenuBarContent(groups: [], bars: []), style: .text),
            "empty content renders nothing"
        )

        let afterNil = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .text))
        XCTAssertIdentical(rendered, afterNil, "a nil render must not evict the memoized image")
    }

    private func makeContent(value: String) -> MenuBarContent {
        let metric = MenuBarContent.Metric(
            id: "claude.session", label: "Session", value: value,
            fraction: 0.42, isBounded: true, hasData: true
        )
        return MenuBarContent(
            groups: [MenuBarContent.Group(
                providerID: "claude",
                displayName: "Claude",
                icon: .providerMark("claude"),
                metrics: [metric]
            )],
            bars: [metric]
        )
    }
}
