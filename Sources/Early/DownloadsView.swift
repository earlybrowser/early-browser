// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI
import UniformTypeIdentifiers

/// The footer's left-hand control. A ring traces the glyph's circle while
/// downloads are active; it never animates on its own.
struct DownloadsButton: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        let store = model.downloads
        Button { model.perform(.showDownloads) } label: {
            DownloadGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.75 * 18 / 24, lineCap: .round, lineJoin: .round))
                .overlay {
                    if store.hasActiveDownloads {
                        Circle()
                            .trim(from: 0, to: store.activeProgress ?? 0.25)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(18 * 2.5 / 24)
                    }
                }
                .frame(width: 18, height: 18)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SpaceControlStyle())
        .foregroundStyle(store.hasActiveDownloads ? .primary : .secondary)
        .browserKeyboardFocus(cornerRadius: 6)
        .accessibilityLabel("Downloads")
        .accessibilityValue(DownloadStatus.summary(for: store))
        .accessibilityIdentifier("downloads.button")
        .help("Downloads (⌥⌘L)")
        .popover(isPresented: $model.downloadsPresented, arrowEdge: .top) {
            DownloadsPanel(store: store)
        }
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
                Button { store.cancel(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .browserKeyboardFocus(cornerRadius: 8)
                .accessibilityLabel("Cancel download")
                .help("Cancel")
            } else if exists {
                Button { store.reveal(item) } label: {
                    Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .browserKeyboardFocus(cornerRadius: 8)
                .accessibilityLabel("Show in Finder")
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { store.open(item) }
        .contextMenu {
            if exists {
                Button("Open") { store.open(item) }
                Button("Show in Finder") { store.reveal(item) }
            }
            if let source = item.sourceURL {
                Button("Copy Download Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
            Divider()
            if item.state.isActive {
                Button("Cancel Download") { store.cancel(item) }
            } else {
                Button("Remove from List") { store.remove(item) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.item.\(item.filename)")
        .accessibilityActions {
            if exists {
                Button("Open") { store.open(item) }
                Button("Show in Finder") { store.reveal(item) }
            }
        }
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
        case .failed:
            return "Failed"
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
