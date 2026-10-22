// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI
import UniformTypeIdentifiers

/// The footer's left-hand control. Each new download or saved file makes the
/// glyph pop; an accent ring over a faint track shows active progress.
struct DownloadsButton: View {
    @Bindable var model: BrowserWindowModel
    @State private var popped = false
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = model.downloads
        let active = store.hasActiveDownloads
        let progress = store.activeProgress
        Button { model.perform(.showDownloads) } label: {
            DownloadGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.75 * 18 / 24, lineCap: .round, lineJoin: .round))
                .opacity(active ? 0.35 : 1)
                .overlay {
                    if active {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2)
                            Circle()
                                .trim(from: 0, to: progress ?? 0.3)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
                                .rotationEffect(.degrees(-90 + (progress == nil && spinning ? 360 : 0)))
                        }
                        .padding(1)
                    }
                }
                .frame(width: 18, height: 18)
                .scaleEffect(popped ? 1.35 : 1)
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
        .onChange(of: store.startedRevision) { pop() }
        .onChange(of: active && progress == nil, initial: true) { _, unknownSize in spin(unknownSize) }
        .popover(isPresented: $model.downloadsPresented, arrowEdge: .top) {
            DownloadsPanel(store: store)
        }
    }

    private func pop() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.45)) { popped = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) { popped = false }
        }
    }

    /// Only an unknown-size transfer turns; Reduce Motion keeps it still.
    private func spin(_ unknownSize: Bool) {
        guard unknownSize, !reduceMotion else {
            withAnimation(nil) { spinning = false }
            return
        }
        spinning = false
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spinning = true }
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
