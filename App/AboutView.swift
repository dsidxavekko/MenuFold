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

            if !CryptoWallet.visible.isEmpty {
                DonationSection()
                    .padding(.top, 8)
            }

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
        return build.map { String(localized: "Версія \(version) (\($0))") } ?? String(localized: "Версія \(version)")
    }

    private static var copyright: String? {
        let text = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
        return text?.isEmpty == false ? text : nil
    }
}

/// "Підтримати проєкт": one row per wallet with copy and QR buttons.
private struct DonationSection: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Підтримати проєкт")
                .font(.headline)
            Text("MenuFold безкоштовний. Якщо він вам знадобився, можна підтримати розробку криптовалютою.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            VStack(spacing: 6) {
                ForEach(CryptoWallet.visible) { wallet in
                    WalletRow(wallet: wallet)
                }
            }
            .frame(maxWidth: 440)

            Text("Надсилайте лише в зазначеній мережі.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct WalletRow: View {
    let wallet: CryptoWallet
    @State private var copied = false
    @State private var showsQR = false
    /// The pending "Скопійовано" reset; cancelled when the wallet is copied again.
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(wallet.coin)
                    .font(.callout.weight(.semibold))
                Text(wallet.network)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)

            Text(wallet.address)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(wallet.address)

            Button {
                copy()
            } label: {
                Label(copyTitle, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(copyTitle)

            Button {
                showsQR = true
            } label: {
                Label("QR-код", systemImage: "qrcode")
                    .labelStyle(.iconOnly)
            }
            .help("QR-код")
            .popover(isPresented: $showsQR, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    if let image = wallet.qrCode() {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .accessibilityLabel(Text(verbatim: wallet.address))
                    }
                    Text(verbatim: "\(wallet.coin) · \(wallet.network)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    private var copyTitle: LocalizedStringKey {
        copied ? "Скопійовано" : "Копіювати"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(wallet.address, forType: .string)
        withAnimation(reduceMotion ? nil : Theme.crossfade) { copied = true }
        // A second tap cancels the first tap's pending reset, so the label doesn't flicker back and
        // forth when the wallet is copied twice in a row.
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Theme.crossfade) { copied = false }
        }
    }
}

#Preview {
    AboutView()
        .frame(width: 520)
}
