// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

extension SpaceIcon {
    var accessibilityName: String {
        switch self {
        case .symbol(let symbol): symbol.label
        }
    }
}

struct SpaceIconView: View {
    let icon: SpaceIcon?
    var size: CGFloat = 10

    var body: some View {
        Group {
            switch icon {
            case .symbol(let symbol):
                Image(systemName: symbol.rawValue).font(.system(size: size, weight: .medium))
            case nil:
                Circle().fill(.primary).frame(width: 7, height: 7)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// A native anchored popover with a compact grid of monochrome symbols.
/// Selection stays in the editor draft until the enclosing sheet is saved.
struct SpaceIconPicker: View {
    @Binding var selection: SpaceIcon?
    var title = "Choose an icon"
    /// The no-icon choice: a Space's dot, or a folder without an icon.
    var noneTitle = "Use default dot"
    var noneSymbol: String?
    let dismiss: () -> Void
    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline).lineLimit(2).multilineTextAlignment(.center)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(SpaceIcon.Symbol.allCases, id: \.self) { symbol in
                    choice(.symbol(symbol), identifier: "space.symbol.\(symbol.rawValue)")
                }
            }

            Divider()
            Button {
                selection = nil
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    if let noneSymbol {
                        Image(systemName: noneSymbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    } else {
                        Circle().fill(.secondary).frame(width: 7, height: 7)
                    }
                    Text(noneTitle)
                    Spacer()
                    if selection == nil { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                }
                .padding(.horizontal, 6).frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .browserKeyboardFocus()
            .accessibilityLabel(noneTitle)
            .accessibilityAddTraits(selection == nil ? .isSelected : [])
            .accessibilityIdentifier("space.icon.none")
        }
        .padding(18)
        .frame(width: 334)
        .browserReducedMotion()
    }

    private func choice(_ icon: SpaceIcon, identifier: String) -> some View {
        Button {
            selection = icon
            dismiss()
        } label: {
            SpaceIconView(icon: icon, size: 15)
                .frame(width: 32, height: 32)
                .overlay(alignment: .bottom) { BrowserSelectionMark(selected: selection == icon) }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(IconChoiceStyle(selected: selection == icon))
        .browserKeyboardFocus()
        .accessibilityLabel(icon.accessibilityName)
        .accessibilityAddTraits(selection == icon ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .help(icon.accessibilityName)
    }

    private struct IconChoiceStyle: ButtonStyle {
        let selected: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(.primary.opacity(selected ? 0.14 : (configuration.isPressed ? 0.08 : 0)),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.25)) }
                }
        }
    }
}
