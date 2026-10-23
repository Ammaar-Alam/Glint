import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
protocol EditorClosing {
    func prepareToClose() async -> Bool
}

enum CliptError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum ImageFile {
    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CliptError.message("This image couldn’t be opened.")
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL, type: UTType = .png, quality: Double = 0.9) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CliptError.message("This image format isn’t supported on this Mac.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CliptError.message("The image couldn’t be encoded.")
        }
        try (data as Data).write(to: url, options: .atomic)
    }

    static func temporaryURL(extension suffix: String = "png") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Clipt-\(UUID().uuidString).\(suffix)")
    }
}

@MainActor
func showError(_ error: Error, in window: NSWindow? = nil) {
    let alert = NSAlert(error: error)
    if let window { alert.beginSheetModal(for: window) }
    else { alert.runModal() }
}
