import AppKit
import SwiftUI

/// "Про програму" tab: icon, name, version and links.
struct AboutView: View {
    private static let repoURL = URL(string: "https://github.com/dsidxavekko/MenuFold")!
    private static let issuesURL = URL(string: "https://github.com/dsidxavekko/MenuFold/issues")!

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: DockIconStyle.menuFold.image)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("MenuFold")
                    .font(.largeTitle.weight(.semibold))
                Text(Self.versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Сітка всіх програм із папками, категоріями та пошуком — замість стосу «Програми» в Dock. Нічого не змінює в системі й ніколи не переміщує файли.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            HStack(spacing: 10) {
                Link(destination: Self.repoURL) {
                    Label("Сторінка проєкту", systemImage: "safari")
                }
                Link(destination: Self.issuesURL) {
                    Label("Повідомити про проблему", systemImage: "exclamationmark.bubble")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(.top, 4)

            if let copyright = Self.copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Версія 0.2.0 (2)" from the bundle's Info.plist.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String
        return build.map { "Версія \(version) (\($0))" } ?? "Версія \(version)"
    }

    private static var copyright: String? {
        let text = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
        return text?.isEmpty == false ? text : nil
    }
}

#Preview {
    AboutView()
        .frame(width: 520)
}
