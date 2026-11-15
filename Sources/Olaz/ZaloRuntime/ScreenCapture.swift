import AppKit
import CoreGraphics

/// The official screenshot tool, `ZaloCap` (a Qt app in Zalo.app's `ZaloHelper.app`), driven the way Zalo PC's main process
/// drives it (main.js module "F58p"):
/// - started once as `ZaloCap zalo2017 <log dir>` and kept running (restarted on demand after it exits);
/// - commands are JSON lines on stdin, `{"cmd": "zalo:capture", "data": {language, enableSend2Me, enableAccept, viMyCloud, enMyCloud}}`;
/// - answers are framed on stdout as `@cap_resp@{"id": n, "data": "<JSON {cmd, data}>"}@end_cap_resp@`, each acknowledged with
///   `{"cmd": "zalo:recvAck", "data": n}`.
///
/// The tool draws its own selection / annotation toolbar. "Gửi" (`cap:acceptScrs`) and "Gửi vào Cloud của tôi" (`cap:send2meScrs`)
/// leave the shot on the clipboard, "Chia sẻ" (`cap:forwardScrs`) hands over an image path, the OCR "share text" (`cap:forwardTextScrs`)
/// its text. Main's "without Zalo" mode hides the windows first and restores them when the tool is done (`cap:cancelScrs` /
/// `cap:quitAction` / exit). OCR availability checks `libzocr_vision.dylib` next to `ZaloCap` and enables in-process OCR when present.
@MainActor
final class ScreenCapture {
    enum Outcome {
        /// "Gửi": the shot (a PNG written from the clipboard) for the conversation the capture started from.
        case send(URL, conversationId: String)
        /// "Gửi vào Cloud của tôi".
        case sendToMe(URL, conversationId: String)
        /// "Chia sẻ": the user picks the conversations.
        case share(URL, conversationId: String)
        /// "Chia sẻ" of the recognised text.
        case shareText(String, conversationId: String)
        /// The tool reported it may not record the screen (System Settings ▸ Privacy ▸ Screen Recording).
        case noPermission
        /// Something failed before the tool could run (helper missing, clipboard empty…), with the text to show.
        case failed(String, conversationId: String)
    }

    var onOutcome: ((Outcome) -> Void)?
    var log: (String) -> Void = { _ in }

    private let executable: URL
    private let logDirectory: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = ""
    /// The conversation of the running capture; nil while idle.
    private var conversationId: String?
    private var hidOlaz = false
    private var terminationObserver: NSObjectProtocol?

    nonisolated static func helperExecutable(appURL: URL = OfficialZaloInstall.defaultAppURL) -> URL {
        appURL.appendingPathComponent("Contents/ZaloHelper.app/Contents/MacOS/ZaloCap")
    }

    /// Path to `libzocr_vision.dylib` inside `ZaloHelper.app/Contents/Frameworks`, resolved relative to `ZaloCap`.
    nonisolated static func ocrLibraryURL(forExecutable executable: URL) -> URL {
        executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks/libzocr_vision.dylib")
    }

