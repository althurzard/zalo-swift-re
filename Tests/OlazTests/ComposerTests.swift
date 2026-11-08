import Testing
import Foundation
import AppKit
@testable import Olaz

/// The ZaloCap stdout framing (main.js "F58p"), composer outcome decoding and the reminder sheet's time chips.
@MainActor
struct ComposerTests {
    @Test func framesAreCutOutOfLogNoise() {
        var buffer = "\" 2026/10/27 - 08:15:09:198 | MainWindow::connectEvents\"\nSUCCESS_INIT\n"
            + #"@cap_resp@{"id":7,"data":"{\"cmd\":\"cap:recvReq\",\"data\":\"zalo:capture\"}"}@end_cap_resp@"#
            + "log line\n"
            + #"@cap_resp@{"id":8,"data":"{\"cmd\":\"cap:forwardScrs\",\"data\":\"/tmp/shot.png\"}"}@end_"#
        let first = ScreenCapture.frames(in: &buffer)
        #expect(first.count == 1)
        #expect(first.first?.command == "cap:recvReq")
        #expect(first.first?.data as? String == "zalo:capture")
        #expect((first.first?.id as? NSNumber)?.intValue == 7)
        // The second frame is incomplete: kept until its end marker arrives.
        #expect(buffer.hasPrefix("@cap_resp@"))
        buffer += "cap_resp@"
        let second = ScreenCapture.frames(in: &buffer)
        #expect(second.map(\.command) == ["cap:forwardScrs"])
        #expect(second.first?.data as? String == "/tmp/shot.png")
        #expect(buffer.isEmpty)
    }

    @Test func frameSplitAcrossChunksAndLineBreaks() {
        var buffer = "noise @cap_"
        #expect(ScreenCapture.frames(in: &buffer).isEmpty)
        buffer += "resp@{\"id\":1,\r\n\"data\":\"{\\\"cmd\\\":\\\"cap:acceptScrs\\\"}\"}@end_cap_resp@"
        let frames = ScreenCapture.frames(in: &buffer)
        #expect(frames.map(\.command) == ["cap:acceptScrs"])
        #expect(frames.first?.data == nil)
    }

    @Test func garbageWithoutFrameStaysBounded() {
        var buffer = String(repeating: "x", count: 5000)
        #expect(ScreenCapture.frames(in: &buffer).isEmpty)
        #expect(buffer.count <= "@cap_resp@".count)
    }

    @Test func outcomes() {
        #expect(ComposerOutcome(json: ["status": "done"]) == .done)
        #expect(ComposerOutcome(json: ["status": "cancelled"]) == .cancelled)
        // The official toast already said why (too many files).
        #expect(ComposerOutcome(json: ["status": "invalid"]) == .cancelled)
        #expect(ComposerOutcome(json: ["status": "invalid", "text": "Vui lòng nhập nội dung nhắc hẹn"]) == .failed("Vui lòng nhập nội dung nhắc hẹn"))
        #expect(ComposerOutcome(json: ["status": "locked", "text": "x"]) == .failed("x"))
        if case .pending = ComposerOutcome(json: ["status": "pending"]) {} else { Issue.record("pending") }
        #expect(ComposerOutcome(json: nil) == .failed(ComposerOutcome.genericFailure))
    }

    @Test func reminderTitleLimits() throws {
        let info = try #require(ReminderComposeInfo(json: ["allowed": true, "titleMaxChars": 10, "titleMaxBytes": 12]))
        #expect(!info.titleTooLong("abc"))
        #expect(info.titleTooLong(String(repeating: "a", count: 10)))
        // 5 characters, 15 UTF-8 bytes.
        #expect(info.titleTooLong("ệệệệệ"))
    }

