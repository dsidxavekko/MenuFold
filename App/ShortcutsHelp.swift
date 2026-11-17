import MenuFoldCore
import SwiftUI

/// The keyboard shortcuts of the panel, shown by ⌘/ in the panel and in Settings → Загальне.
enum PanelShortcuts {
    struct Group: Identifiable {
        let title: String
        let items: [(keys: String, text: String)]
        var id: String { title }
    }

    static var groups: [Group] {
        [
            Group(title: String(localized: "Рух і запуск"), items: [
                ("↑ ↓ ← →", String(localized: "Вибрати плитку")),
                ("↩", String(localized: "Запустити або відкрити папку")),
                ("⌥↩", String(localized: "Новий екземпляр програми")),
                ("⇧↩  ⌘R", String(localized: "Показати у Finder")),
                ("⇥", String(localized: "Дії з програмою")),
                ("⌘I", String(localized: "Інформація про програму")),
                ("⌘⌫", String(localized: "Перемістити в Кошик")),
            ]),
            Group(title: String(localized: "Порядок"), items: [
                ("⌘D", String(localized: "Закріпити або відкріпити")),
                ("⌥← ⌥→ ⌥↑ ⌥↓", String(localized: "Пересунути плитку на «Все»")),
                ("⌘Z  ⇧⌘Z", String(localized: "Скасувати й повторити зміни")),
            ]),
            Group(title: String(localized: "Вкладки й панель"), items: [
                ("⌘1 … ⌘9", String(localized: "Перейти на вкладку")),
                ("⌃⇥  ⌃⇧⇥", String(localized: "Наступна й попередня вкладка")),
                ("⌘/", String(localized: "Список клавіш")),
                ("⎋", String(localized: "Закрити папку чи панель")),
            ]),
        ]
    }
}

/// One shortcut row: the keys in a rounded cap, then what they do.
private struct ShortcutRow: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(keys)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: .rect(cornerRadius: 6, style: .continuous))
                .frame(minWidth: 96, alignment: .leading)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// ⌘/ overlay: a glass card over a dimmed panel (an alert or sheet would close the panel).
struct ShortcutsHelpCard: View {
    @Bindable var model: GridModel
    @Environment(\.menuFoldReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Гарячі клавіші")
                .font(.headline)
            ForEach(PanelShortcuts.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    ForEach(group.items, id: \.keys) { item in
                        ShortcutRow(keys: item.keys, text: item.text)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Готово") { model.showsShortcutsHelp = false }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardCorner, style: .continuous))
        .cardShadow()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Settings → Загальне → «Гарячі клавіші».
struct ShortcutsSettingsSection: View {
    var body: some View {
        Section {
            ForEach(PanelShortcuts.groups) { group in
                ForEach(group.items, id: \.keys) { item in
                    LabeledContent(item.text) {
                        Text(item.keys)
                            .font(.system(.callout, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("Гарячі клавіші", systemImage: "keyboard")
        } footer: {
            Text("Діють у відкритій панелі, коли вибрано плитку. Список можна відкрити й там: ⌘/.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
