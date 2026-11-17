import AppKit
import MenuFoldCore
import SwiftUI

/// "Створити папку з…": a compact searchable list of the other apps, shown in the panel for
/// `model.folderPickerSourceID` (no drag needed, so it works with VoiceOver and the keyboard).
/// `MenuFoldRootView` draws the dim behind it and cancels on a click outside; Esc cancels via the
/// panel's `onCancel`. Choosing an app makes the folder like a drop of app on app.
struct FolderPickerCard: View {
    let source: AppEntry
    @Bindable var model: GridModel

    @Environment(\.menuFoldReduceMotion) private var reduceMotion
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let candidates = model.folderPickerCandidates(search: search)
        VStack(spacing: 12) {
            Text("Створити папку з «\(source.name)»")
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            TextField("Пошук програми", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = candidates.first { choose(first) } }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(candidates, id: \.id) { app in
                        Button { choose(app) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: IconCache.shared.icon(for: app))
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 28, height: 28)
                                    .accessibilityHidden(true)
                                Text(app.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(app.name)
                    }
                    if candidates.isEmpty {
                        Text("Нічого не знайдено")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                }
            }
            .frame(height: 260)
            Button("Скасувати") { model.cancelFolderPicker() }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(22)
        .frame(width: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardCorner, style: .continuous))
        .cardShadow()
        .onAppear { searchFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func choose(_ app: AppEntry) {
        withAnimation(Theme.motion(Theme.morph, reduceMotion: reduceMotion)) {
            if let id = model.completeFolderPicker(with: app.id) { model.openFolderID = id }
        }
    }
}
