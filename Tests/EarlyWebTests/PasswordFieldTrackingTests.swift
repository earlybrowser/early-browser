// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyWeb
import Testing
import WebKit

/// Exercise the shipping observer with access to its private bookkeeping only
/// in this local fixture. No diagnostic API is exposed by the installed script.
@Suite(.serialized) @MainActor
struct PasswordFieldTrackingTests {
    private func fixture() async throws -> WKWebView {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let script = PasswordFormObserver.script.replacingOccurrences(of: "const isInput = node =>", with: """
            globalThis.tracking = {
                tokenFor, fieldFor,
                get count() { return fields.size; },
                simulateCollectedReference(token) {
                    forget(token);
                    fields.set(token, {deref: () => undefined});
                    schedulePrune();
                }
            };
            const isInput = node =>
            """)
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: PasswordFormObserver.world))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.loadHTMLString("<form id=form><input id=user autocomplete=username><input id=pass type=password></form>", baseURL: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (try? await run("return typeof tracking !== 'undefined' && document.readyState === 'complete';", in: view)) as? Bool != true {
            guard ContinuousClock.now < deadline else { throw PageToolFixture.Failure.timeout("password tracking fixture") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return view
    }

    private func run(_ script: String, in view: WKWebView) async throws -> Any? {
        try await view.callAsyncJavaScript(script, contentWorld: PasswordFormObserver.world)
    }

    @Test func fiftyThousandReplacedFieldsDoNotAccumulateEntries() async throws {
        let view = try await fixture()
        defer { view.stopLoading() }
        let result = try await run("""
            const keeper = document.getElementById('pass'), token = tracking.tokenFor(keeper);
            let peak = 0;
            for (let i = 0; i < 50000; i++) {
                const field = document.createElement('input');
                field.type = 'password';
                document.body.append(field);
                tracking.tokenFor(field);
                peak = Math.max(peak, tracking.count);
                field.remove();
            }
            for (let i = 0; i < 100 && tracking.count !== 1; i++) await new Promise(resolve => setTimeout(resolve, 20));
            return [peak, tracking.count, tracking.fieldFor(token) === keeper];
            """, in: view) as? [Any]
        #expect((result?[0] as? Int ?? Int.max) <= 10, "Churn does not leave one Map entry per removed field")
        #expect(result?[1] as? Int == 1 && result?[2] as? Bool == true, "The connected field keeps its token")
    }

    @Test func largeRemovalsAreSweptInBatchesWithoutSweepingEveryFieldOnFocus() async throws {
        let view = try await fixture()
        defer { view.stopLoading() }
        let result = try await run("""
            const keeper = document.getElementById('pass'), token = tracking.tokenFor(keeper);
            const container = document.createElement('div');
            document.body.append(container);
            for (let i = 0; i < 2000; i++) {
                const field = document.createElement('input');
                container.append(field);
                tracking.tokenFor(field);
            }
            const before = tracking.count;
            const deref = WeakRef.prototype.deref;
            let examined = 0;
            WeakRef.prototype.deref = function() { examined++; return deref.call(this); };
            tracking.tokenFor(keeper);
            WeakRef.prototype.deref = deref;
            container.remove();
            for (let i = 0; i < 250 && tracking.count !== 1; i++) await new Promise(resolve => setTimeout(resolve, 20));
            return [before, examined, tracking.count, tracking.fieldFor(token) === keeper];
            """, in: view) as? [Any]
        #expect(result?[0] as? Int == 2001, "Connected fields are not evicted")
        #expect((result?[1] as? Int ?? Int.max) <= 8, "A new focus does bounded cleanup")
        #expect(result?[2] as? Int == 1 && result?[3] as? Bool == true, "Removal drains the remainder asynchronously")
    }

    @Test func collectedReferencesAndDetachedFieldsAreRemovedAndReinsertedFieldsCanFill() async throws {
        let view = try await fixture()
        defer { view.stopLoading() }
        let result = try await run("""
            const field = document.getElementById('pass'), token = tracking.tokenFor(field);
            // Deterministic dead WeakRef: real GC timing is not a test contract.
            tracking.simulateCollectedReference(token);
            for (let i = 0; i < 100 && tracking.count; i++) await new Promise(resolve => setTimeout(resolve, 20));
            const collected = tracking.count === 0;
            const restored = tracking.tokenFor(field) === token && tracking.fieldFor(token) === field;
            field.remove();
            const detached = tracking.fieldFor(token) === null && tracking.count === 0;
            document.getElementById('form').append(field);
            field.focus();
            const reinserted = tracking.tokenFor(field);
            const filled = __earlyPasswords.fill(reinserted, 'ada', 'synthetic-password', 'login', 'current', '', 0);
            return [collected, restored, detached, reinserted === token, filled?.username,
                    document.getElementById('user').value, field.value];
            """, in: view) as? [Any]
        #expect(result?.prefix(4).allSatisfy { $0 as? Bool == true } == true)
        #expect(result?[4] as? String == "ada" && result?[5] as? String == "ada" && result?[6] as? String == "synthetic-password")
    }

    @Test func pageHideInvalidatesOldTokensAndPageShowRestartsCleanup() async throws {
        let view = try await fixture()
        defer { view.stopLoading() }
        let result = try await run("""
            const field = document.getElementById('pass'), old = tracking.tokenFor(field);
            window.dispatchEvent(new PageTransitionEvent('pagehide', {persisted: true}));
            const cleared = tracking.count === 0 && tracking.fieldFor(old) === null;
            window.dispatchEvent(new PageTransitionEvent('pageshow', {persisted: true}));
            const token = tracking.tokenFor(field);
            const restored = token !== old && tracking.fieldFor(token) === field;
            field.remove();
            for (let i = 0; i < 100 && tracking.count; i++) await new Promise(resolve => setTimeout(resolve, 20));
            return [cleared, restored, tracking.count === 0];
            """, in: view) as? [Bool]
        #expect(result == [true, true, true])
    }
}
