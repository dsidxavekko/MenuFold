import SwiftUI

/// Small accent capsule at the trailing end of the search row while Sparkle knows of an update the
/// user has not installed (`Updater.availableUpdateVersion`). The panel has no settings button, so
/// this is the only in-panel hint that a new version is waiting. A click hands over to Sparkle's
/// own window, which takes key status and closes the panel (expected).
struct UpdatePill: View {
    let version: String
    @State private var isHovered = false

    var body: some View {
        Button {
            Updater.shared.checkForUpdates()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                Text("Оновлення \(version)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: Theme.capsuleHeight - 4)
            .glassEffect(.regular.tint(Color.accentColor.opacity(isHovered ? 1 : 0.85)).interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(Theme.snappy, value: isHovered)
        .help("Встановити нову версію MenuFold")
        .accessibilityLabel(String(localized: "Доступне оновлення \(version)"))
    }
}

#Preview {
    UpdatePill(version: "0.5.0")
        .padding()
}
