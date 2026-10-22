// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
@testable import EarlyWeb
import Testing
import SwiftUI
import WebKit

/// Controller and unshown native-host checks only. No app launch/input synthesis.
@Suite(.serialized) @MainActor
struct SplitPresentationTests {
    @MainActor private final class AttachmentRecordingWebView: WKWebView {
        var arrivalFrames: [CGRect] = []
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview != nil { arrivalFrames.append(frame) }
        }
    }

    @MainActor private final class ResizeRecordingWebView: WKWebView {
        var resizeStarts = 0
        var resizeEnds = 0
        override func viewWillStartLiveResize() {
            resizeStarts += 1
            super.viewWillStartLiveResize()
        }
        override func viewDidEndLiveResize() {
            resizeEnds += 1
            super.viewDidEndLiveResize()
        }
    }

    @MainActor private final class ReadyPages: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let data = Data("""
                <!doctype html><html><head><title>Ready</title>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>html,body{margin:0;background:#202124;color:white}body{min-height:100vh}</style>
                </head><body>Ready<input id="saved"></body></html>
                """.utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    @MainActor private final class Fixture {
        let suite = "local.early.tests.split.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel
        let tabs: [BrowserTab]
        var saves = 0
        var feedback = 0
        init(servePages: Bool = false) {
            _ = NSApplication.shared
            let profile = UUID(), space = UUID()
            tabs = (0..<4).map { BrowserTab(spaceID: space, profileID: profile, title: "Page \($0)",
                currentURL: URL(string: "early-test://fixture/one?tab=\($0)")!) }
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            defaults.set(false, forKey: "haptics")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("EarlySplit-\(UUID()).sqlite"), input: input)
            let pages = ReadyPages()
            model = BrowserWindowModel(startup: .returningSession,
                session: BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs, selectionBySpace: [space: tabs[0].id]),
                repository: repository, input: input, isTesting: true, restorationError: nil, defaults: defaults,
                configureWebView: servePages ? { $0.setURLSchemeHandler(pages, forURLScheme: "early-test") } : nil)
            model.onSave = { [weak self] _ in self?.saves += 1 }
            model.onSplitPreviewFeedback = { [weak self] in self?.feedback += 1 }
        }
        func cleanup() {
            model.cancelWindowInteractions()
            model.sidebarInteractionInProgress = false
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private let bounds = CGRect(x: 250, y: 6, width: 700, height: 600)
    private let left = CGPoint(x: 425, y: 306), right = CGPoint(x: 775, y: 306)

    @Test func dragPreviewIsReadOnlyDeduplicatesHapticsAndCommitHasNoDropPulse() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, initial = model.coordinator.session
        let focus = model.contentFocusRequest, work = model.webViews.workMetrics
        let original = try #require(model.activePage)
        model.preferences.haptics = true // Test callback replaces the performer.
        model.sidebarInteractionInProgress = true
        // Crossing the content boundary reveals BOTH cards without activating a
        // split. Neither old edge is a target, and the center is a cancel zone.
        for point in [CGPoint(x: 251, y: 306), CGPoint(x: 600, y: 306), CGPoint(x: 949, y: 306)] {
            model.updateSplitPreview(for: fixture.tabs[1].id, at: point, in: bounds)
            #expect(model.splitDropSourceID == fixture.tabs[1].id && model.splitPreview == nil)
            #expect(fixture.feedback == 0 && model.coordinator.session == initial)
        }
        for _ in 0..<50 { model.updateSplitPreview(for: fixture.tabs[1].id, at: right, in: bounds) }
        #expect(model.splitPreview?.side == .trailing && fixture.feedback == 1)
        #expect(model.coordinator.session == initial && model.activePage === original)
        #expect(model.webViews.creationCount == 1 && model.webViews.snapshots.pendingCount == 0)
        #expect(fixture.saves == 0 && model.contentFocusRequest == focus)
        #expect(model.webViews.workMetrics.retentionPasses == work.retentionPasses)
        #expect(model.webViews.workMetrics.presentationVisits == work.presentationVisits)
        model.updateSplitPreview(for: fixture.tabs[1].id, at: left, in: bounds)
        #expect(fixture.feedback == 2)
        #expect(model.commitSplitPreview())
        #expect(fixture.feedback == 2 && fixture.saves == 1)
        #expect(model.splitPreview == nil && model.splitDropSourceID == nil)
        #expect(model.coordinator.visibleTabIDs == [fixture.tabs[0].id, fixture.tabs[1].id])
        #expect(model.webViews.creationCount == 2 && model.webViews.pages[fixture.tabs[0].id] === original)
        #expect(model.webViews.visibleTabIDs == model.coordinator.visibleTabIDs)
        #expect(model.contentFocusRequest == focus + 1)
    }

    @Test func invalidTargetsDisabledHapticsAndCancellationLeaveOrganizationUntouched() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, initial = model.coordinator.session
        model.sidebarInteractionInProgress = true
        model.updateSplitPreview(for: fixture.tabs[1].id, at: right, in: bounds)
        #expect(model.splitPreview != nil && fixture.feedback == 0)
        for point in [CGPoint(x: 200, y: 100), CGPoint(x: 600, y: 306), CGPoint(x: 949, y: -1)] {
            model.updateSplitPreview(for: fixture.tabs[1].id, at: point, in: bounds)
            #expect(model.splitPreview == nil && !model.commitSplitPreview())
        }
        model.updateSplitPreview(for: fixture.tabs[0].id, at: right, in: bounds)
        #expect(model.splitPreview == nil && model.splitDropSourceID == nil)
        model.updateSplitPreview(for: fixture.tabs[1].id, at: right, in: bounds)
        model.cancelWindowInteractions()
        #expect(model.splitPreview == nil && model.splitDropSourceID == nil && !model.commitSplitPreview())
        #expect(model.coordinator.session == initial && fixture.saves == 0 && model.webViews.creationCount == 1)
    }

    @Test func leavingCardsClearsHighlightLeavingContentHidesTargetsAndStaleSourceCannotCommit() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, source = fixture.tabs[1].id
        model.preferences.haptics = true
        model.sidebarInteractionInProgress = true
        model.updateSplitPreview(for: source, at: left, in: bounds)
        #expect(fixture.feedback == 1 && model.splitPreview?.side == .leading)
        model.updateSplitPreview(for: source, at: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds)
        #expect(model.splitDropSourceID == source && model.splitPreview == nil && fixture.feedback == 1)
        model.updateSplitPreview(for: source, at: CGPoint(x: bounds.minX - 1, y: bounds.midY), in: bounds)
        #expect(model.splitDropSourceID == nil && model.splitPreview == nil)
        model.updateSplitPreview(for: source, at: right, in: bounds)
        #expect(fixture.feedback == 2)
        // A close arriving while dragging cannot apply the stale proposal.
        model.coordinator.closeTab(source)
        #expect(!model.commitSplitPreview())
        #expect(model.splitDropSourceID == nil && model.splitPreview == nil && fixture.feedback == 2)
        #expect(model.coordinator.activeSplitGroup == nil && fixture.saves == 0)
    }

    @Test func modalAndOrganizationChangesClearEvenUnhighlightedTargets() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, source = fixture.tabs[1].id
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        model.updateSplitPreview(for: source, at: center, in: bounds)
        #expect(model.splitDropSourceID == source && model.splitPreview == nil)
        model.folderEditorIsPresented = true
        model.updateSplitPreview(for: source, at: right, in: bounds)
        #expect(model.splitDropSourceID == nil && model.splitPreview == nil)
        model.folderEditorIsPresented = false
        model.updateSplitPreview(for: source, at: center, in: bounds)
        model.coordinator.closeTab(source)
        model.save()
        #expect(model.splitDropSourceID == nil && model.splitPreview == nil)
    }

    @Test func floatingSidebarOrganizationNeverRevealsOrActivatesContentTargets() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, initial = model.coordinator.session, source = fixture.tabs[1].id
        model.sidebarInteractionInProgress = true
        let content = CGRect(x: 6, y: 6, width: 900, height: 600)
        let targets = try #require(BrowserSplitDropTargets(in: content, leadingInset: 270))
        model.updateSplitPreview(for: source, at: CGPoint(x: 200, y: 306), in: content, leadingInset: 270)
        #expect(model.splitDropSourceID == nil && model.splitPreview == nil)
        model.updateSplitPreview(for: source, at: CGPoint(x: 280, y: 306), in: content, leadingInset: 270)
        #expect(model.splitDropSourceID == source && model.splitPreview == nil)
        model.updateSplitPreview(for: source, at: CGPoint(x: targets.leading.midX, y: targets.leading.midY), in: content, leadingInset: 270)
        #expect(model.splitPreview?.side == .leading)
        // Returning to the overlapping sidebar cancels the content proposal.
        model.updateSplitPreview(for: source, at: CGPoint(x: 200, y: 306), in: content, leadingInset: 270)
        #expect(model.splitDropSourceID == nil && !model.commitSplitPreview())
        #expect(model.coordinator.session == initial && fixture.saves == 0 && model.webViews.creationCount == 1)
    }

    @Test func resizeIsTransientUntilReleaseAndCancellationRestoresSavedFraction() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let group = try #require(model.coordinator.activeSplitGroup), initial = model.coordinator.session
        let saves = fixture.saves, focus = model.contentFocusRequest
        model.beginSplitResize(group.id)
        #expect(model.webViews.interactionInProgress)
        #expect(!model.canManageSpaces)
        for index in 0..<100 { model.updateSplitResize(0.5 + Double(index) / 500) }
        #expect(model.coordinator.session == initial && fixture.saves == saves)
        #expect(model.contentFocusRequest == focus && model.webViews.creationCount == 2)
        model.finishSplitResize(commit: true)
        #expect(abs((model.coordinator.activeSplitGroup?.leadingFraction ?? 0) - 0.698) < 0.000001)
        #expect(fixture.saves == saves + 1 && !model.webViews.interactionInProgress)
        model.beginSplitResize(group.id)
        model.updateSplitResize(0.3)
        model.cancelWindowInteractions()
        #expect(model.splitResize == nil && abs((model.coordinator.activeSplitGroup?.leadingFraction ?? 0) - 0.698) < 0.000001)
        #expect(fixture.saves == saves + 1 && model.contentFocusRequest == focus)
    }

    @Test func pointerFocusDoesNotStealInputAndPaneRemovalKeepsBothPagesLive() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let group = try #require(model.coordinator.activeSplitGroup)
        let leftPage = try #require(model.webViews.pages[fixture.tabs[0].id])
        let rightPage = try #require(model.webViews.pages[fixture.tabs[1].id])
        let focus = model.contentFocusRequest
        #expect(model.focusPane(group.panes[0].id, restoreFocus: false))
        #expect(model.activePage === leftPage && model.contentFocusRequest == focus)
        let saves = fixture.saves
        #expect(model.focusPane(group.panes[0].id, restoreFocus: false))
        #expect(fixture.saves == saves)
        #expect(model.perform(.focusSplitPane(group.panes[1].id)))
        #expect(model.activePage === rightPage && model.contentFocusRequest == focus + 1)
        #expect(model.perform(.removeSplitPane(group.panes[1].id)))
        #expect(model.coordinator.splitGroups.isEmpty && model.activePage === leftPage)
        #expect(model.webViews.pages[fixture.tabs[1].id] === rightPage && model.webViews.creationCount == 2)
        #expect(model.coordinator.tabStore.tabs.allSatisfy { $0.isOpen })
    }

    @Test func swapSavesOnceWithoutReloadingPagesMovingFocusOrOfferingMemberPlacement() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let group = try #require(model.coordinator.activeSplitGroup)
        let original = model.coordinator.session, focus = model.contentFocusRequest, saves = fixture.saves
        let pages = model.webViews.pages
        #expect(model.perform(.swapSplit(group.id)))
        #expect(model.coordinator.activeSplitGroup?.panes == Array(group.panes.reversed()))
        #expect(model.coordinator.focusedPaneByGroupID == original.focusedPaneByGroupID)
        #expect(model.coordinator.session.tabs == original.tabs && model.coordinator.focusedTabID == fixture.tabs[1].id)
        #expect(model.contentFocusRequest == focus && fixture.saves == saves + 1)
        #expect(model.webViews.creationCount == 2 && model.webViews.focusedTabID == fixture.tabs[1].id)
        for (id, page) in pages { #expect(model.webViews.pages[id] === page) }
        for pane in group.panes {
            #expect(model.splitGroup(containing: pane.tabID)?.id == group.id)
            for side in BrowserSplitSide.allCases {
                #expect(!model.canPerform(.splitTab(pane.tabID, side)))
                #expect(!model.perform(.splitTab(pane.tabID, side)))
            }
        }
        #expect(model.splitGroup(containing: fixture.tabs[2].id) == nil)
        #expect(model.canPerform(.splitTab(fixture.tabs[2].id, .leading)))
        #expect(!model.perform(.swapSplit(UUID())) && fixture.saves == saves + 1)
        model.folderEditorIsPresented = true
        #expect(!model.perform(.swapSplit(group.id)))
        model.folderEditorIsPresented = false
        #expect(model.perform(.presentCommandBar(.commandSearch)))
        model.updateQuery("split")
        let commands = model.commandSearchCandidates()
        #expect(commands.contains { $0.target == .action(.swapSplit(group.id)) })
        #expect(!commands.contains { $0.target == .action(.splitTab(fixture.tabs[1].id, .trailing)) })
        #expect(model.perform(.swapSplit(group.id), source: .commandBar))
        #expect(model.coordinator.commandBar == nil && model.coordinator.activeSplitGroup == group)
    }

    @Test func nativeDividerRegistersCursorBeforeClickAndRetainsAccessibleKeyboardResize() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let divider = SplitDividerView(frame: CGRect(x: 390, y: 0, width: 12, height: 600))
        try #require(window.contentView).addSubview(divider)
        defer { divider.invalidate(); window.close() }
        let groupID = UUID(), layout = BrowserSplitLayout(size: CGSize(width: 800, height: 600), leadingFraction: 0.5)
        divider.configure(groupID: groupID, layout: layout, enabled: true, resizing: false, increasedContrast: false)
        divider.resetCursorRects()
        #expect(divider.clipsToBounds && divider.resizeCursorRect == divider.bounds.intersection(divider.visibleRect))
        let cursorRect = try #require(divider.resizeCursorRect)
        #expect(abs(cursorRect.width - 12) < 0.001, "Native cursor region: \(cursorRect)")
        #expect(divider.focusRingType == .none && !divider.keyboardFocused)
        #expect(divider.becomeFirstResponder() && divider.keyboardFocused)
        #expect(divider.resignFirstResponder() && !divider.keyboardFocused)
        #expect(divider.accessibilityRole() == .splitter && divider.accessibilityIdentifier() == "split.divider")
        #expect(divider.accessibilityValue() as? String == "50 percent left pane")
        var adjustments: [Double] = [], fractions: [Double] = [], commits: [Bool] = []
        divider.onAdjust = { adjustments.append($0); return true }
        #expect(divider.accessibilityPerformIncrement() && divider.accessibilityPerformDecrement())
        #expect(adjustments == [0.05, -0.05])
        #expect(SplitDividerView.adjustment(for: 123, modifiers: []) == -0.05)
        #expect(SplitDividerView.adjustment(for: 124, modifiers: [.shift]) == 0.05)
        for modifiers: NSEvent.ModifierFlags in [[.command], [.control], [.option], [.control, .option]] {
            #expect(SplitDividerView.adjustment(for: 123, modifiers: modifiers) == nil)
        }
        #expect(SplitDividerView.adjustment(for: 17, modifiers: []) == nil)
        divider.onBegin = { true }
        divider.onResize = { fractions.append($0) }
        divider.onEnd = { commits.append($0) }
        divider.beginResize(atWindowX: 400)
        divider.updateResize(atWindowX: 479.2)
        #expect(abs(try #require(fractions.last) - 0.6) < 0.00001)
        divider.endResize(commit: true)
        #expect(commits == [true])
        divider.beginResize(atWindowX: 400)
        divider.invalidate()
        #expect(commits == [true, false] && divider.resizeCursorRect == nil)
        #expect(!divider.acceptsFirstResponder && !divider.accessibilityPerformIncrement() && !window.isVisible)
    }

    @Test(arguments: [false, true])
    func nativeDividerDrawsOnlyAKeyboardFocusIndicator(increasedContrast: Bool) throws {
        _ = NSApplication.shared
        let divider = SplitDividerView(frame: CGRect(x: 0, y: 0, width: 12, height: 120))
        defer { divider.invalidate() }
        divider.configure(groupID: UUID(), layout: BrowserSplitLayout(size: CGSize(width: 800, height: 120), leadingFraction: 0.5),
                          enabled: true, resizing: false, increasedContrast: increasedContrast)
        func paintedPixels(appearance: NSAppearance.Name) throws -> [CGPoint] {
            // Render this native drawing into memory only. No window, app
            // launch, screen capture or synthesized pointer/keyboard input.
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 120,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            let style = try #require(NSAppearance(named: appearance))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.clear(divider.bounds)
            style.performAsCurrentDrawingAppearance { divider.draw(divider.bounds) }
            return (0..<120).flatMap { y in
                (0..<12).compactMap { x in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 ? CGPoint(x: x, y: y) : nil
                }
            }
        }
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            #expect(try paintedPixels(appearance: appearance).isEmpty)
            divider.onBegin = { true }
            divider.beginResize(atWindowX: 400)
            #expect(try paintedPixels(appearance: appearance).isEmpty, "Pointer dragging must not show a grip or line")
            divider.endResize(commit: false)
            #expect(divider.becomeFirstResponder())
            let focusedPixels = try paintedPixels(appearance: appearance)
            #expect(!focusedPixels.isEmpty)
            #expect(focusedPixels.allSatisfy { $0.x >= 4 && $0.x < 8 && $0.y >= 36 && $0.y < 84 },
                    "Only the compact keyboard-focus indicator may be drawn")
            #expect(divider.resignFirstResponder())
            #expect(try paintedPixels(appearance: appearance).isEmpty)
        }
    }

    @Test func contentEdgesHaveOnlyOneBorderOwnerAndFocusKeepsTheSameShape() {
        for radius: CGFloat in [4, 8, 10, 16] {
            let single = BrowserContentSurface.container(cornerRadius: radius, split: false)
            let singlePage = BrowserContentSurface.pane(cornerRadius: radius, split: false, focused: true)
            #expect(single.border == .standard && single.cornerRadius == radius)
            #expect(singlePage.border == .none && singlePage.cornerRadius == 0)
            #expect(single.borderWidth == 1 && singlePage.borderWidth == 0)
            let pair = BrowserContentSurface.container(cornerRadius: radius, split: true)
            let focused = BrowserContentSurface.pane(cornerRadius: radius, split: true, focused: true)
            let other = BrowserContentSurface.pane(cornerRadius: radius, split: true, focused: false)
            #expect(pair.border == .none && pair.cornerRadius == 0, "The pair must not add another rounded edge")
            #expect(focused.border == .focused && other.border == .standard)
            #expect(pair.borderWidth == 0 && focused.borderWidth == 2 && other.borderWidth == 1)
            #expect(focused.shape.cornerSize == CGSize(width: radius, height: radius))
            #expect(other.shape.cornerSize == focused.shape.cornerSize)
            let bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
            #expect(focused.shape.path(in: bounds) == other.shape.path(in: bounds))
            #expect(focused.shape.path(in: bounds) == single.shape.path(in: bounds))
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func splitFocusEmphasizesTheSameSingleEdgeWithoutAnEnclosingOutline(_ scheme: ColorScheme) throws {
        _ = NSApplication.shared
        func pixels(focusLeft: Bool) throws -> NSBitmapImageRep {
            let pair = HStack(spacing: 8) {
                Color.clear.modifier(BrowserContentSurface.pane(cornerRadius: 10, split: true, focused: focusLeft))
                Color.clear.modifier(BrowserContentSurface.pane(cornerRadius: 10, split: true, focused: !focusLeft))
            }
            .frame(width: 120, height: 80)
            .modifier(BrowserContentSurface.container(cornerRadius: 10, split: true))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: pair)
            renderer.scale = 2
            let data = try #require(renderer.nsImage?.tiffRepresentation)
            return try #require(NSBitmapImageRep(data: data))
        }
        for focusLeft in [true, false] {
            let image = try pixels(focusLeft: focusLeft)
            #expect(image.pixelsWide == 240 && image.pixelsHigh == 160)
            func alpha(_ x: Int, _ y: Int) -> CGFloat { image.colorAt(x: x * 2, y: y * 2)?.alphaComponent ?? 1 }
            let focused = alpha(focusLeft ? 28 : 92, 0)
            let other = alpha(focusLeft ? 92 : 28, 0)
            #expect(focused > other && other > 0)
            #expect((image.colorAt(x: (focusLeft ? 28 : 92) * 2, y: 3)?.alphaComponent ?? 0) > 0
                    && (image.colorAt(x: (focusLeft ? 92 : 28) * 2, y: 3)?.alphaComponent ?? 1) == 0,
                    "Only the focused edge extends to two points")
            #expect(alpha(28, 2) == 0 && alpha(92, 2) == 0, "The page interior stays clear, without a separate inset ring")
            #expect(alpha(60, 0) == 0 && alpha(60, 79) == 0, "No container border may bridge the split gap")
            #expect(alpha(0, 0) == 0 && alpha(119, 0) == 0, "Each page keeps its own rounded corners")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func focusedPageEdgeRendersEveryThemeWithoutTintingInactiveBorders(_ scheme: ColorScheme) throws {
        _ = NSApplication.shared
        func sample(_ theme: WindowTheme, focused: Bool) throws -> NSColor {
            let content = Color.clear.frame(width: 80, height: 64)
                .modifier(BrowserContentSurface.pane(cornerRadius: 10, split: true, focused: focused, theme: theme))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            // Normalize into an explicit sRGB bitmap so numeric comparisons
            // don't depend on NSColor's host-display/device color conversions.
            let image = try #require(renderer.cgImage)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let offset = 80 * 4, alpha = Double(bytes[offset + 3]) / 255
            func channel(_ index: Int) -> Double { alpha > 0 ? Double(bytes[offset + index]) / 255 / alpha : 0 }
            return NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: alpha)
        }
        let neutral = try sample(.space(.gray), focused: false)
        for theme in BrowserSpace.Color.allCases.map(WindowTheme.space) + [.privateBrowsing] {
            let edge = try sample(theme, focused: true)
            let expected = theme.focusBorder(isDark: scheme == .dark)
            #expect(abs(edge.redComponent - expected.red) < 0.01)
            #expect(abs(edge.greenComponent - expected.green) < 0.01)
            #expect(abs(edge.blueComponent - expected.blue) < 0.01)
            #expect(edge.alphaComponent > 0.99)
            let inactive = try sample(theme, focused: false)
            #expect(abs(inactive.redComponent - neutral.redComponent) < 0.001)
            #expect(abs(inactive.greenComponent - neutral.greenComponent) < 0.001)
            #expect(abs(inactive.blueComponent - neutral.blueComponent) < 0.001)
            #expect(inactive.alphaComponent == neutral.alphaComponent)
        }
    }

    @Test func inactiveSplitMemberActionsManageTheirOwnGroupNotTheVisiblePair() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let first = try #require(model.coordinator.activeSplitGroup)
        #expect(model.perform(.selectTab(fixture.tabs[2].id)))
        #expect(model.perform(.splitTab(fixture.tabs[3].id, .trailing)))
        let visible = try #require(model.coordinator.activeSplitGroup), focus = model.coordinator.focusedTabID
        #expect(model.splitGroup(containing: fixture.tabs[0].id) == first)
        #expect(!model.canPerform(.splitTab(fixture.tabs[0].id, .leading)))
        #expect(model.perform(.swapSplit(first.id)))
        #expect(model.coordinator.activeSplitGroup == visible && model.coordinator.focusedTabID == focus)
        #expect(model.splitGroup(containing: fixture.tabs[0].id)?.panes == Array(first.panes.reversed()))
        #expect(model.perform(.exitSplit(first.id)))
        #expect(model.coordinator.activeSplitGroup == visible && model.coordinator.focusedTabID == focus)
        #expect(model.coordinator.splitGroups.count == 1 && model.webViews.creationCount == 4)
    }

    @Test func sidebarResizeEdgeIsOneNativeViewOverTheVisiblePageOutline() async throws {
        let fixture = Fixture(), model = fixture.model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(BrowserWindowView(model: model).transaction { $0.disablesAnimations = true }))
        window.contentView = hosting
        hosting.frame.size = CGSize(width: 800, height: 600)
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            fixture.cleanup()
        }
        func edges(in view: NSView) -> [SidebarResizeEdge.EdgeView] {
            ((view as? SidebarResizeEdge.EdgeView).map { [$0] } ?? []) + view.subviews.flatMap { edges(in: $0) }
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        let found = edges(in: hosting)
        #expect(found.count == 1, "Exactly one resize element")
        let edge = try #require(found.first)
        // Pinned sidebar: the page outline starts after its 6 pt gap, so the
        // 12 pt area spans 3 pt inside the sidebar through 2 pt past the outline.
        let frame = edge.convert(edge.bounds, to: nil)
        let windowInset: CGFloat = 6 // BrowserWindowView's frame around sidebar and page.
        let sidebarTrailing = windowInset + CGFloat(model.sidebarWidth)
        let outline = sidebarTrailing + 6
        #expect(abs(frame.minX - (sidebarTrailing - 3)) < 0.5 && abs(frame.width - 12) < 0.5, "Edge frame: \(frame)")
        #expect(frame.minX < outline && frame.maxX >= outline + 1, "The outline is inside the grab area: \(frame)")
        #expect(abs(frame.minY - windowInset) < 0.5 && frame.height > 500, "Full-height grab area: \(frame)")
    }

    @Test(arguments: [false, true])
    func freshDragSplitEnablesDividerWhenSidebarDragEndsWithoutASwap(animationsEnabled: Bool) async throws {
        let fixture = Fixture(), model = fixture.model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(BrowserWindowView(model: model).transaction { $0.disablesAnimations = !animationsEnabled }))
        window.contentView = hosting
        hosting.frame.size = CGSize(width: 800, height: 600)
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            fixture.cleanup()
        }
        func divider(in view: NSView) -> SplitDividerView? {
            (view as? SplitDividerView) ?? view.subviews.lazy.compactMap { divider(in: $0) }.first
        }
        func layout() {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
        }
        layout()
        model.sidebarInteractionInProgress = true
        model.updateSplitPreview(for: fixture.tabs[1].id, at: right, in: bounds)
        layout()
        #expect(model.commitSplitPreview())
        let group = try #require(model.coordinator.activeSplitGroup)
        layout()
        let native = try #require(divider(in: hosting))
        #expect(!native.isAccessibilityEnabled(), "Still blocked while the sidebar owns the drag")
        // This is the last state change made by endDrag(). No swap, focus or
        // ratio mutation may be needed to refresh the native control afterward.
        model.sidebarInteractionInProgress = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !native.isAccessibilityEnabled(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            layout()
        }
        try #require(native.isAccessibilityEnabled(), "A new split must be immediately resizable without swapping")
        try await Task.sleep(for: .milliseconds(350))
        layout()
        #expect(divider(in: hosting) === native)
        native.resetCursorRects()
        #expect(native.resizeCursorRect?.isEmpty == false)
        let center = CGPoint(x: native.bounds.midX, y: native.bounds.midY)
        let hit = hosting.hitTest(try #require(hosting.superview).convert(center, from: native))
        #expect(hit === native, "The new divider must own its native hit region")
        let saves = fixture.saves
        native.beginResize(atWindowX: 400)
        try #require(model.splitResize?.groupID == group.id)
        layout()
        native.updateResize(atWindowX: 450)
        layout()
        let fraction = try #require(model.splitResize?.fraction)
        #expect(fraction > group.leadingFraction && fixture.saves == saves)
        native.endResize(commit: true)
        #expect(model.coordinator.activeSplitGroup?.leadingFraction == fraction)
        #expect(fixture.saves == saves + 1 && model.splitResize == nil)
        layout()
        #expect(native.isAccessibilityEnabled() && !window.isVisible)
    }

    @Test func dividerTrackingFollowsItsFirstAssignedFrameWithoutASwapOrReconfigure() throws {
        _ = NSApplication.shared
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let divider = SplitDividerView(frame: .zero)
        container.addSubview(divider)
        defer { divider.invalidate() }
        divider.configure(groupID: UUID(), layout: BrowserSplitLayout(size: container.bounds.size, leadingFraction: 0.5),
                          enabled: true, resizing: false, increasedContrast: false)
        // Native representables are configured before SwiftUI assigns their
        // first real frame. The initial tracking area is consequently empty.
        divider.updateTrackingAreas()
        divider.frame = CGRect(x: 394, y: 0, width: 12, height: 600)
        divider.needsLayout = true
        divider.layoutSubtreeIfNeeded()
        let area = try #require(divider.trackingAreas.first)
        let tracked = area.options.contains(.inVisibleRect) ? divider.bounds.intersection(divider.visibleRect) : area.rect
        #expect(tracked == divider.bounds, "First layout must replace the empty native hover/cursor area")
        #expect(tracked.width == 12 && tracked.height == 600)
        // The same area must follow another resize without any model update.
        divider.frame.size.height = 400
        let resized = area.options.contains(.inVisibleRect) ? divider.bounds.intersection(divider.visibleRect) : area.rect
        #expect(resized.height == 400)
    }

    @Test func successfulPagesRefreshDividerAvailabilityWithoutNavigationOrLayoutNudges() async throws {
        let fixture = Fixture(servePages: true), model = fixture.model
        #expect(model.perform(.selectTab(fixture.tabs[1].id)))
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.webViews.pages.values.contains(where: { $0.isLoading || $0.view.title != "Ready" }), ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.webViews.pages.count == 2 && model.webViews.pages.values.allSatisfy { $0.view.title == "Ready" && $0.failure == nil })
        #expect(model.perform(.selectTab(fixture.tabs[0].id)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(SplitContentView(model: model).transaction { $0.disablesAnimations = true }))
        window.contentView = hosting
        hosting.frame.size = CGSize(width: 800, height: 600)
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            fixture.cleanup()
        }
        func divider(in view: NSView) -> SplitDividerView? {
            (view as? SplitDividerView) ?? view.subviews.lazy.compactMap { divider(in: $0) }.first
        }
        hosting.layoutSubtreeIfNeeded()
        model.sidebarInteractionInProgress = true
        model.updateSplitPreview(for: fixture.tabs[1].id, at: right, in: bounds)
        #expect(model.commitSplitPreview())
        hosting.layoutSubtreeIfNeeded()
        let native = try #require(divider(in: hosting))
        #expect(!native.isAccessibilityEnabled())
        model.sidebarInteractionInProgress = false
        // Do not set needsLayout, swap or select a tab to force a refresh. The
        // native representable's observed inputs must invalidate it themselves.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !native.isAccessibilityEnabled(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
        }
        try #require(native.isAccessibilityEnabled(), "Successful pages must not leave the freshly mounted divider disabled")
        native.beginResize(atWindowX: 400)
        try #require(model.splitResize != nil)
        native.endResize(commit: false)
        #expect(model.webViews.creationCount == 2 && !window.isVisible)
    }

    @Test func nativeDividerUsesCurrentWindowGateBeforeAnyRenderOrNavigationRefresh() throws {
        let fixture = Fixture(), model = fixture.model
        defer { fixture.cleanup() }
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let group = try #require(model.coordinator.activeSplitGroup)
        let native = SplitDividerView(frame: CGRect(x: 0, y: 0, width: 12, height: 600))
        defer { native.invalidate() }
        let layout = BrowserSplitLayout(size: CGSize(width: 800, height: 600), leadingFraction: 0.5)
        model.sidebarInteractionInProgress = true
        native.configure(groupID: group.id, layout: layout, enabled: false, resizing: false, increasedContrast: false)
        native.canInteract = { model.splitResize?.groupID == group.id || model.canPerform(.resizeSplit(group.id, 0.5)) }
        native.onBegin = { model.beginSplitResize(group.id); return model.splitResize?.groupID == group.id }
        native.onResize = { model.updateSplitResize($0) }
        native.onEnd = { model.finishSplitResize(commit: $0) }
        #expect(!native.acceptsFirstResponder && !native.isAccessibilityEnabled())
        // No configure/layout/tab-switch call between clearing the drag and
        // interacting: the native control still holds its disabled snapshot.
        model.sidebarInteractionInProgress = false
        #expect(native.acceptsFirstResponder && native.isAccessibilityEnabled())
        native.beginResize(atWindowX: 400)
        try #require(model.splitResize?.groupID == group.id)
        native.updateResize(atWindowX: 450)
        #expect((model.splitResize?.fraction ?? 0) > 0.5)
        native.endResize(commit: false)
        #expect(model.splitResize == nil)
        // The inverse matters too: an outdated enabled snapshot must not allow
        // resizing through a modal editor or after leaving this split.
        native.configure(groupID: group.id, layout: layout, enabled: true, resizing: false, increasedContrast: false)
        model.folderEditorIsPresented = true
        #expect(!native.acceptsFirstResponder)
        native.beginResize(atWindowX: 400)
        #expect(model.splitResize == nil)
        model.folderEditorIsPresented = false
        #expect(model.perform(.selectTab(fixture.tabs[2].id)))
        #expect(!native.isAccessibilityEnabled())
        #expect(model.perform(.selectTab(fixture.tabs[0].id)))
        #expect(native.isAccessibilityEnabled())
    }

    @Test func splitTargetsAndFocusFollowActiveThemeAndKeepRoundedInsetBorders() throws {
        let fixture = Fixture(), model = fixture.model
        defer { fixture.cleanup() }
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let pages = model.webViews.pages, focus = model.coordinator.focusedTabID
        for theme in BrowserSpace.Color.allCases {
            #expect(model.editSpace(model.coordinator.activeSpaceID, name: "Theme", color: theme, icon: nil))
            #expect(model.chromeTheme == .space(theme))
        }
        model.preferences.spaceThemes = false
        #expect(model.chromeTheme == .space(.gray) && !model.tintsChrome)
        model.preferences.spaceThemes = true
        #expect(model.chromeTheme == .space(.green) && model.tintsChrome)
        #expect(model.coordinator.focusedTabID == focus && model.webViews.creationCount == 2)
        for (id, page) in pages { #expect(model.webViews.pages[id] === page) }
        #expect(SplitDropCard.shape.cornerSize == CGSize(width: 18, height: 18))
        let inner = CGRect(x: 0, y: 0, width: 224, height: 420).insetBy(dx: SplitDropCard.borderInset, dy: SplitDropCard.borderInset)
        let path = SplitDropCard.shape.path(in: inner)
        #expect(!path.contains(CGPoint(x: inner.minX + 3, y: inner.minY + 3)))
        #expect(path.contains(CGPoint(x: inner.midX, y: inner.minY + 2)))
        #expect(path.contains(CGPoint(x: inner.midX, y: inner.midY)))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func splitCardBackgroundActuallyRendersItsThemeInBothAppearances(_ scheme: ColorScheme) throws {
        _ = NSApplication.shared
        func sample(_ theme: WindowTheme) throws -> NSColor {
            let card = SplitDropCard(theme: theme, side: .leading, highlighted: true, title: "Add left split",
                                     size: CGSize(width: 224, height: 420), allowsTransparency: false)
                .frame(width: 224, height: 420).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 1
            let data = try #require(renderer.nsImage?.tiffRepresentation)
            let pixels = try #require(NSBitmapImageRep(data: data))
            #expect((pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01, "Outer card corners stay rounded")
            return try #require(pixels.colorAt(x: 35, y: 60)?.usingColorSpace(.deviceRGB))
        }
        let red = try sample(.space(.red)), blue = try sample(.space(.blue))
        #expect(red.redComponent > red.blueComponent + 0.04)
        #expect(blue.blueComponent > blue.redComponent + 0.04)
        // The private gray is the same mid-light gray in either appearance.
        let gray = try sample(.privateBrowsing)
        #expect(abs(gray.redComponent - gray.blueComponent) < 0.05 && abs(gray.redComponent - gray.greenComponent) < 0.05)
        #expect((0.5...0.8).contains(gray.greenComponent))
    }

    @Test func eitherVisibleDialogBlocksSplitFocusAndPreviewAndForeignWindowStaysUntouched() throws {
        let first = Fixture(), second = Fixture()
        defer { first.cleanup(); second.cleanup() }
        let model = first.model, other = second.model.coordinator.session
        #expect(model.perform(.splitTab(first.tabs[1].id, .trailing)))
        let group = try #require(model.coordinator.activeSplitGroup)
        model.webViews.pages[first.tabs[0].id]?.hasDialog = true
        #expect(model.hasVisibleDialog && !model.canPerform(.focusSplitPane(group.panes[0].id)))
        #expect(!model.canManageSpaces)
        model.updateSplitPreview(for: first.tabs[2].id, at: right, in: bounds)
        #expect(model.splitPreview == nil)
        model.webViews.pages[first.tabs[0].id]?.hasDialog = false
        #expect(!model.canPerform(.splitTab(second.tabs[0].id, .leading)))
        #expect(second.model.coordinator.session == other && second.model.webViews.creationCount == 1)
    }

    @Test func splitCommandsRequireExplicitSplitIntentInsteadOfCrowdingTabSearch() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.perform(.presentCommandBar(.commandSearch)))
        model.updateQuery("Page 1")
        #expect(!model.commandSearchCandidates().contains { $0.id.hasPrefix("action.split") })
        model.updateQuery("split right Page 1")
        #expect(model.commandSearchCandidates().contains { $0.target == .action(.splitTab(fixture.tabs[1].id, .trailing)) })
        model.commandBarActionsEnabled = false
        #expect(!model.commandSearchCandidates().contains { $0.id.hasPrefix("action.split") })
    }

    @Test func windowNotificationsCancelOnlyTheirOwnTransientInteractionAndDetachCleanly() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let monitor = BrowserWindowActivityMonitor.MonitorView()
        var cancellations = 0
        monitor.onCancel = { cancellations += 1 }
        try #require(window.contentView).addSubview(monitor)
        defer { monitor.stop(); window.close(); other.close() }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: other)
        #expect(cancellations == 0)
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.willEnterFullScreenNotification] {
            NotificationCenter.default.post(name: name, object: window)
        }
        #expect(cancellations == 4)
        monitor.stop()
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(cancellations == 4 && !window.isVisible && !other.isVisible)
        #expect(monitor.hitTest(.zero) == nil && !monitor.isAccessibilityElement())
    }

    @Test(arguments: [false, true])
    func rendererRetainsHostsAcrossSplitResizeAndPreviewWithoutShowingAWindow(fullWindow: Bool) async throws {
        let fixture = Fixture()
        let model = fixture.model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Offscreen geometry assertions use an animation-disabled transaction;
        // the real view reads the system's read-only Reduce Motion environment.
        let root = fullWindow ? AnyView(BrowserWindowView(model: model)) : AnyView(SplitContentView(model: model))
        let hosting = NSHostingView(rootView: AnyView(root.transaction { $0.disablesAnimations = true }))
        window.contentView = hosting
        hosting.frame.size = CGSize(width: 800, height: 600)
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            fixture.cleanup()
        }
        func hosts() -> [WebContentView.HostView] {
            func collect(_ view: NSView) -> [WebContentView.HostView] {
                (view as? WebContentView.HostView).map { [$0] } ?? view.subviews.flatMap(collect)
            }
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            return collect(hosting)
        }
        func waitForHosts(_ count: Int) async throws -> [WebContentView.HostView] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                let result = hosts()
                if result.count == count { return result }
                guard ContinuousClock.now < deadline else { throw LayoutFailure.timeout }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let originalHost = try #require(try await waitForHosts(1).first)
        let originalView = try #require(originalHost.hosted)
        let originalFrame = hosting.convert(originalHost.bounds, from: originalHost)
        #expect(originalHost.containsPageView(originalView))
        #expect(!originalHost.containsPageView(hosting))
        #expect(!originalHost.containsPageView(NSButton()))
        #expect(!originalHost.containsPageView(nil))
        // Both cards can appear, highlight and change sides without moving,
        // shrinking, hiding, rehosting or snapshotting the current live page.
        let localBounds = CGRect(origin: .zero, size: hosting.bounds.size)
        let targets = try #require(BrowserSplitDropTargets(in: localBounds))
        model.sidebarInteractionInProgress = true
        for point in [CGPoint(x: localBounds.minX + 1, y: localBounds.midY),
                      CGPoint(x: targets.leading.midX, y: targets.leading.midY),
                      CGPoint(x: targets.trailing.midX, y: targets.trailing.midY),
                      CGPoint(x: localBounds.midX, y: localBounds.midY)] {
            model.updateSplitPreview(for: fixture.tabs[1].id, at: point, in: localBounds)
            _ = hosts()
            #expect(model.splitDropSourceID == fixture.tabs[1].id)
            #expect(hosting.convert(originalHost.bounds, from: originalHost) == originalFrame)
            #expect(originalHost.hosted === originalView && originalHost.alphaValue == 1)
            #expect(hosts().count == 1 && model.webViews.creationCount == 1)
            #expect(model.webViews.snapshots.pendingCount == 0)
        }
        model.cancelSplitPreview()
        model.sidebarInteractionInProgress = false
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let splitHosts = try await waitForHosts(2)
        #expect(splitHosts.contains { $0 === originalHost && $0.hosted === originalView })
        let group = try #require(model.coordinator.activeSplitGroup)
        #expect(model.perform(.resizeSplit(group.id, 0.7)))
        _ = hosts()
        #expect(hosts().contains { $0 === originalHost && $0.hosted === originalView })
        let created = model.webViews.creationCount
        #expect(model.perform(.swapSplit(group.id)))
        _ = hosts()
        #expect(hosts().contains { $0 === originalHost && $0.hosted === originalView })
        let otherHost = try #require(hosts().first { $0 !== originalHost })
        #expect(hosting.convert(originalHost.bounds, from: originalHost).midX > hosting.convert(otherHost.bounds, from: otherHost).midX)
        let splitFrames = Dictionary(uniqueKeysWithValues: hosts().map { (ObjectIdentifier($0), hosting.convert($0.bounds, from: $0)) })
        model.sidebarInteractionInProgress = true
        model.updateSplitPreview(for: fixture.tabs[2].id, at: right, in: bounds)
        _ = hosts()
        #expect(hosts().count == 2 && model.webViews.creationCount == created)
        for host in hosts() {
            #expect(hosting.convert(host.bounds, from: host) == splitFrames[ObjectIdentifier(host)])
            #expect(host.alphaValue == 1)
        }
        #expect(model.webViews.pages[fixture.tabs[2].id] == nil)
        model.cancelSplitPreview()
        model.sidebarInteractionInProgress = false
        #expect(model.perform(.removeSplitPane(group.panes[1].id)))
        let remainingHost = try #require(try await waitForHosts(1).first)
        #expect(remainingHost === originalHost && remainingHost.hosted === originalView)
        #expect(hosting.convert(originalHost.bounds, from: originalHost) == originalFrame)
        #expect(model.webViews.creationCount == created)
        #expect(!window.isVisible)
    }

    @Test(arguments: [false, true])
    func rapidSpaceHandoffsReusePagesAndSharedFavoritesWithoutBlankHosts(disableAnimations: Bool) async throws {
        let fixture = Fixture(servePages: true), model = fixture.model
        let originalSpace = model.coordinator.activeSpaceID
        let otherSpace = try #require(model.createSpace(name: "Other"))
        let emptySpace = try #require(model.createSpace(name: "Empty"))
        #expect(model.moveTab(fixture.tabs[1].id, toSpace: otherSpace))
        let otherPage = try #require(model.activePage)
        #expect(model.switchSpace(to: originalSpace))
        let originalPage = try #require(model.activePage)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(SplitContentView(model: model)
            .transaction { if disableAnimations { $0.disablesAnimations = true } }))
        window.contentView = hosting
        hosting.frame.size = CGSize(width: 800, height: 600)
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            fixture.cleanup()
        }
        func hosts() -> [WebContentView.HostView] {
            func collect(_ view: NSView) -> [WebContentView.HostView] {
                (view as? WebContentView.HostView).map { [$0] } ?? view.subviews.flatMap(collect)
            }
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            return collect(hosting)
        }
        func waitForHosts(_ count: Int) async throws -> [WebContentView.HostView] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                let result = hosts()
                if result.count == count && result.allSatisfy({ $0.hosted != nil }) { return result }
                guard ContinuousClock.now < deadline else { throw LayoutFailure.timeout }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        _ = try await waitForHosts(1)
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while originalPage.view.title != "Ready" || otherPage.view.title != "Ready" {
            guard ContinuousClock.now < readyDeadline else { throw LayoutFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        for page in [originalPage, otherPage] {
            _ = try await page.view.evaluateJavaScript("window.spaceIdentity = 'keep document'; document.getElementById('saved').value = 'keep form'; true")
        }
        // Re-enter before the previous transition has finished. A new
        // host must never be left empty because an outgoing host still owns it.
        for space in [otherSpace, originalSpace, otherSpace, originalSpace] {
            #expect(model.switchSpace(to: space))
            #expect(model.coordinator.activeSpaceID == space, "Direct Space selection must commit synchronously, without waiting for the fade")
            _ = hosts()
            try await Task.sleep(for: .milliseconds(15))
        }
        let returned = try #require(try await waitForHosts(1).first)
        #expect(returned.hosted === originalPage.view)
        #expect(originalPage.view.frame == returned.bounds)
        #expect(model.webViews.creationCount == 2)
        for page in [originalPage, otherPage] {
            #expect(try await page.view.evaluateJavaScript("window.spaceIdentity") as? String == "keep document")
            #expect(try await page.view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep form")
        }
        #expect(model.switchSpace(to: emptySpace))
        _ = try await waitForHosts(0)
        #expect(model.activePage == nil && model.webViews.creationCount == 2)
        #expect(originalPage.view.bounds.width > 0 && otherPage.view.bounds.width > 0)
        #expect(model.switchSpace(to: originalSpace))
        _ = try await waitForHosts(1)

        // The same Favorite selected in two Spaces has no page handoff at all.
        #expect(model.perform(.setFavorite(fixture.tabs[0].id, true)))
        #expect(model.switchSpace(to: otherSpace))
        #expect(model.perform(.selectTab(fixture.tabs[0].id)))
        let favoriteHost = try #require(try await waitForHosts(1).first)
        #expect(model.switchSpace(to: originalSpace))
        let unchanged = try #require(try await waitForHosts(1).first)
        #expect(unchanged === favoriteHost && unchanged.hosted === originalPage.view)
        #expect(model.webViews.creationCount == 2 && !window.isVisible)
    }

    @Test func spaceSwitchPresentationKeepsSuccessfulHandoffsShortWithoutRushingCancellation() {
        // A deterministic animation contract, not a hardware-dependent speed
        // benchmark: no wall-clock threshold is asserted by this test.
        #expect(SpaceSwitchMotion.contentDuration > 0 && SpaceSwitchMotion.contentDuration <= 0.08)
        #expect(SpaceSwitchMotion.navigationSettleDuration > 0 && SpaceSwitchMotion.navigationSettleDuration <= 0.08)
        #expect(SpaceSwitchMotion.contentDuration + SpaceSwitchMotion.navigationSettleDuration <= 0.16)
        #expect(SpaceSwitchMotion.cancellationSettleDuration == 0.18)
    }

    private struct SpaceChangeTransactionProbe: View {
        final class Recorder { var swipeCommits: [Bool] = [] }
        let model: BrowserWindowModel
        let recorder: Recorder
        var body: some View {
            Text(model.coordinator.activeSpaceID.uuidString).transaction(value: model.coordinator.activeSpaceID) {
                recorder.swipeCommits.append($0.isSpaceSwipeCommit)
            }
        }
    }

    @Test func swipeCommitsDoNotReplayTheFooterIndicatorWhileDirectSwitchesAnimate() async throws {
        let indicator = Animation.easeInOut(duration: SpaceSwitchMotion.indicatorDuration)
        var marked = Transaction(animation: indicator)
        marked.isSpaceSwipeCommit = true
        SpaceSwitchMotion.applyIndicatorPolicy(to: &marked)
        var direct = Transaction(animation: indicator)
        SpaceSwitchMotion.applyIndicatorPolicy(to: &direct)
        #expect(marked.animation == nil && direct.animation == indicator)

        // The real settled swipe must deliver its Space change in that marked
        // transaction; an ordinary dot/menu/keyboard switch must not.
        let fixture = Fixture(), model = fixture.model
        let recorder = SpaceChangeTransactionProbe.Recorder()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(SpaceChangeTransactionProbe(model: model, recorder: recorder)))
        window.contentView = hosting
        hosting.frame.size = CGSize(width: 200, height: 100)
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            fixture.cleanup()
        }
        func waitForChange(to space: UUID) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while model.coordinator.activeSpaceID != space || recorder.swipeCommits.isEmpty {
                guard ContinuousClock.now < deadline else { throw LayoutFailure.timeout }
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let next = try #require(model.createSpace(name: "Next"))
        let last = try #require(model.createSpace(name: "Last"))
        hosting.layoutSubtreeIfNeeded()
        recorder.swipeCommits.removeAll()

        model.updateSpaceSwipe(translation: -120)
        model.finishSpaceSwipe(.next)
        try await waitForChange(to: next)
        #expect(recorder.swipeCommits.allSatisfy { $0 })
        #expect(!model.spaceSwipeIsSettling && model.spaceSwipeProgress == 0)

        recorder.swipeCommits.removeAll()
        #expect(model.switchSpace(to: last))
        try await waitForChange(to: last)
        #expect(!recorder.swipeCommits.contains(true))
        #expect(!window.isVisible)
    }

    @Test func settledSpaceSwipesCommitOnceAndCanceledSwipesCannotReplaceANewerSelection() async throws {
        let fixture = Fixture(), model = fixture.model
        defer { fixture.cleanup() }
        let next = try #require(model.createSpace(name: "Next"))
        let empty = try #require(model.createSpace(name: "Empty"))
        model.finishSpaceSwipe(.next)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.coordinator.activeSpaceID != next {
            guard ContinuousClock.now < deadline else { throw LayoutFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.spaceSwipeIsSettling && model.spaceSwipeProgress == 0)
        #expect(model.activePage == nil && model.webViews.creationCount == 1)
        model.finishSpaceSwipe(.previous)
        #expect(model.switchSpace(to: empty)) // Cancels any unfinished settle.
        try await Task.sleep(for: .milliseconds(220))
        #expect(model.coordinator.activeSpaceID == empty)
        #expect(!model.spaceSwipeIsSettling && model.spaceSwipeProgress == 0)
        #expect(model.activePage == nil && model.webViews.creationCount == 1)
    }

    @Test func nativePageHandoffPreservesItsViewportUntilTheNewHostHasARealSize() {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let original = WebContentView.HostView(frame: page.frame)
        #expect(original.display(page))
        let previousFrame = page.frame
        original.invalidate()
        let destination = WebContentView.HostView(frame: .zero)
        defer { destination.invalidate() }
        #expect(destination.display(page))
        #expect(page.frame == previousFrame, "Attaching to an unlaid-out host must not collapse a warm page to zero")
        destination.setFrameSize(CGSize(width: 700, height: 500))
        #expect(page.frame == destination.bounds)
        destination.setBoundsSize(.zero)
        #expect(page.frame.size == CGSize(width: 700, height: 500))
        destination.setBoundsSize(CGSize(width: 500, height: 400))
        #expect(page.frame == destination.bounds)
    }

    @Test func nativePageIsSizedBeforeItJoinsItsNewHost() {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let page = AttachmentRecordingWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let host = WebContentView.HostView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        defer { host.invalidate() }
        #expect(host.display(page))
        #expect(page.arrivalFrames.last == host.bounds,
                "WebKit must see its final viewport when attachment makes the page drawable")
    }

    @Test func nativePageHostClipsAndResizesImmediatelyAndBalancesLiveResize() {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let first = ResizeRecordingWebView(frame: .zero, configuration: config)
        let second = ResizeRecordingWebView(frame: .zero, configuration: config)
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let host = WebContentView.HostView(frame: CGRect(x: 20, y: 20, width: 400, height: 600))
        parent.addSubview(host)
        defer { host.invalidate() }
        host.setLiveResize(true) // A request before a page is attached is safe.
        #expect(host.display(first))
        #expect(first.resizeStarts == 1 && first.resizeEnds == 0)
        #expect(host.clipsToBounds && host.isFlipped && !host.autoresizesSubviews)
        #expect(host.visibleRect == host.bounds)
        for size in [CGSize(width: 650, height: 480), .zero, CGSize(width: 200, height: 700), CGSize(width: 800, height: 600)] {
            let previousFrame = first.frame
            host.setFrameSize(size)
            // Assert before another run-loop/layout pass: there must not be an
            // old-sized child behind a newly positioned pane boundary.
            if size == .zero {
                #expect(first.frame == previousFrame, "A transient empty host must not collapse the page viewport")
                #expect(host.visibleRect.isEmpty, "The clipped zero-sized host must not expose its retained page")
            } else {
                #expect(first.frame == host.bounds && first.bounds.size == size)
            }
            host.setLiveResize(true)
            #expect(host.display(first))
        }
        #expect(first.resizeStarts == 1 && first.resizeEnds == 0)
        host.setBoundsSize(CGSize(width: 500, height: 400))
        #expect(first.frame == host.bounds)
        // Element fullscreen reparents the page. Native layout must not resize
        // a view that now belongs to another container.
        let fullscreenOwner = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        first.removeFromSuperview()
        fullscreenOwner.addSubview(first)
        let fullscreenFrame = first.frame
        host.setFrameSize(CGSize(width: 300, height: 500))
        #expect(first.frame == fullscreenFrame && first.superview === fullscreenOwner)
        #expect(host.display(second))
        #expect(first.resizeStarts == 1 && first.resizeEnds == 1)
        #expect(second.resizeStarts == 1 && second.resizeEnds == 0)
        #expect(second.frame == host.bounds)
        host.setLiveResize(false)
        host.setLiveResize(false)
        #expect(second.resizeEnds == 1)
        host.setLiveResize(true)
        #expect(second.resizeStarts == 2)
        host.invalidate() // Cancellation/teardown must always end live resize.
        host.setLiveResize(true)
        #expect(second.resizeEnds == 2 && !host.display(second))
        #expect(first.superview === fullscreenOwner)
    }

    @Test func nativePageHostBackgroundFollowsOnlyItsCurrentPage() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let first = WKWebView(frame: .zero, configuration: config)
        let second = WKWebView(frame: .zero, configuration: config)
        let host = WebContentView.HostView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        defer { host.invalidate() }
        first.underPageBackgroundColor = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        #expect(host.display(first))
        #expect(host.layer?.backgroundColor == first.underPageBackgroundColor.cgColor)
        first.underPageBackgroundColor = NSColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while host.layer?.backgroundColor != first.underPageBackgroundColor.cgColor, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.layer?.backgroundColor == first.underPageBackgroundColor.cgColor)
        // Queue an old page notification, then replace it before that task can
        // run. Neither it nor future notifications may recolor the new page.
        first.underPageBackgroundColor = .red
        second.underPageBackgroundColor = NSColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1)
        #expect(host.display(second))
        await Task.yield()
        #expect(host.layer?.backgroundColor == second.underPageBackgroundColor.cgColor)
        #expect(host.display(nil))
        first.underPageBackgroundColor = .blue
        second.underPageBackgroundColor = .blue
        await Task.yield()
        #expect(host.layer?.backgroundColor == nil)
    }

    @Test func liveSplitResizeKeepsNativeAndDOMViewportsAligned() async throws {
        let fixture = Fixture(servePages: true), model = fixture.model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(SplitContentView(model: model)))
        window.contentView = hosting
        hosting.frame.size = CGSize(width: 800, height: 600)
        defer {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
            fixture.cleanup()
        }
        func hosts(in view: NSView) -> [WebContentView.HostView] {
            (view as? WebContentView.HostView).map { [$0] } ?? view.subviews.flatMap { hosts(in: $0) }
        }
        func layout() {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
        }
        func expectDOMViewport(_ view: WKWebView, in host: WebContentView.HostView) async throws {
            // WebKit's separate process applies viewport messages asynchronously.
            // Native bounds must match immediately; the DOM must converge on the
            // latest size, including after a burst of intermediate geometries.
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var viewport = -1.0
            repeat {
                viewport = try #require(try await view.evaluateJavaScript("window.innerWidth") as? Double)
                if abs(viewport - host.bounds.width) < 1 { return }
                try await Task.sleep(for: .milliseconds(10))
                layout()
            } while ContinuousClock.now < deadline
            #expect(abs(viewport - host.bounds.width) < 1, "DOM viewport must follow the latest native size: DOM \(viewport), host \(host.bounds)")
        }
        #expect(model.perform(.splitTab(fixture.tabs[1].id, .trailing)))
        let group = try #require(model.coordinator.activeSplitGroup)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (hosts(in: hosting).count != 2 || model.webViews.pages.values.contains { $0.isLoading || $0.view.title != "Ready" }), ContinuousClock.now < deadline {
            layout()
            try await Task.sleep(for: .milliseconds(20))
        }
        // Allow only the committed split insertion animation to settle. Divider
        // tracking below must resize directly, with production animations ON.
        try await Task.sleep(for: .milliseconds(300))
        layout()
        let originalHosts = hosts(in: hosting)
        try #require(originalHosts.count == 2)
        let originalViews = try originalHosts.map { try #require($0.hosted) }
        for view in originalViews {
            _ = try await view.evaluateJavaScript("window.resizeMarker = 'keep'; document.getElementById('saved').value = 'keep';")
        }
        let created = model.webViews.creationCount, saves = fixture.saves, focus = model.contentFocusRequest
        model.beginSplitResize(group.id)
        for fraction in [0.7, 0.3, 0.8, 0.2, 0.6] {
            model.updateSplitResize(fraction)
            layout()
            let expected = BrowserSplitLayout(size: hosting.bounds.size, leadingFraction: fraction)
            let currentHosts = hosts(in: hosting)
            for (index, pane) in group.panes.enumerated() {
                let view = try #require(model.webViews.pages[pane.tabID]?.view)
                let host = try #require(currentHosts.first { $0.hosted === view })
                let actual = hosting.convert(host.bounds, from: host)
                #expect(abs(actual.width - expected.frame(at: index).width) < 1, "Pane geometry must follow the live fraction")
                #expect(view.frame == host.bounds, "Native viewport must fill its host immediately: web \(view.frame), host \(host.bounds)")
                #expect(view.bounds.size == host.bounds.size)
                try await expectDOMViewport(view, in: host)
            }
        }
        model.finishSplitResize(commit: true)
        layout()
        #expect(fixture.saves == saves + 1 && model.contentFocusRequest == focus)
        // Exercise rapid changes without waiting on JavaScript/WebKit between
        // native layouts, then cancel back to the saved ratio.
        model.beginSplitResize(group.id)
        for step in 0..<40 {
            model.updateSplitResize(step.isMultiple(of: 2) ? 0.25 : 0.75)
            layout()
            for host in hosts(in: hosting) { #expect(host.hosted?.frame == host.bounds) }
        }
        model.finishSplitResize(commit: false)
        layout()
        #expect(fixture.saves == saves + 1 && model.coordinator.activeSplitGroup?.leadingFraction == 0.6)
        for size in [CGSize(width: 1100, height: 500), CGSize(width: 640, height: 720)] {
            window.setContentSize(size)
            layout()
            for host in hosts(in: hosting) {
                let view = try #require(host.hosted)
                #expect(view.frame == host.bounds)
                try await expectDOMViewport(view, in: host)
            }
        }
        #expect(model.webViews.creationCount == created)
        for (host, view) in zip(originalHosts, originalViews) {
            #expect(hosts(in: hosting).contains { $0 === host } && host.hosted === view)
            #expect(try await view.evaluateJavaScript("window.resizeMarker") as? String == "keep")
            #expect(try await view.evaluateJavaScript("document.getElementById('saved').value") as? String == "keep")
        }
        #expect(!window.isVisible)
    }

    private enum LayoutFailure: Error { case timeout }

    @Test func titlebarCompatibilityScopeDoesNotClaimUnrelatedWindows() throws {
        _ = NSApplication.shared
        let browser = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        browser.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let control = try #require(other.standardWindowButton(.closeButton)), parent = control.superview
        let host = WindowControls.ControlsHost(frame: CGRect(x: 0, y: 0, width: 60, height: 32))
        defer { host.detach(); browser.close(); other.close() }
        try #require(browser.contentView).addSubview(host)
        #expect(WindowControls.ControlsHost.ownsControls(in: browser))
        #expect(!WindowControls.ControlsHost.ownsControls(in: other))
        #expect(!WindowControls.ControlsHost.ownsControls(in: nil))
        #expect(control.superview === parent && !browser.isVisible && !other.isVisible)
        host.detach()
        #expect(!WindowControls.ControlsHost.ownsControls(in: browser))
        #expect(control.superview === parent)
    }
}
