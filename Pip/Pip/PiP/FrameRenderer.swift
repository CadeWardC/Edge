import CoreGraphics
import CoreVideo
import Foundation

/// Draws a set of photos into one video frame. Used from a single background queue.
final class FrameRenderer {
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.totalCostLimit = 80 << 20
    }

    func render(photos: [Photo], width: Int, height: Int, arrangement: PipSettings.Arrangement, fill: Bool) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let size = CGSize(width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high

        let maxPixel = photos.count == 1 ? max(width, height) : 800
        let rects = Layout.rects(count: photos.count, size: size, arrangement: arrangement)
        for (index, photo) in photos.enumerated() {
            // Core Graphics counts rows from the bottom
            let rect = CGRect(x: rects[index].minX, y: size.height - rects[index].maxY, width: rects[index].width, height: rects[index].height)
            let isInset = arrangement == .inset && index > 0
            if let image = image(photo, maxPixel: maxPixel) {
                let imageWidth = CGFloat(image.width), imageHeight = CGFloat(image.height)
                let scale = fill || isInset
                    ? max(rect.width / imageWidth, rect.height / imageHeight)
                    : min(rect.width / imageWidth, rect.height / imageHeight)
                let drawn = CGSize(width: imageWidth * scale, height: imageHeight * scale)
                context.saveGState()
                context.clip(to: rect)
                context.draw(image, in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
                context.restoreGState()
            }
            if isInset {
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.setLineWidth(5)
                context.stroke(rect)
            }
        }
        return buffer
    }

    private func image(_ photo: Photo, maxPixel: Int) -> CGImage? {
        let key = "\(photo.fileName)-\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = PhotoFiles.image(photo, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
