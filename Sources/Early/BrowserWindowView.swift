import EarlyCore
import SwiftUI

struct BrowserWindowView: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        HStack(spacing: 6) {
            sidebar
            ZStack {
                Color(nsColor: .textBackgroundColor)
                    .accessibilityLabel("Empty browser content")
                    .accessibilityIdentifier("browser.emptyContent")
                if model.coordinator.commandBar != nil {
                    CommandBarView(model: model)
                        .padding(32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(6)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneValue(\.browserWindow, model)
        .onDisappear { model.webViews.discardAll() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("early")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .accessibilityLabel("Early")
            addressBar
            Label("Personal", systemImage: "square.stack")
                .font(.headline)
            VStack(alignment: .leading, spacing: 20) {
                sectionLabel("Favorites")
                sectionLabel("Pinned")
                Divider()
                sectionLabel("Today")
            }
            Button {
                model.presentCommandBar(.newTab)
            } label: {
                HStack {
                    Label("New Tab", systemImage: "plus")
                    Spacer()
                    Text("⌘T").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.newTab")
            .help("Open the command bar (Command-T)")
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("browser.sidebar")
    }

    private var currentURL: String? {
        guard case .web(let id) = model.coordinator.content else { return nil }
        return model.coordinator.tabStore.tab(id: id)?.currentURL.absoluteString
    }

    private var addressBar: some View {
        Button {
            model.presentCommandBar(.navigateCurrentTab)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(currentURL ?? "Search or enter URL")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(currentURL == nil ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Address bar")
        .accessibilityValue(currentURL ?? "No active tab")
        .accessibilityIdentifier("sidebar.addressBar")
        .help(currentURL.map { "\($0) — Open Location (Command-L)" }
              ?? "Search or enter a URL (Command-L)")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
