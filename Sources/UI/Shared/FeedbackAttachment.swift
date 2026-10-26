import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FeedbackAttachment: Codable, Equatable, Identifiable, Sendable {
    nonisolated static let maximumBytes = 1_048_576
    nonisolated static let inputLimit = 20 * 1_048_576
    nonisolated static let imageTypes = [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.heic.identifier]
    let id: UUID
    let data: Data
    let mimeType: String
    let filename: String

    func validate() throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw FeedbackSubmissionError.imageTooLarge }
        let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = data.starts(with: [255, 216, 255]) && data.suffix(2) == Data([255, 217])
        guard (mimeType == "image/png" && png) || (mimeType == "image/jpeg" && jpeg),
              filename == "screenshot-\(id.uuidString).\(mimeType == "image/png" ? "png" : "jpg")" else {
            throw FeedbackSubmissionError.unsupportedImage
        }
    }

    static func load(from url: URL) async throws -> FeedbackAttachment {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try normalizedImage(at: url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func load(data: Data) async throws -> FeedbackAttachment {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try normalizedImage(data: data)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func normalizedImage(at url: URL) throws -> FeedbackAttachment {
        guard url.isFileURL else { throw FeedbackSubmissionError.unsupportedImage }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bounded read even if another process grows the selected file.
        guard let original = try handle.read(upToCount: inputLimit + 1),
              !original.isEmpty, original.count <= inputLimit else { throw FeedbackSubmissionError.imageTooLarge }
        return try normalizedImage(data: original)
    }

    private static func normalizedImage(data original: Data) throws -> FeedbackAttachment {
        guard !original.isEmpty, original.count <= inputLimit else { throw FeedbackSubmissionError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              imageTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 40_000, height <= 40_000,
              width * height <= 40_000_000 else { throw FeedbackSubmissionError.unsupportedImage }

        for dimension in [1_600, 1_000] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                           kCGImageSourceThumbnailMaxPixelSize: dimension]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw FeedbackSubmissionError.unsupportedImage
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw FeedbackSubmissionError.unsupportedImage
            }
            // Encoding the decoded image, rather than copying image-source properties,
            // omits original names, location, comments and other screenshot metadata.
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw FeedbackSubmissionError.unsupportedImage }
            if output.length <= maximumBytes {
                let id = UUID()
                return FeedbackAttachment(id: id, data: output as Data, mimeType: "image/jpeg", filename: "screenshot-\(id.uuidString).jpg")
            }
        }
        throw FeedbackSubmissionError.imageTooLarge
    }
}
