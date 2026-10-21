// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
@testable import EarlyWeb
import Testing
import SwiftUI

/// Controller and unshown native-host checks only. No app launch/input synthesis.
@Suite(.serialized) @MainActor
struct SplitPresentationTests {
    @MainActor private final class Fixture {
        let suite = "local.early.tests.split.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel
        let tabs: [BrowserTab]
        var saves = 0
        var feedback = 0
        init() {
            _ = NSApplication.shared
            let profile = UUID(), space = UUID()
            tabs = (0..<4).map { BrowserTab(spaceID: space, profileID: profile, title: "Page \($0)",
                currentURL: URL(string: "early-test://fixture/one?tab=\($0)")!) }
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            defaults.set(false, forKey: "haptics")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("EarlySplit-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession,
                session: BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs, selectionBySpace: [space: tabs[0].id]),
                repository: repository, input: input, isTesting: true, restorationError: nil, defaults: defaults)
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

    @Test func rendererRetainsHostsAcrossSplitResizeAndPreviewWithoutShowingAWindow() async throws {
        let fixture = Fixture()
        let model = fixture.model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Offscreen geometry assertions use an animation-disabled transaction;
        // the real view reads the system's read-only Reduce Motion environment.
        let hosting = NSHostingView(rootView: AnyView(SplitContentView(model: model).transaction { $0.disablesAnimations = true }))
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
