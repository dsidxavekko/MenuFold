import AppKit
import CoreImage.CIFilterBuiltins

/// A crypto wallet that accepts donations, shown in Settings → Про програму.
struct CryptoWallet: Identifiable {
    let coin: String
    let network: String
    let address: String

    var id: String { coin + network }

    /// Fill in the addresses here. A wallet with an empty address is not shown,
    /// and the whole "Підтримати проєкт" section hides while all of them are empty.
    static let all: [CryptoWallet] = [
        CryptoWallet(coin: "BTC", network: "Bitcoin", address: "bc1qucdvlr66xqu4xeeyrlhm0ru2nl7klyfnyy3wsc"),
        CryptoWallet(coin: "ETH", network: "Ethereum (ERC-20)", address: "0xb1c1314a1d63d6ae92c54d64ed8f34daca683a80"),
        CryptoWallet(coin: "SOL", network: "Solana", address: "H8AgKJgd9yCwXQQfPYV3DwhAcXSUADpYbiXY4reHiPLS"),
        CryptoWallet(coin: "TRX", network: "Tron (TRC-20)", address: "TF9rt5o7RkgpsA88mrXxqLBiUnnMGnAanr"),
    ]

    static var visible: [CryptoWallet] {
        all.filter { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A crisp QR code of the address, `size` points wide.
    func qrCode(size: CGFloat = 180) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (size / output.extent.width).rounded(.up)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
