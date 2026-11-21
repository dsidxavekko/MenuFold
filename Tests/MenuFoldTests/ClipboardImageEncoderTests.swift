import AppKit
import Testing
@testable import MenuFold

@Suite("ClipboardImageEncoder")
struct ClipboardImageEncoderTests {
    private func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @Test func tiffBecomesPNGWithThumbnail() throws {
        let tiff = try #require(bitmap(width: 400, height: 200).tiffRepresentation)
        let image = try #require(ClipboardImageEncoder.encode(tiff))
        #expect(image.width == 400 && image.height == 200)
        #expect(image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let thumb = try #require(NSBitmapImageRep(data: image.thumbnail))
        #expect(max(thumb.pixelsWide, thumb.pixelsHigh) <= ClipboardImageEncoder.thumbnailPixels)
    }

    @Test func pngIsKeptByteForByte() throws {
        let png = try #require(bitmap(width: 50, height: 50).representation(using: .png, properties: [:]))
        let image = try #require(ClipboardImageEncoder.encode(png))
        #expect(image.data == png)
    }

    @Test func garbageIsRejected() {
        #expect(ClipboardImageEncoder.encode(Data("not an image".utf8)) == nil)
    }
}
