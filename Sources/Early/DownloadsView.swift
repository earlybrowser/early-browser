// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI
import UniformTypeIdentifiers

/// The footer's left-hand control, in the active Space's theme. A clicked
/// download first flies in (see `DownloadFlightView`). When a download starts
/// (or lands) the icon grows and its arrow drops through the circle and bounces
/// back in; a ring traces the circle clockwise from zero as the transfer
/// completes; at the finish the icon bounces and shines. These run only on
/// those events; Reduce Motion uses a brief color fade instead.
struct DownloadsButton: View {
    @Bindable var model: BrowserWindowModel
    @State private var ringValue = 0.0
    @State private var ringOpacity = 1.0
    @State private var finishing = false
    @State private var scale: CGFloat = 1
    @State private var glow = 0.0
    @State private var arrowOffset: CGFloat = 0
    @State private var startGeneration = 0
    @State private var shineOffset: CGFloat = -16
    @State private var shineOpacity = 0.0
    @State private var tint = 0.0
    @State private var bounceEndsAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private static let glyphStroke = StrokeStyle(lineWidth: 1.75 * 18 / 24, lineCap: .round, lineJoin: .round)

    var body: some View {
        let store = model.downloads
        let active = store.hasActiveDownloads
        let theme = model.chromeTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        Button { model.perform(.showDownloads) } label: {
            ZStack {
                glyph(.foreground)
                glyph(theme).opacity(tint)
                DownloadGlyph()
                    .stroke(LinearGradient(colors: [theme, .white.opacity(0.95), theme], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.5),
                                               .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 11)
                            .offset(x: shineOffset)
                    }
                    .opacity(shineOpacity)
                if active || finishing {
                    // Traces the glyph's own circle, so no separate track is drawn.
                    // A steady theme glow keeps a running download easy to spot.
                    Circle()
                        .trim(from: 0, to: ringValue)
                        .stroke(theme, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(18 * 3 / 24)
                        .shadow(color: theme.opacity(DownloadRing.glowOpacity), radius: DownloadRing.glowRadius)
                        .opacity(ringOpacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: ringValue)
                }
            }
            .frame(width: 18, height: 18)
            .scaleEffect(scale)
            .shadow(color: theme.opacity(max(shineOpacity * 0.8, glow)), radius: 3)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpaceControlStyle())
        .foregroundStyle(active ? .primary : .secondary)
        .browserKeyboardFocus(cornerRadius: 6)
        .accessibilityLabel("Downloads")
        .accessibilityValue(DownloadStatus.summary(for: store))
        .accessibilityIdentifier("downloads.button")
        .help("Downloads (⌥⌘L)")
        .onChange(of: DownloadRing.Input(active: active, progress: store.activeProgress)) { _, input in
            guard !finishing else { return }
            ringValue = DownloadRing.next(current: ringValue, active: input.active, progress: input.progress)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: DownloadsButtonFrameKey.self, value: geometry.frame(in: .named("browserWindow")))
            }
        }
        .onChange(of: store.startedRevision) { started() }
        .onChange(of: model.downloadLandingRevision) { playStart() }
        .onChange(of: store.finishedRevision) { finished() }
        .popover(isPresented: $model.downloadsPresented, arrowEdge: .top) {
            DownloadsPanel(store: store, tint: theme)
                .spacePopoverBackground(model)
        }
    }

    /// The circle stays still while the arrow, clipped to the circle's inside,
    /// can leave through the bottom and fall back in from the top.
    private func glyph<S: ShapeStyle>(_ style: S) -> some View {
        ZStack {
            DownloadGlyph(part: .circle).stroke(style, style: Self.glyphStroke)
            DownloadGlyph(part: .arrow).stroke(style, style: Self.glyphStroke)
                .offset(y: arrowOffset)
                .mask { Circle().padding(DownloadArrowDrop.maskInset) }
        }
    }

    private var instant: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    private func started() {
        let latest = model.downloads.items.first
        announce(latest?.wasSaved == true ? "Saved \(latest?.filename ?? "file")" : "Download started")
        // A clicked download plays this when its flying icon lands instead.
        guard model.downloadFlight == nil else {
            bounceEndsAt = Date().addingTimeInterval(DownloadFlightPath.duration + DownloadArrowDrop.duration)
            return
        }
        playStart()
    }

    private func playStart() {
        startGeneration += 1
        let generation = startGeneration
        guard !reduceMotion else { fadeTint(); return }
        bounceEndsAt = Date().addingTimeInterval(DownloadArrowDrop.duration)
        // Grow in the theme color while the arrow drops out of the circle...
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
            scale = DownloadArrowDrop.startScale
            glow = 0.75
            tint = 1
        }
        withAnimation(.easeIn(duration: 0.16)) { arrowOffset = DownloadArrowDrop.travel }
        Task { @MainActor in
            // ...then falls back in from the top and bounces as it lands.
            try? await Task.sleep(for: .milliseconds(160))
            guard generation == startGeneration else { return }
            withTransaction(instant) { arrowOffset = -DownloadArrowDrop.travel }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.42)) { arrowOffset = 0 }
            try? await Task.sleep(for: .milliseconds(260))
            guard generation == startGeneration else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { scale = 1 }
            withAnimation(.easeOut(duration: 0.45)) {
                glow = 0
                tint = 0
            }
        }
    }

    /// The finish: a quick grow that springs back, alongside the shine.
    private func bounce() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { scale = DownloadArrowDrop.finishScale }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { scale = 1 }
        }
    }

    private func finished() {
        if model.downloads.items.first?.wasSaved != true { announce("Download finished") }
        let completesRing = !model.downloads.hasActiveDownloads
        guard !reduceMotion else {
            fadeTint()
            if completesRing { withTransaction(instant) { ringValue = 0 } }
            return
        }
        Task { @MainActor in
            // A save starts and finishes at once: let its bounce finish first.
            let wait = bounceEndsAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if completesRing {
                finishing = true
                ringValue = 1
                try? await Task.sleep(for: .milliseconds(200))
            }
            withTransaction(instant) {
                shineOffset = -16
                shineOpacity = 1
            }
            withAnimation(.easeInOut(duration: 0.5)) { shineOffset = 16 }
            bounce()
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.25)) {
                shineOpacity = 0
                if completesRing { ringOpacity = 0 }
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard completesRing else { return }
            withTransaction(instant) {
                finishing = false
                ringOpacity = 1
                ringValue = DownloadRing.next(current: 0, active: model.downloads.hasActiveDownloads,
                                              progress: model.downloads.activeProgress)
            }
        }
    }

    /// Reduce Motion: a brief theme-colored fade, with no movement.
    private func fadeTint() {
        withAnimation(.easeOut(duration: 0.2)) { tint = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeIn(duration: 0.35)) { tint = 0 }
        }
    }

    private func announce(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// The ring starts at zero for each burst of downloads and only grows. An
/// unknown total stays at zero rather than inventing progress.
enum DownloadRing {
    static let glowOpacity = 0.85
    static let glowRadius: CGFloat = 3
    struct Input: Equatable {
        let active: Bool
        let progress: Double?
    }

    static func next(current: Double, active: Bool, progress: Double?) -> Double {
        guard active else { return 0 }
        return max(current, min(1, max(0, progress ?? 0)))
    }
}

struct DownloadsButtonFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// Safari-style feedback with Early's own download icon: it arcs from the
/// clicked page point into the Downloads button, shrinking to the button's icon
/// size as it lands. A disc in the window color keeps it visible over any page.
/// Drawing only; never interactive.
struct DownloadFlightView: View {
    let flight: BrowserWindowModel.DownloadFlight
    let theme: Color
    let landed: () -> Void
    @State private var progress = 0.0

    var body: some View {
        let size = DownloadFlightPath.size
        DownloadGlyph()
            .stroke(theme, style: StrokeStyle(lineWidth: 1.75 * size / 24, lineCap: .round, lineJoin: .round))
            .background {
                Circle()
                    .fill(.background)
                    .overlay { Circle().fill(theme.opacity(0.12)) }
                    .padding(size * 3 / 24)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            }
            .frame(width: size, height: size)
            .modifier(DownloadFlightPath(progress: progress, start: flight.start, end: flight.end))
            .onAppear {
                withAnimation(.timingCurve(0.3, 0, 0.3, 1, duration: DownloadFlightPath.duration),
                              completionCriteria: .logicallyComplete) {
                    progress = 1
                } completion: {
                    landed()
                }
            }
    }
}

/// Position, scale and fade along a quadratic arc that rises above both ends.
struct DownloadFlightPath: ViewModifier, Animatable {
    nonisolated static let size: CGFloat = 34
    /// Lands at the footer icon's 18-point size.
    nonisolated static let endScale: CGFloat = 18 / size
    static let duration: TimeInterval = 0.65

    // SwiftUI interpolates this value outside the view's main-actor context.
    nonisolated var progress: Double
    let start: CGPoint
    let end: CGPoint

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    nonisolated static func point(at t: Double, start: CGPoint, end: CGPoint) -> CGPoint {
        let t = min(1, max(0, t))
        // Stays inside the window when the click is near its top.
        let control = CGPoint(x: (start.x + end.x) / 2, y: max(24, min(start.y, end.y) - 90))
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    nonisolated static func scale(at t: Double) -> Double { 1 - (1 - endScale) * min(1, max(0, t)) }
    /// Fades only at the very end, as the button's own icon takes over.
    nonisolated static func opacity(at t: Double) -> Double { t < 0.85 ? 1 : max(0, (1 - t) / 0.15) }

    func body(content: Content) -> some View {
        content
            .scaleEffect(Self.scale(at: progress))
            .opacity(Self.opacity(at: progress))
            .position(Self.point(at: progress, start: start, end: end))
    }
}

/// Start-of-download motion. The arrow travels far enough to be fully hidden by
/// the mask at both ends, and the mask sits just inside the circle's stroke, so
/// the arrow never crosses the ring.
enum DownloadArrowDrop {
    /// The 18-point icon's circle (inset 3 of 24) plus half its stroke.
    static let maskInset: CGFloat = (3 + 1.75 / 2) * 18 / 24
    static let travel: CGFloat = 11
    static let startScale: CGFloat = 1.45
    static let finishScale: CGFloat = 1.35
    static let duration: TimeInterval = 0.8
}

/// Session download list for this profile. Clearing removes rows, not files.
struct DownloadsPanel: View {
    let store: DownloadStore
    /// The Space's color, for progress and the hovered row.
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { store.clearInactive() }
                    .disabled(!store.items.contains { !$0.state.isActive })
                    .accessibilityIdentifier("downloads.clear")
                    .help("Remove finished downloads from the list")
            }
            if store.items.isEmpty {
                Text("No downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .accessibilityIdentifier("downloads.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.items) { DownloadRow(item: $0, store: store, tint: tint) }
                    }
                }
                .frame(height: min(CGFloat(store.items.count) * 52, 312))
            }
        }
        .padding(12)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.panel")
        .browserReducedMotion()
    }
}

