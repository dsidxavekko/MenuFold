import AppKit
import MenuFoldCore
import SwiftUI

/// The "Буфер обміну" tab: copied texts and pictures, newest first, pinned ones on top. A click or
/// Return puts the entry back on the pasteboard and closes the panel. ↑/↓ pick a row, ⌘D pins it,
/// ⌘⌫ deletes it (see `PanelController`); the search field above filters the history.
struct ClipboardView: View {
    @Bindable var model: GridModel
    @Environment(\.menuFoldReduceMotion) private var reduceMotion

    var body: some View {
        let entries = model.clipboardEntries
        if model.clipboard.entries.isEmpty {
            EmptyStateView(
                title: String(localized: "Буфер обміну порожній"),
                subtitle: String(localized: "Скопійований текст з’явиться тут."),
                systemImage: "doc.on.clipboard"
            )
        } else if entries.isEmpty {
            EmptyStateView(
                title: String(localized: "Нічого не знайдено"),
                systemImage: "magnifyingglass",
                effectTrigger: model.query
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            ClipboardRow(entry: entry, model: model, isSelected: model.clipboardSelectedID == entry.id)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .onChange(of: model.clipboardSelectedID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : Theme.snappy) { proxy.scrollTo(id) }
                }
            }
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
    let isSelected: Bool

    @State private var isHovered = false
    @Environment(\.menuFoldContrast) private var contrast

    private var height: CGFloat { entry.image == nil ? 36 : 52 }

    var body: some View {
        let high = contrast == .increased
        Button(action: use) {
            HStack(spacing: 10) {
                leading
                Text(entry.preview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.isPinned, entry.image != nil {
                    Image(systemName: "pin.fill").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(Capsule().fill(Color.primary.opacity(isSelected || isHovered ? 0.10 : 0.04)))
            .overlay {
                if isSelected {
                    Capsule().strokeBorder(
                        Color.accentColor.opacity(high ? Theme.selectionRingOpacityHighContrast : Theme.selectionRingOpacity),
                        lineWidth: high ? Theme.selectionRingWidthHighContrast : Theme.selectionRingWidth
                    )
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(entry.isPinned ? "Відкріпити" : "Закріпити") { model.clipboard.togglePin(id: entry.id) }
            Button("Видалити", role: .destructive) { model.clipboard.remove(id: entry.id) }
        }
        .accessibilityLabel(entry.preview)
        .accessibilityHint(entry.image == nil ? "Копіює текст у буфер обміну" : "Копіює зображення у буфер обміну")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var leading: some View {
        if let image = entry.image, let thumbnail = NSImage(data: image.thumbnail) {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: entry.isPinned ? "pin.fill" : "text.alignleft")
                .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 18)
        }
    }

    private func use() {
        ClipboardMonitor.shared.copy(entry)
        model.onLaunched?()
    }
}
