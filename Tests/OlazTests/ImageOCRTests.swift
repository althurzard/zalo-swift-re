import Testing
import AppKit
import CoreGraphics
import CoreText
import Foundation
import VisionKit
@testable import Olaz

@Suite struct ImageOCRTests {
    /// Renders high-contrast black text onto an opaque white CoreGraphics bitmap.
    private func renderTextCGImage(lines: [String], size: CGSize = CGSize(width: 900, height: 280)) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 40, nil)
        let color = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        let lineHeight: CGFloat = 58
        var baselineY = size.height - 84
        for text in lines {
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: baselineY)
            CTLineDraw(ctLine, context)
            baselineY -= lineHeight
        }

        return try #require(context.makeImage())
    }

    private func renderBlankCGImage(size: CGSize = CGSize(width: 400, height: 200)) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try #require(context.makeImage())
    }

    private func pngData(from cgImage: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - ImageOCRService

    @Test func recognizesTextFromNSImageCGImageAndData() async throws {
        let cgImage = try renderTextCGImage(lines: ["HELLO OLAZ 2026", "APPLE VISION OCR"])
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let data = try pngData(from: cgImage)

        let fromCG = try await ImageOCRService.recognizeText(in: cgImage)
        #expect(!fromCG.isEmpty)
        #expect(fromCG.recognizedText.localizedCaseInsensitiveContains("HELLO"))
        #expect(fromCG.recognizedText.localizedCaseInsensitiveContains("OLAZ"))
        #expect(fromCG.recognizedText.localizedCaseInsensitiveContains("2026"))
        #expect(fromCG.lines.count >= 2)
        #expect(!fromCG.detectedLanguages.isEmpty)

        let fromNS = try await ImageOCRService.recognizeText(in: nsImage)
        #expect(fromNS.recognizedText == fromCG.recognizedText)
        #expect(fromNS.lines == fromCG.lines)

        let fromData = try await ImageOCRService.recognizeText(in: data)
        #expect(fromData.recognizedText == fromCG.recognizedText)
    }

    @Test func recognizesVietnameseText() async throws {
        let cgImage = try renderTextCGImage(lines: ["Xin chào Việt Nam", "Chuyển khoản ngân hàng"])
        let result = try await ImageOCRService.recognizeText(in: cgImage)
        #expect(!result.isEmpty)
        let folded = result.recognizedText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
        #expect(folded.contains("xin chao viet nam"))
        #expect(folded.contains("chuyen khoan"))
        #expect(!result.detectedLanguages.isEmpty)
    }

    @Test func blankImageReturnsEmptyOCRResult() async throws {
        let blankCG = try renderBlankCGImage()
        let blankNS = NSImage(cgImage: blankCG, size: NSSize(width: blankCG.width, height: blankCG.height))

        let result = try await ImageOCRService.recognizeText(in: blankNS)
        #expect(result.isEmpty)
        #expect(result.recognizedText.isEmpty)
        #expect(result.lines.isEmpty)
        #expect(result.detectedLanguages.isEmpty)
    }

    @Test func invalidDataThrowsInvalidImageError() async {
        await #expect(throws: ImageOCRError.invalidImage) {
            try await ImageOCRService.recognizeText(in: Data([0x00, 0x01, 0x02, 0x03]))
        }
        await #expect(throws: ImageOCRError.invalidImage) {
            try await ImageOCRService.recognizeText(in: NSImage(size: .zero))
        }
    }

    @Test func liveTextAvailabilityMatchesVisionKit() async throws {
        #expect(ImageOCRService.isLiveTextSupported == ImageAnalyzer.isSupported)
        if ImageOCRService.isLiveTextSupported {
            let cgImage = try renderTextCGImage(lines: ["Chuyển khoản ngân hàng"])
            let analysis = try await ImageOCRService.analyzeLiveText(in: cgImage)
            #expect(analysis.hasResults(for: .text))
            #expect(analysis.transcript.localizedCaseInsensitiveContains("ngân hàng"))
        }
    }

    // MARK: - ScreenCapture OCR Availability

    @Test func ocrAvailabilityPayloadEncodesSupportedAndUnsupportedBranches() throws {
        let enabledPayload = ScreenCapture.ocrAvailabilityPayload(id: "req-42", helperExists: true)
        #expect(enabledPayload["cmd"] as? String == "zalo:ocrAvailability")
        let enabledData = try #require(enabledPayload["data"] as? [String: Any])
        #expect(enabledData["idReq"] as? String == "req-42")
        #expect(enabledData["enabled"] as? Bool == true)
        #expect(enabledData["transport"] as? String == "in-process")
        #expect(enabledData["canShareOCRContent"] as? Bool == true)
        #expect(enabledData["reason"] == nil)

        let disabledPayload = ScreenCapture.ocrAvailabilityPayload(id: "req-99", helperExists: false)
        #expect(disabledPayload["cmd"] as? String == "zalo:ocrAvailability")
        let disabledData = try #require(disabledPayload["data"] as? [String: Any])
        #expect(disabledData["idReq"] as? String == "req-99")
        #expect(disabledData["enabled"] as? Bool == false)
        #expect(disabledData["reason"] as? String == "unsupported")
        #expect(disabledData["transport"] == nil)
    }

    @Test func detectsLibzocrVisionRelativeToZaloCapExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-ocr-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helperContents = root.appendingPathComponent("ZaloHelper.app/Contents", isDirectory: true)
        let macosDir = helperContents.appendingPathComponent("MacOS", isDirectory: true)
        let frameworksDir = helperContents.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        let zaloCap = macosDir.appendingPathComponent("ZaloCap")
        try Data().write(to: zaloCap)
        #expect(!ScreenCapture.hasOCRLibrary(forExecutable: zaloCap))

        let dylib = frameworksDir.appendingPathComponent("libzocr_vision.dylib")
        try Data().write(to: dylib)
        #expect(ScreenCapture.hasOCRLibrary(forExecutable: zaloCap))
    }

    // MARK: - MediaViewer & ZoomScrollView Integration

    @Test @MainActor func overlayViewIsAttachedOnlyWhenOCREnabled() throws {
        let cgImage = try renderTextCGImage(lines: ["OVERLAY TEST"])
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let view = ZoomScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.setImage(nsImage)
        #expect(!view.isOCROverlayAttached)

        view.setOCR(enabled: true, analysis: nil)
        #expect(view.isOCROverlayAttached)

        view.setOCR(enabled: false, analysis: nil)
        #expect(!view.isOCROverlayAttached)

        view.setOCR(enabled: true, analysis: nil)
        #expect(view.isOCROverlayAttached)
        view.teardown()
        #expect(!view.isOCROverlayAttached)
    }

    @Test @MainActor func shortcutOAndStateClearManageOCRSafely() {
        let state = MediaViewer.shared.state
        state.clear()
        defer { state.clear() }

        let photo = MediaViewerItem(
            media: .photo(url: URL(string: "https://example.com/ocr.jpg"), width: 800, height: 600, encrypted: false),
            conversationId: "c1",
            messageId: "m1",
            senderName: "An",
            date: Date(timeIntervalSince1970: 100)
        )
        state.present(photo)
        #expect(!state.isOCREnabled)

        let consumed = MediaViewer.shared.handleKey(keyCode: 31, characters: "o", modifiers: [])
        #expect(consumed)
        #expect(state.isOCREnabled == ImageOCRService.isLiveTextSupported)

        let toggledOff = MediaViewer.shared.handleKey(keyCode: 31, characters: "o", modifiers: [])
        #expect(toggledOff)
        #expect(!state.isOCREnabled)

        // Command+O should not toggle OCR.
        #expect(!MediaViewer.shared.handleKey(keyCode: 31, characters: "o", modifiers: [.command]))
        #expect(!state.isOCREnabled)

        // Re-enable and clear() must reset all OCR state.
        _ = MediaViewer.shared.handleKey(keyCode: 31, characters: "o", modifiers: [])
        state.clear()
        #expect(!state.isOCREnabled)
        #expect(state.ocrAnalysis == nil)
        #expect(state.ocrFeedback == nil)

        // Video items ignore the OCR shortcut.
        let video = MediaViewerItem(
            media: .video(file: URL(fileURLWithPath: "/tmp/test.mp4"), size: CGSize(width: 640, height: 360)),
            conversationId: "c1",
            messageId: "m2",
            senderName: "An",
            date: Date(timeIntervalSince1970: 200)
        )
        state.present(video)
        #expect(!MediaViewer.shared.handleKey(keyCode: 31, characters: "o", modifiers: []))
        #expect(!state.isOCREnabled)
    }

    @Test @MainActor func copyRecognizedTextCopiesToPasteboardAndRespectsHiddenLock() async throws {
        let cgText = try renderTextCGImage(lines: ["COPY OCR TEXT"])
        let nsText = NSImage(cgImage: cgText, size: NSSize(width: cgText.width, height: cgText.height))
        let cgBlank = try renderBlankCGImage()
        let nsBlank = NSImage(cgImage: cgBlank, size: NSSize(width: cgBlank.width, height: cgBlank.height))

        let state = MediaViewerState()
        let photo = MediaViewerItem(
            media: .photo(url: URL(string: "https://example.com/copy.jpg"), width: 900, height: 280, encrypted: false),
            conversationId: "c1",
            messageId: "m1",
            senderName: "An",
            date: Date(timeIntervalSince1970: 100)
        )
        state.present(photo)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let result = await state.performCopyRecognizedText(from: nsText, pasteboard: pasteboard)
        #expect(result != nil)
        let copied = pasteboard.string(forType: .string) ?? ""
        #expect(copied.localizedCaseInsensitiveContains("COPY OCR TEXT"))
        #expect(state.ocrFeedback?.kind == .success)

        // Blank image leaves pasteboard untouched and shows empty feedback.
        let blankBoard = NSPasteboard.withUniqueName()
        defer { blankBoard.releaseGlobally() }
        let blankResult = await state.performCopyRecognizedText(from: nsBlank, pasteboard: blankBoard)
        #expect(blankResult?.isEmpty == true)
        #expect(blankBoard.string(forType: .string) == nil)
        #expect(state.ocrFeedback?.kind == .empty)

        // Hidden-chat safety: locked engine refuses to copy and clears viewer state.
        let lockedEngine = ZaloEngine()
        lockedEngine.conversationActions.apply(json: ["hidden": ["enabled": true, "hasPin": true, "ids": ["h1"]]])
        let hiddenPhoto = MediaViewerItem(
            media: .photo(url: URL(string: "https://example.com/secret.jpg"), width: 900, height: 280, encrypted: false),
            conversationId: "h1",
            messageId: "m2",
            senderName: "An",
            date: Date(timeIntervalSince1970: 100)
        )
        state.present(hiddenPhoto, engine: lockedEngine)
        let lockedBoard = NSPasteboard.withUniqueName()
        defer { lockedBoard.releaseGlobally() }
        let blocked = await state.performCopyRecognizedText(from: nsText, pasteboard: lockedBoard)
        #expect(blocked == nil)
        #expect(lockedBoard.string(forType: .string) == nil)
        #expect(state.item == nil)
        #expect(state.ocrAnalysis == nil)
        #expect(!state.isOCREnabled)
    }
}
