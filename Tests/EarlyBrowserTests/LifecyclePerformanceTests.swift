// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import EarlyCore
@testable import EarlyWeb
@testable import EarlyBrowser
import Testing
import WebKit

/// Opt-in release benchmark, never UI automation. Output is one JSON record per
/// stage. It measures this process, not WebKit's separate content/network/GPU
/// processes, and controller/document readiness rather than a rendered window.
@Suite(.serialized) @MainActor
struct LifecyclePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARLY_LIFECYCLE_BENCHMARK"] == "1"))
    func localPageScenarios() async throws {
        let foundationStart = ContinuousClock.now
        _ = NSApplication.shared
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        try emit("environment", ["foundationInitMS": elapsed(foundationStart),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processors": ProcessInfo.processInfo.processorCount,
            "physicalMemoryMiB": Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
            "configuration": configuration,
            "scope": "headless local HTML; host process only; no rendered-window/real-site timings"])
        for count in [0, 1, 10, 50, 100] { try await scenario(count) }
    }

    private func scenario(_ count: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPerf-\(UUID())")
        let suite = "local.early.tests.performance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "onlineSearchSuggestions")
        defaults.set(false, forKey: "haptics")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let profile = UUID(), space = UUID(), pages = PerformancePages()
        let tabs = (0..<count).map { index in
            BrowserTab(spaceID: space, profileID: profile, title: "Fixture \(index)",
                currentURL: URL(string: "early-performance://fixture/page/\(index)")!)
        }
        let session = BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs,
            selectionBySpace: tabs.first.map { [space: $0.id] } ?? [:])
        let input = NavigationInput(allowedSchemes: ["early-performance"])
        let repository = SessionRepository(fileURL: directory.appendingPathComponent("session.sqlite"), input: input)
        let saveStart = ContinuousClock.now
        try await repository.save(session, revision: 1)
        let saveMS = elapsed(saveStart), readStart = ContinuousClock.now
        let restored = try #require(try await repository.load())
        let readMS = elapsed(readStart), start = ContinuousClock.now
        let model = BrowserWindowModel(startup: .returningSession, session: restored, repository: repository,
            input: input, isTesting: true, restorationError: nil, defaults: defaults,
            configureWebView: { $0.setURLSchemeHandler(pages, forURLScheme: "early-performance") })
        defer { model.cancelCommandBarQueries(); model.webViews.discardAll() }
        let startupMS = elapsed(start)
        if let first = tabs.first { try await ready(first.id, model: model) }
        try emit("startup", ["tabs": count, "controllerInitMS": startupMS, "firstDocumentReadyMS": elapsed(start),
            "webKitUse": count == 0 ? "none" : count == 1 ? "first in this test process" : "warm",
            "sessionSaveMS": saveMS, "sessionReadMS": readMS, "live": model.webViews.liveViewCount,
            "created": model.webViews.creationCount, "rssMiB": try residentMiB()])
        var loadTimes: [Double] = [], peakLive = model.webViews.liveViewCount
        for tab in tabs.dropFirst() {
            let start = ContinuousClock.now
            #expect(model.perform(.selectTab(tab.id)))
            try await ready(tab.id, model: model)
            _ = model.webViews.enforceRetention()
            loadTimes.append(elapsed(start))
            peakLive = max(peakLive, model.webViews.liveViewCount)
            #expect(model.webViews.liveViewCount <= 9)
        }
        try emit("visited", ["tabs": count, "loadMedianMS": percentile(loadTimes, 0.5),
            "loadP95MS": percentile(loadTimes, 0.95), "peakSettledLive": peakLive,
            "live": model.webViews.liveViewCount, "created": model.webViews.creationCount,
            "rssMiB": try residentMiB()])

        let retained = tabs.filter { model.webViews.pages[$0.id] != nil }
        var switchTimes: [Double] = []
        let createdBefore = model.webViews.creationCount
        for index in 0..<(retained.isEmpty ? 0 : 100) {
            let tab = retained[index % retained.count], old = model.webViews.pages[tab.id]
            let start = ContinuousClock.now
            #expect(model.perform(.selectTab(tab.id)))
            switchTimes.append(elapsed(start))
            #expect(model.webViews.pages[tab.id] === old)
        }
        #expect(model.webViews.creationCount == createdBefore)
        let before = model.webViews.workMetrics
        let bookkeepingStart = ContinuousClock.now
        for _ in 0..<500 {
            _ = model.webViews.setPresentation(visibleTabIDs: model.coordinator.visibleTabIDs,
                focusedTabID: model.coordinator.focusedTabID)
            _ = model.webViews.enforceRetention()
        }
        try emit("switching", ["tabs": count, "medianMS": percentile(switchTimes, 0.5),
            "p95MS": percentile(switchTimes, 0.95), "bookkeeping500MS": elapsed(bookkeepingStart),
            "presentationVisits": model.webViews.workMetrics.presentationVisits - before.presentationVisits,
            "protectionInspections": model.webViews.workMetrics.inspectedPages - before.inspectedPages])
        let cpu = try cpuSeconds(), idleStart = ContinuousClock.now
        let idleBefore = model.webViews.workMetrics
        try await Task.sleep(for: .seconds(2))
        let idleCPU = try cpuSeconds() - cpu
        try emit("idle", ["tabs": count, "cpuPercentOfOneCore": idleCPU / (elapsed(idleStart) / 1000) * 100,
            "rssMiB": try residentMiB(),
            "retentionPasses": model.webViews.workMetrics.retentionPasses - idleBefore.retentionPasses])

        // Each close releases its owner before another local page is opened.
        // Sample batches to expose allocator warm-up versus repeated growth.
        for tab in Array(model.coordinator.tabStore.tabs) { model.closeTab(tab.id) }
        for batch in 0..<(count == 0 ? 0 : 3) {
            for index in 0..<10 {
                let id = try #require(model.coordinator.navigate(to: URL(string:
                    "early-performance://fixture/cycle/\(batch)/\(index)")!, target: .newTab(spaceID: space)))
                model.activateSelection()
                try await ready(id, model: model)
                model.closeTab(id)
            }
            #expect(model.webViews.liveViewCount == 0 && model.webViews.lifecycles.isEmpty)
            #expect(model.webViews.snapshots.byteCount == 0)
            try emit("closedBatch", ["tabsScenario": count, "batch": batch + 1,
                "openedAndClosed": (batch + 1) * 10, "live": model.webViews.liveViewCount,
                "lifecycleRecords": model.webViews.lifecycles.count, "rssMiB": try residentMiB()])
        }
    }

    private func ready(_ id: UUID, model: BrowserWindowModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while model.webViews.pages[id]?.view.title != "Performance fixture"
            || model.webViews.pages[id]?.isLoading != false {
            guard ContinuousClock.now < deadline else { throw Failure.documentTimeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private func residentMiB() throws -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw Failure.memoryMeasurement }
        return Double(info.resident_size) / 1_048_576
    }

    private func cpuSeconds() throws -> Double {
        var value = rusage()
        guard getrusage(RUSAGE_SELF, &value) == 0 else { throw Failure.cpuMeasurement }
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }

    private func emit(_ stage: String, _ values: [String: Any]) throws {
        var record = values
        record["stage"] = stage
        print("EARLY_PERF " + String(decoding: try JSONSerialization.data(withJSONObject: record,
            options: [.sortedKeys]), as: UTF8.self))
    }

    enum Failure: Error { case documentTimeout, memoryMeasurement, cpuMeasurement }
}

@MainActor private final class PerformancePages: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let data = Data("<!doctype html><title>Performance fixture</title><main><h1>Local page</h1><p>Fixed workload.</p></main>".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
