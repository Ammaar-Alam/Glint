import Foundation
@preconcurrency import Vision
import CoreGraphics

enum ImageTextLayout {
    static func wordBoxes(in image: CGImage) async throws -> [CGRect] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
            catch { try Task.checkCancellation(); throw error }
            var boxes: [CGRect] = []
            for observation in request.results ?? [] {
                try Task.checkCancellation()
                guard let text = observation.topCandidates(1).first else { continue }
                text.string.enumerateSubstrings(in: text.string.startIndex..<text.string.endIndex, options: .byWords) { _, range, _, _ in
                    if let box = try? text.boundingBox(for: range)?.boundingBox {
                        boxes.append(CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                                            width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)))
                    }
                }
            }
            try Task.checkCancellation()
            return boxes
        } onCancel: {
            request.cancel()
        }
    }

    static func highlights(intersecting selection: CGRect, words: [CGRect]) -> [CGRect] {
        let matches = words.filter { word in
            let overlap = selection.intersection(word)
            return !overlap.isNull && overlap.width > 0 && overlap.height >= word.height * 0.25
        }.sorted { $0.midY == $1.midY ? $0.minX < $1.minX : $0.midY < $1.midY }
        var lines: [CGRect] = []
        for word in matches {
            if let previous = lines.last,
               abs(previous.midY - word.midY) < min(previous.height, word.height) / 2,
               max(word.minX - previous.maxX, previous.minX - word.maxX) < max(previous.height, word.height) {
                lines[lines.count - 1] = previous.union(word)
            } else { lines.append(word) }
        }
        return lines.map { $0.insetBy(dx: -2, dy: -2) }
    }
}
