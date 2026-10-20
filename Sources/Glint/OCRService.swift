import Foundation
import Vision

enum OCRService {
    static func recognize(url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let codes = VNDetectBarcodesRequest()
            codes.symbologies = [.qr]
            let handler = VNImageRequestHandler(url: url, options: [:])
            try handler.perform([text, codes])
            try Task.checkCancellation()
            let recognized = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
            var parts = recognized.isEmpty ? [] : [recognized]
            for payload in payloads where !parts.contains(payload) && !recognized.contains(payload) { parts.append(payload) }
            return parts.joined(separator: "\n\n")
        }.value
    }
}
