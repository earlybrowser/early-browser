// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI
import UniformTypeIdentifiers

/// The footer's left-hand control, in the active Space's theme. A drop falls
/// into the icon when a download starts, a ring traces its circle clockwise
/// from zero as the transfer completes, and a shine marks the finish. These
/// run only on those events; Reduce Motion uses a brief color fade instead.
struct DownloadsButton: View {
    @Bindable var model: BrowserWindowModel
    @State private var ringValue = 0.0
    @State private var ringOpacity = 1.0
    @State private var finishing = false
    @State private var dropOffset: CGFloat = -12
    @State private var dropOpacity = 0.0
    @State private var rippleScale: CGFloat = 0.3
    @State private var rippleOpacity = 0.0
    @State private var shineOffset: CGFloat = -16
    @State private var shineOpacity = 0.0
    @State private var tint = 0.0
    @State private var dropEndsAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private static let glyphStroke = StrokeStyle(lineWidth: 1.75 * 18 / 24, lineCap: .round, lineJoin: .round)

    var body: some View {
        let store = model.downloads
        let active = store.hasActiveDownloads
        let theme = model.splitTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        Button { model.perform(.showDownloads) } label: {
            ZStack {
                DownloadGlyph().stroke(style: Self.glyphStroke)
                DownloadGlyph().stroke(theme, style: Self.glyphStroke).opacity(tint)
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
                    Circle()
                        .trim(from: 0, to: ringValue)
                        .stroke(theme, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(18 * 3 / 24)
                        .opacity(ringOpacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: ringValue)
                }
                Circle()
                    .stroke(theme, lineWidth: 1.25)
                    .padding(4.5)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)
                DropletShape()
                    .fill(theme)
                    .frame(width: 4.5, height: 6.5)
                    .offset(y: dropOffset)
                    .opacity(dropOpacity)
            }
            .frame(width: 18, height: 18)
            .shadow(color: theme.opacity(shineOpacity * 0.8), radius: 3)
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
        .onChange(of: store.startedRevision) { started() }
        .onChange(of: store.finishedRevision) { finished() }
        .popover(isPresented: $model.downloadsPresented, arrowEdge: .top) {
            DownloadsPanel(store: store)
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
        guard !reduceMotion else { fadeTint(); return }
        dropEndsAt = Date().addingTimeInterval(0.62)
        withTransaction(instant) {
            dropOffset = -12
            dropOpacity = 1
            rippleScale = 0.3
            rippleOpacity = 0
        }
        withAnimation(.easeIn(duration: 0.26)) { dropOffset = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            withTransaction(instant) {
                dropOpacity = 0
                rippleOpacity = 0.85
            }
            withAnimation(.easeOut(duration: 0.36)) {
                rippleScale = 1.3
                rippleOpacity = 0
            }
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
            // A save starts and finishes at once: let its drop land first.
            let wait = dropEndsAt.timeIntervalSinceNow
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
    struct Input: Equatable {
        let active: Bool
        let progress: Double?
    }

    static func next(current: Double, active: Bool, progress: Double?) -> Double {
        guard active else { return 0 }
        return max(current, min(1, max(0, progress ?? 0)))
    }
}

/// A small water drop: a pointed top over a round base.
struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.maxY - radius)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: center.y),
                          control: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.45))
        path.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.45))
        path.closeSubpath()
        return path
    }
}

/// Session download list for this profile. Clearing removes rows, not files.
struct DownloadsPanel: View {
    let store: DownloadStore

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
                        ForEach(store.items) { DownloadRow(item: $0, store: store) }
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

private struct DownloadRow: View {
    let item: DownloadItem
    let store: DownloadStore
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
                    if let fraction = item.fractionCompleted {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovered ? 0.06 : 0)))
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