/// A download's progress in the Space's color, as the Downloads button's
/// ring shows it. Without a known size a short segment sweeps back and
/// forth; with Reduce Motion it rests in the middle.
private struct DownloadProgressBar: View {
    let fraction: Double?
    let tint: Color
    @State private var sweeping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction {
                    Capsule().fill(tint).frame(width: max(4, width * min(max(fraction, 0), 1)))
                } else {
                    Capsule().fill(tint).frame(width: width * 0.3)
                        .offset(x: reduceMotion ? width * 0.35 : (sweeping ? width * 0.7 : 0))
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
        .onAppear {
            guard fraction == nil, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweeping = true }
        }
        .accessibilityHidden(true)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let store: DownloadStore
    let tint: Color
    @State private var hovered = false

    var body: some View {
        let exists = store.fileExists(item)
        let status = DownloadStatus.text(for: item, fileExists: exists)
        HStack(spacing: 10) {
            Image(nsImage: icon(exists: exists))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle)
                if item.state.isActive {
                    DownloadProgressBar(fraction: item.fractionCompleted, tint: tint)
                }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.filename)
            .accessibilityValue(status)
            Spacer(minLength: 4)
            if item.state.isActive {
                rowButton("xmark.circle.fill", label: "Stop download", help: "Stop") { store.stop(item) }
            } else if item.canResume || item.state == .paused {
                rowButton("arrow.clockwise.circle.fill", label: "Resume download", help: "Resume", tint: .yellow) {
                    store.resume(item)
                }
                .disabled(!item.canResume)
                rowButton("xmark.circle.fill", label: "Cancel download", help: "Cancel and delete the partial file") {
                    store.cancel(item)
                }
            } else if exists {
                rowButton("magnifyingglass.circle.fill", label: "Show in Finder", help: "Show in Finder") { store.reveal(item) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(hovered ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { store.open(item) }
        .contextMenu {
            if store.canReveal(item) { Button("Show in Finder") { store.reveal(item) } }
            if item.canResume { Button("Resume") { store.resume(item) } }
            if exists { Button("Open") { store.open(item) } }
            if let source = item.sourceURL {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
            Divider()
            if item.state.isActive {
                Button("Stop Download") { store.stop(item) }
            } else if item.canResume || item.state == .paused {
                Button("Cancel Download") { store.cancel(item) }
            }
            if !item.state.isActive { Button("Remove from List") { store.remove(item) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.item.\(item.filename)")
        .accessibilityActions {
            if exists { Button("Open") { store.open(item) } }
            if store.canReveal(item) { Button("Show in Finder") { store.reveal(item) } }
            if item.canResume { Button("Resume") { store.resume(item) } }
        }
    }

    private func rowButton(_ symbol: String, label: String, help: String, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .symbolRenderingMode(tint == nil ? .monochrome : .palette)
                .foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.black.opacity(0.75)),
                                 tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .browserKeyboardFocus(cornerRadius: 8)
        .accessibilityLabel(label)
        .help(help)
    }

    private func icon(exists: Bool) -> NSImage {
        if exists, let destination = item.destination { return NSWorkspace.shared.icon(forFile: destination.path) }
        let type = UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

@MainActor
enum DownloadStatus {
    static func text(for item: DownloadItem, fileExists: Bool) -> String {
        switch item.state {
        case .preparing:
            return "Starting…"
        case .downloading:
            if let expected = item.expectedBytes, expected > 0 {
                return "\(size(item.completedBytes)) of \(size(expected))"
            }
            return size(item.completedBytes)
        case .finished:
            guard fileExists else { return "Moved or deleted" }
            let host = item.sourceURL?.host().map { " — \($0)" } ?? ""
            return size(item.completedBytes) + host
        case .paused:
            return item.resumeData == nil ? "Stopping…" : "Resume downloading"
        case .failed:
            return item.canResume ? "Interrupted — resume to try again" : "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    static func summary(for store: DownloadStore) -> String {
        let active = store.activeCount
        if active > 0 { return active == 1 ? "1 download in progress" : "\(active) downloads in progress" }
        return store.items.isEmpty ? "No downloads" : "\(store.items.count) in list"
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