    @Test func reminderChips() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 22, minute: 50, second: 41)))
        let in30 = ReminderComposeSheet.time(for: .in30, from: now)
        #expect(calendar.component(.second, from: in30) == 0)
        #expect(calendar.component(.hour, from: in30) == 23 && calendar.component(.minute, from: in30) == 20)
        let tomorrow = ReminderComposeSheet.time(for: .tomorrow9, from: now)
        #expect(calendar.component(.day, from: tomorrow) == 28 && calendar.component(.hour, from: tomorrow) == 9 && calendar.component(.minute, from: tomorrow) == 0)
    }

    @Test func clipboardPasteDistinguishesFinderFilesExcelSpreadsheetImageOnlyAndPlainText() throws {
        // Create a small 24x24 test PNG image.
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let png = try #require(ClipboardPasteContent.renderImageToPNG(image, opaqueWhiteBackground: true)?.data)

        // 1. Excel / Numbers copy: both PNG/TIFF image and plain text on pasteboard -> .spreadsheetOrRichImageAndText
        let excelPB = NSPasteboard.withUniqueName()
        excelPB.clearContents()
        excelPB.setData(png, forType: .png)
        excelPB.setString("Hạng mục\tSố lượng\r\nTáo\t12", forType: .string)
        let excelResult = ClipboardPasteContent.inspect(excelPB)
        if case .spreadsheetOrRichImageAndText(let imageData, let size, let text) = excelResult {
            #expect(!imageData.isEmpty)
            #expect(size.width > 0 && size.height > 0)
            #expect(text == "Hạng mục\tSố lượng\nTáo\t12")
        } else {
            Issue.record("Expected .spreadsheetOrRichImageAndText for Excel copy, got \(excelResult)")
        }

        // 2. Tabular spreadsheet copy without bitmap (e.g. Google Sheets / TSV table) -> synthesizes PNG and returns .spreadsheetOrRichImageAndText
        let sheetsPB = NSPasteboard.withUniqueName()
        sheetsPB.clearContents()
        sheetsPB.setString("Cột A\tCột B\nGiá trị 1\tGiá trị 2", forType: .string)
        let sheetsResult = ClipboardPasteContent.inspect(sheetsPB)
        if case .spreadsheetOrRichImageAndText(let imageData, let size, let text) = sheetsResult {
            #expect(!imageData.isEmpty)
            #expect(size.width >= 100 && size.height >= 40)
            #expect(text == "Cột A\tCột B\nGiá trị 1\tGiá trị 2")
        } else {
            Issue.record("Expected .spreadsheetOrRichImageAndText for tabular TSV copy, got \(sheetsResult)")
        }

        // 3. Screenshot / image-only copy -> .imageOnly
        let shotPB = NSPasteboard.withUniqueName()
        shotPB.clearContents()
        shotPB.setData(png, forType: .png)
        let shotResult = ClipboardPasteContent.inspect(shotPB)
        if case .imageOnly(let imageData, let size) = shotResult {
            #expect(!imageData.isEmpty)
            #expect(size.width > 0 && size.height > 0)
        } else {
            Issue.record("Expected .imageOnly for screenshot copy, got \(shotResult)")
        }

        // 4. Finder file copy (writes .fileURL + icon image + filename text) -> .files (must NOT be mistaken for Excel!)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-test-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let finderPB = NSPasteboard.withUniqueName()
        finderPB.clearContents()
        finderPB.writeObjects([tempFile as NSURL])
        finderPB.setData(png, forType: .tiff)
        finderPB.setString(tempFile.lastPathComponent, forType: .string)
        let finderResult = ClipboardPasteContent.inspect(finderPB)
        #expect(finderResult == .files([tempFile]))

        // 5. Plain text copy -> .plainText
        let textPB = NSPasteboard.withUniqueName()
        textPB.clearContents()
        textPB.setString("Xin chào buổi tối", forType: .string)
        #expect(ClipboardPasteContent.inspect(textPB) == .plainText("Xin chào buổi tối"))
    }

    @Test func prepareAttachmentURLsZipsDirectoriesAutomatically() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("OlazTestFolder-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let innerFile = folder.appendingPathComponent("note.txt")
        try Data("inside folder".utf8).write(to: innerFile)

        let prepared = ZaloEngine.prepareAttachmentURLs([folder])
        #expect(prepared.count == 1)
        let zipURL = try #require(prepared.first)
        #expect(zipURL.pathExtension.lowercased() == "zip")
        #expect(fm.fileExists(atPath: zipURL.path))
    }

    @Test func browserCopyImageAndRaycastHistoryStayImageOnlyAndValidatePasteMenu() throws {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        let png = try #require(ClipboardPasteContent.renderImageToPNG(image, opaqueWhiteBackground: true)?.data)

        // 1. Safari / Chrome "Copy Image" places both `.png` and a single-line URL `.string` on NSPasteboard -> must stay `.imageOnly`
        let browserPB = NSPasteboard.withUniqueName()
        browserPB.clearContents()
        browserPB.setData(png, forType: .png)
        browserPB.setString("https://example.com/photo.png", forType: .string)
        if case .imageOnly(let data, _) = ClipboardPasteContent.inspect(browserPB) {
            #expect(!data.isEmpty)
        } else {
            Issue.record("Expected .imageOnly for browser Copy Image with URL string")
        }

        // 2. Raycast Clipboard History places `.png`, `com.raycast.RestoredType`, and a temporary `.fileURL` -> must extract `.imageOnly`
        let tempCache = FileManager.default.temporaryDirectory.appendingPathComponent("raycast-\(UUID().uuidString).png")
        try png.write(to: tempCache)
        defer { try? FileManager.default.removeItem(at: tempCache) }

        let raycastPB = NSPasteboard.withUniqueName()
        raycastPB.clearContents()
        raycastPB.declareTypes([
            .png,
            NSPasteboard.PasteboardType("com.raycast.RestoredType"),
            .fileURL
        ], owner: nil)
        raycastPB.setData(png, forType: .png)
        raycastPB.setData(Data(), forType: NSPasteboard.PasteboardType("com.raycast.RestoredType"))
        raycastPB.setString(tempCache.absoluteString, forType: .fileURL)
        if case .imageOnly(let data, _) = ClipboardPasteContent.inspect(raycastPB) {
            #expect(!data.isEmpty)
        } else {
            Issue.record("Expected .imageOnly for Raycast restored image")
        }

        // 3. Single-cell Excel copy (image + HTML table marker) -> `.spreadsheetOrRichImageAndText`
        let singleCellExcelPB = NSPasteboard.withUniqueName()
        singleCellExcelPB.clearContents()
        singleCellExcelPB.setData(png, forType: .png)
        singleCellExcelPB.setString("<table><tr><td>42</td></tr></table>", forType: NSPasteboard.PasteboardType("public.html"))
        singleCellExcelPB.setString("42", forType: .string)
        if case .spreadsheetOrRichImageAndText = ClipboardPasteContent.inspect(singleCellExcelPB) {
            // ok
        } else {
            Issue.record("Expected .spreadsheetOrRichImageAndText for HTML table Excel copy")
        }

        // 4. FieldTextView readablePasteboardTypes and hasPasteableContent support image-only pasteboards (no .string)
        let imageOnlyPB = NSPasteboard.withUniqueName()
        imageOnlyPB.clearContents()
        imageOnlyPB.setData(png, forType: .png)
        #expect(ClipboardPasteContent.hasPasteableContent(imageOnlyPB))

        let tv = ComposerTextView.FieldTextView()
        tv.isRichText = false
        tv.importsGraphics = false
        #expect(tv.readablePasteboardTypes.contains(.png))
        #expect(tv.readablePasteboardTypes.contains(.tiff))
        #expect(tv.readablePasteboardTypes.contains(.fileURL))
    }

    @MainActor @Test func stagedImagesStageRemoveAndTakePerConversation() {
        let engine = ZaloEngine()
        let first = NSImage(size: NSSize(width: 4, height: 4))
        let second = NSImage(size: NSSize(width: 8, height: 8))
        engine.stageImages([first, second], in: "conv-1")
        #expect(engine.stagedImages["conv-1"]?.count == 2)
        #expect(engine.stagedImages["conv-2"] == nil)

        if let firstId = engine.stagedImages["conv-1"]?.first?.id {
            engine.removeStagedImage(firstId, in: "conv-1")
        }
        #expect(engine.stagedImages["conv-1"]?.count == 1)

        let taken = engine.takeStagedImages(for: "conv-1")
        #expect(taken.count == 1)
        #expect(engine.stagedImages["conv-1"] == nil)

        engine.restoreStagedImages(taken, in: "conv-1")
        #expect(engine.stagedImages["conv-1"]?.count == 1)

        engine.clearStagedImages(in: "conv-1")
        #expect(engine.stagedImages["conv-1"] == nil)
    }

    @MainActor @Test func fieldTextViewReturnAndEnterKeyHandlingWithStagedImagesAndIME() throws {
        let tv = ComposerTextView.FieldTextView()
        tv.isEditable = true
        var sentCount = 0
        tv.onSend = { sentCount += 1 }
        tv.string = "Xin chào"

        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        let enterEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 76
        ))
        let shiftReturn = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))

        // 1. Without marked text, Return and Numpad Enter trigger onSend
        tv.keyDown(with: returnEvent)
        #expect(sentCount == 1)
        tv.keyDown(with: enterEvent)
        #expect(sentCount == 2)

        // 2. Modifiers like Shift+Return do not send
        tv.keyDown(with: shiftReturn)
        #expect(sentCount == 2)

        // 3. IME active (hasMarkedText) without staged images: Return should NOT trigger send (lets IME commit)
        tv.setMarkedText("tiế", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(tv.hasMarkedText())
        tv.hasStagedImages = false
        tv.keyDown(with: returnEvent)
        #expect(sentCount == 2)

        // 4. IME active with staged images: Return discards marked text and sends immediately
        tv.setMarkedText("tiế", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(tv.hasMarkedText())
        tv.hasStagedImages = true
        tv.keyDown(with: returnEvent)
        #expect(sentCount == 3)
        #expect(!tv.hasMarkedText())
    }
}
