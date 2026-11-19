import ImageIO
import PhotosUI
import SwiftUI

/// One photo the app keeps its own copy of (a JPEG in Documents/Photos).
struct Photo: Identifiable, Codable, Hashable {
    let id: UUID
    var fileName: String { id.uuidString + ".jpg" }
}

/// Reading and writing the photo files. Safe to call from any thread.
enum PhotoFiles {
    /// Longest edge of the stored copy. The floating window is small, so this is plenty.
    static let storedPixels = 2048

    static let folder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var indexURL: URL { folder.appendingPathComponent("index.json") }

    static func url(_ photo: Photo) -> URL { folder.appendingPathComponent(photo.fileName) }

    /// Decodes at a reduced size, upright (the camera's rotation flag is applied).
    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func image(_ photo: Photo, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(photo) as CFURL, nil) else { return nil }
        return downsample(source, maxPixel: maxPixel)
    }

    /// Width divided by height of the stored copy.
    static func aspect(_ photo: Photo) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url(photo) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        return width / height
    }

    /// Stores a picked photo (any format the iPhone can read) and returns its record.
    static func save(_ data: Data) -> Photo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsample(source, maxPixel: storedPixels),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { return nil }
        let photo = Photo(id: UUID())
        do {
            try jpeg.write(to: url(photo), options: .atomic)
            return photo
        } catch {
            return nil
        }
    }
}

/// The ordered list of photos shown in the floating window.
final class PhotoLibrary: ObservableObject {
    static let shared = PhotoLibrary()

    @Published private(set) var photos: [Photo] = []
    /// Photos still being copied in.
    @Published private(set) var importing = 0
    /// Photos that could not be read in the last import.
    @Published var failed = 0

    private let thumbnails = NSCache<NSString, UIImage>()

    private init() {
        if let data = try? Data(contentsOf: PhotoFiles.indexURL), let saved = try? JSONDecoder().decode([Photo].self, from: data) {
            photos = saved.filter { FileManager.default.fileExists(atPath: PhotoFiles.url($0).path) }
        }
    }

    @MainActor
    func add(_ items: [PhotosPickerItem]) async {
        importing += items.count
        for item in items {
            var photo: Photo?
            if let data = try? await item.loadTransferable(type: Data.self) {
                photo = await Task.detached(priority: .userInitiated) { PhotoFiles.save(data) }.value
            }
            if let photo {
                photos.append(photo)
                persist()
            } else {
                failed += 1
            }
            importing -= 1
        }
    }

    func remove(atOffsets offsets: IndexSet) {
        let removed = offsets.map { photos[$0] }
        photos.remove(atOffsets: offsets)
        persist()
        removed.forEach { try? FileManager.default.removeItem(at: PhotoFiles.url($0)) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        photos.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func removeAll() {
        remove(atOffsets: IndexSet(integersIn: photos.indices))
    }

    func thumbnail(_ photo: Photo) -> UIImage? {
        let key = photo.fileName as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = PhotoFiles.image(photo, maxPixel: 180) else { return nil }
        let thumbnail = UIImage(cgImage: image)
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(photos) {
            try? data.write(to: PhotoFiles.indexURL, options: .atomic)
        }
    }
}