    nonisolated static func hasOCRLibrary(forExecutable executable: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: ocrLibraryURL(forExecutable: executable).path) {
            return true
        }
        let fallback = executable
            .deletingLastPathComponent()
            .appendingPathComponent("Contents/Frameworks/libzocr_vision.dylib")
        return fm.fileExists(atPath: fallback.path)
    }

    nonisolated static func ocrAvailabilityPayload(id: String, helperExists: Bool) -> [String: Any] {
        if helperExists {
            return [
                "cmd": "zalo:ocrAvailability",
                "data": [
                    "idReq": id,
                    "enabled": true,
                    "transport": "in-process",
                    "canShareOCRContent": true,
                ] as [String: Any],
            ]
        }
        return [
            "cmd": "zalo:ocrAvailability",
            "data": [
                "idReq": id,
                "enabled": false,
                "reason": "unsupported",
            ] as [String: Any],
        ]
    }

    init(executable: URL = ScreenCapture.helperExecutable(),
         logDirectory: URL = ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("logs/capture", isDirectory: true)) {
        self.executable = executable
        self.logDirectory = logDirectory
        // Main's `stop()`: the tool does not outlive the app.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    var isCapturing: Bool { conversationId != nil }

    /// `startScreenshot(params, convId)`: `withOlaz` false hides Olaz's windows first (main's "WithoutZalo").
    func start(in conversationId: String, withOlaz: Bool) {
        guard self.conversationId == nil else { log("capture: busy"); return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            onOutcome?(.failed("Không tìm thấy công cụ chụp màn hình của Zalo (ZaloHelper.app/Contents/MacOS/ZaloCap). Hãy mở lại Olaz để cài lại.", conversationId: conversationId))
            return
        }
        // The tool records the screen on Olaz's behalf (Olaz is the responsible process): without the permission it would only
        // see the wallpaper. Ask macOS once; the tool itself reports `cap:noPermission` too.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            onOutcome?(.noPermission)
            return
        }
        do { try launchIfNeeded() } catch {
            log("capture: launch failed \(error.localizedDescription)")
            onOutcome?(.failed("Không mở được công cụ chụp màn hình.", conversationId: conversationId))
            return
        }
        self.conversationId = conversationId
        let request: [String: Any] = [
            "cmd": "zalo:capture",
            "data": ["language": "_vn", "enableSend2Me": 1, "enableAccept": 1,
                     "viMyCloud": "Gửi vào Cloud của tôi", "enMyCloud": "Send to My Cloud"],
        ]
        if withOlaz {
            send(request)
        } else {
            // Main hides the window and starts the capture 200 ms after its "hide" event.
            hidOlaz = true
            NSApp.hide(nil)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.send(request)
            }
        }
    }

    func shutdown() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdin = nil
        finish()
    }

    // MARK: Process

    private func launchIfNeeded() throws {
        if let process, process.isRunning { return }
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["zalo2017", logDirectory.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        // A write after the tool died must fail with EPIPE, not raise SIGPIPE (which would end Olaz).
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // stdout carries the framed answers next to the tool's log lines; neither is logged verbatim (paths, OCR text).
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === finished else { return }
                    self.log("capture: tool exited \(status)")
                    self.process = nil
                    self.stdin = nil
                    self.finish()
                }
            }
        }
        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
        buffer = ""
        log("capture: tool started")
    }

    private func send(_ request: [String: Any]) {
        guard let stdin, process?.isRunning == true, let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        do { try stdin.write(contentsOf: data + Data("\n".utf8)) } catch { log("capture: write failed") }
    }

    // MARK: Answers

    /// A decoded `@cap_resp@…@end_cap_resp@` frame.
    struct Frame {
        var id: Any
        var command: String
        var data: Any?
    }

    /// Takes every complete frame out of `buffer` (what precedes a frame is the tool's log output and is dropped).
    static func frames(in buffer: inout String) -> [Frame] {
        let start = "@cap_resp@", end = "@end_cap_resp@"
        var found: [Frame] = []
        while let open = buffer.range(of: start) {
            guard let close = buffer.range(of: end, range: open.upperBound..<buffer.endIndex) else {
                buffer = String(buffer[open.lowerBound...])
                return found
            }
            // Main strips line breaks from the chunk before parsing.
            let body = buffer[open.upperBound..<close.lowerBound].replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            buffer = String(buffer[close.upperBound...])
            guard let outer = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any], let id = outer["id"] else { continue }
            var command = "", payload: Any?
            if let text = outer["data"] as? String, let inner = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                command = inner["cmd"] as? String ?? ""
                payload = inner["data"]
            }
            found.append(Frame(id: id, command: command, data: payload))
        }
        // No frame start: keep only a tail that could be the beginning of one.
        if buffer.count > start.count { buffer = String(buffer.suffix(start.count)) }
        return found
    }

    private func consume(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        for frame in Self.frames(in: &buffer) {
            send(["cmd": "zalo:recvAck", "data": frame.id])
            handle(frame)
        }
    }

    private func handle(_ frame: Frame) {
        let conversation = conversationId ?? ""
        switch frame.command {
        case "cap:acceptScrs":
            deliver { .send($0, conversationId: conversation) }
        case "cap:send2meScrs":
            deliver { .sendToMe($0, conversationId: conversation) }
        case "cap:forwardScrs":
            let path = (frame.data as? String).map { $0.hasPrefix("file://") ? URL(string: $0)?.path ?? $0 : $0 }
            if let path, FileManager.default.fileExists(atPath: path), let url = Self.copyShot(from: URL(fileURLWithPath: path)) {
                finish()
                onOutcome?(.share(url, conversationId: conversation))
            } else {
                deliver { .share($0, conversationId: conversation) }
            }
        case "cap:forwardTextScrs":
            var text = frame.data as? String ?? ""
            // Main: a JSON payload carries the text in `text`.
            if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { text = object["text"] as? String ?? "" }
            finish()
            if !text.isEmpty { onOutcome?(.shareText(text, conversationId: conversation)) }
        case "cap:cancelScrs", "cap:quitAction":
            finish()
        case "cap:noPermission":
            finish()
            onOutcome?(.noPermission)
        case "cap:ocrRequest":
            let request = (frame.data as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? frame.data as? [String: Any]
            if let id = request?["idReq"] as? String, !id.isEmpty {
                send(Self.ocrAvailabilityPayload(id: id, helperExists: Self.hasOCRLibrary(forExecutable: executable)))
            }
        default:
            // cap:recvReq / cap:running / cap:copyScrs / cap:saveScrs / zalo:changeDataClipboard / cap:osEvent / cap:logActionById
            break
        }
    }

    /// The shot the tool left on the clipboard, written as PNG (main: `getClipboardImage().toPNG()`).
    private func deliver(_ outcome: (URL) -> Outcome) {
        let conversation = conversationId ?? ""
        finish()
        guard let png = Self.clipboardPNG(), let url = Self.writeShot(png) else {
            onOutcome?(.failed("Không lấy được ảnh chụp màn hình. Hãy thử lại.", conversationId: conversation))   // STR_TOAST_ERROR
            return
        }
        onOutcome?(outcome(url))
    }

    /// Ends the running capture and brings Olaz back (main's restore + `bringOnTop`).
    private func finish() {
        guard conversationId != nil || hidOlaz else { return }
        conversationId = nil
        if hidOlaz { hidOlaz = false; NSApp.unhide(nil) }
        NSApp.activate()
    }

    // MARK: Files

    static func clipboardPNG(_ pasteboard: NSPasteboard = .general) -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty { return png }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Shots live in the temporary directory, one folder each (the page reads them while it uploads); older ones are removed.
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-screenshots", isDirectory: true)

    static func writeShot(_ png: Data) -> URL? {
        prune()
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("screenshot.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
            return url
        } catch { return nil }
    }

    static func copyShot(from source: URL) -> URL? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        if source.pathExtension.lowercased() == "png" { return writeShot(data) }
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return writeShot(png)
    }

    private static func prune() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: folder) }
        }
    }
}
