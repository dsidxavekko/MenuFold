import AppKit
import MenuFoldCore
import SwiftUI

/// The "Буфер обміну" tab: copied texts, newest first, pinned ones on top. A click puts the text
/// back on the pasteboard and closes the panel; the context menu pins or removes an entry.
struct ClipboardView: View {
    @Bindable var model: GridModel

    var body: some View {
        let entries = model.clipboard.entries
        if entries.isEmpty {
            EmptyStateView(
                title: String(localized: "Буфер обміну порожній"),
                subtitle: String(localized: "Скопійований текст з’явиться тут."),
                systemImage: "doc.on.clipboard"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(entries) { entry in
                        ClipboardRow(entry: entry, model: model)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .overlay(alignment: .bottomTrailing) {
                Button("Очистити") { withAnimation(Theme.snappy) { model.clipboard.clear() } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(8)
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let model: GridModel

    @State private var isHovered = false

    var body: some View {
        Button(action: use) {
            HStack(spacing: 10) {
                Image(systemName: entry.isPinned ? "pin.fill" : "text.alignleft")
                    .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(entry.preview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(Color.primary.opacity(isHovered ? 0.10 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(entry.isPinned ? "Відкріпити" : "Закріпити") { model.clipboard.togglePin(id: entry.id) }
            Button("Видалити", role: .destructive) { model.clipboard.remove(id: entry.id) }
        }
        .accessibilityLabel(entry.preview)
        .accessibilityHint("Копіює текст у буфер обміну")
    }

    private func use() {
        ClipboardMonitor.shared.copy(entry)
        model.onLaunched?()
    }
}
