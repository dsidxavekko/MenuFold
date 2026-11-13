import SwiftUI

/// One-time card at the bottom of the panel listing the gestures that are not discoverable by
/// looking at the grid (drag to make folders, drop on a tab, shortcuts). Shown by
/// `MenuFoldRootView` until "Зрозуміло" sets `AppPreferences.hasSeenFirstRunHint`. It is compact and
/// sits over the bottom edge so most of the grid stays usable while it is up.
struct FirstRunHintCard: View {
    let dismiss: () -> Void

    private struct Hint: Identifiable {
        let symbol: String
        let text: LocalizedStringKey
        var id: String { symbol }
    }

    private let hints: [Hint] = [
        Hint(symbol: "magnifyingglass", text: "Друкуйте, щоб шукати"),
        Hint(symbol: "folder.badge.plus", text: "Перетягніть програму на іншу — вийде папка"),
        Hint(symbol: "tag", text: "Перетягніть програму на вкладку — зміниться категорія"),
        Hint(symbol: "contextualmenu.and.cursorarrow", text: "Правий клік — більше дій"),
        Hint(symbol: "command", text: "⌘1…9 — вкладки, ⌘Z — скасувати"),
        Hint(symbol: "trash", text: "⌘⌫ — перемістити програму в Кошик"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Як користуватися MenuFold")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Зрозуміло", action: dismiss)
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
            LazyVGrid(
                columns: [SwiftUI.GridItem(.flexible(), alignment: .leading), SwiftUI.GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(hints) { hint in
                    HStack(spacing: 8) {
                        Image(systemName: hint.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(hint.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    FirstRunHintCard {}
        .padding()
        .frame(width: GridMetrics.panelWidth)
        .background(.regularMaterial)
}
