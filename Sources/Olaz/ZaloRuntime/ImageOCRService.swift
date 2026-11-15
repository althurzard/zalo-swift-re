import AppKit
import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import Vision
@preconcurrency import VisionKit

/// Result of offline on-device OCR on a still image.
struct OCRTextResult: Sendable, Hashable {
    let recognizedText: String
    let lines: [String]
    let detectedLanguages: [String]

    var isEmpty: Bool {
        recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ImageOCRError: Error, Sendable, Equatable {
    case invalidImage
    case liveTextUnsupported
}

/// On-device Apple Vision text recognition and VisionKit Live Text analysis.
///
/// Privacy invariant: never log recognized OCR text via `EngineLog` or OSLog.
enum ImageOCRService {
    nonisolated static var isLiveTextSupported: Bool {
        ImageAnalyzer.isSupported
    }

    static func recognizeText(
        in image: NSImage,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> OCRTextResult {
        let cgImage = try extractCGImage(from: image)
        return try await recognizeText(in: cgImage, orientation: .up)
    }

    nonisolated static func recognizeText(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> OCRTextResult {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["vi-VN", "en-US"]
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()

            let lines = (request.results ?? [])
                .compactMap { observation in
                    observation.topCandidates(1).first?.string
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
            let recognizedText = lines.joined(separator: "\n")
            let languages = detectLanguages(in: recognizedText)
            return OCRTextResult(
                recognizedText: recognizedText,
                lines: lines,
                detectedLanguages: languages
            )
        }.value
    }

    nonisolated static func recognizeText(in data: Data) async throws -> OCRTextResult {
        try Task.checkCancellation()
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageOCRError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            ?? (properties?[kCGImagePropertyOrientation] as? Int).map(UInt32.init)
        let orientation = rawOrientation.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return try await recognizeText(in: cgImage, orientation: orientation)
    }

    static func analyzeLiveText(
        in image: NSImage,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> ImageAnalysis {
        let cgImage = try extractCGImage(from: image)
        return try await analyzeLiveText(in: cgImage, orientation: .up)
    }

    nonisolated static func analyzeLiveText(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> ImageAnalysis {
        guard isLiveTextSupported else {
            throw ImageOCRError.liveTextUnsupported
        }
        try Task.checkCancellation()
        let analyzer = ImageAnalyzer()
        var configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        configuration.locales = ["vi-VN", "en-US"]
        return try await analyzer.analyze(cgImage, orientation: orientation, configuration: configuration)
    }

    private static func extractCGImage(from image: NSImage) throws -> CGImage {
        guard image.size.width > 0, image.size.height > 0 else {
            throw ImageOCRError.invalidImage
        }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage
        }
        if let tiffData = image.tiffRepresentation,
           let source = CGImageSourceCreateWithData(tiffData as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return cgImage
        }
        throw ImageOCRError.invalidImage
    }

    nonisolated private static func detectLanguages(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            .filter { $0.key != .undetermined && $0.value >= 0.15 }
            .sorted { $0.value > $1.value }
            .map { $0.key.rawValue }
        if !hypotheses.isEmpty {
            return hypotheses
        }
        if let dominant = recognizer.dominantLanguage, dominant != .undetermined {
            return [dominant.rawValue]
        }
        return []
    }
}
