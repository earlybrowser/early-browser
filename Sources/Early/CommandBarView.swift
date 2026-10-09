import EarlyCore
import SwiftUI

struct CommandBarView: View {
    @Bindable var model: BrowserWindowModel
    @FocusState private var queryIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search or enter a URL", text: Binding(
                    get: { model.coordinator.commandBar?.query ?? "" },
                    set: {
                        model.coordinator.updateQuery($0)
                        model.submissionMessage = nil
                    }
                ))
                .font(.title3)
                .textFieldStyle(.plain)
                .focused($queryIsFocused)
                .accessibilityLabel("Search or enter a URL")
                .accessibilityIdentifier("commandBar.query")
                .onSubmit { model.submit() }
                Button {
                    model.coordinator.dismissCommandBar()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss command bar")
                .help("Dismiss (Escape)")
            }
            if let message = model.submissionMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("commandBar.message")
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .task(id: model.coordinator.commandBarFocusRequest) {
            // Let the sidebar button finish its click/focus transaction before
            // moving the first responder into the newly presented editor.
            await Task.yield()
            guard !Task.isCancelled else { return }
            queryIsFocused = true
        }
        .onExitCommand { model.coordinator.dismissCommandBar() }
    }
}
