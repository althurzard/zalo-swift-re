import AppKit
import UniformTypeIdentifiers

// Composer "+" actions — Ảnh hoặc Video, Tệp, Chụp màn hình, Danh thiếp, Nhắc hẹn — bridged to `HostScripts/composer-adapter.js`
// (`window.__zaloCompose`). Picked files reach the page as browser `File`s: the adapter clicks a hidden file input and
// `OfficialClientHost` answers its open panel with the URLs picked here. Screenshots come from the official ZaloCap tool
// (ScreenCapture.swift).

/// Result of a composer action (composer-adapter.js `{status, text}`).
enum ComposerOutcome: Equatable, Sendable {
    case done
    /// Nothing was picked, or the official client already said why (its toast reached the screen).
    case cancelled
    case failed(String)
    /// Started but not answered in time: it may still happen, so the wording never invites a retry.
    case pending(String)

    static let genericFailure = "Không gửi được. Hãy thử lại."

    init(json: Any?) {
        guard let root = json as? [String: Any], let status = root["status"] as? String else {
            self = .failed(Self.genericFailure)
            return
        }
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case "done": self = .done
        case "cancelled": self = .cancelled
        case "invalid": self = text.map(Self.failed) ?? .cancelled
        case "pending": self = .pending(text ?? CardActionOutcome.defaultPending)
        case "not-open": self = .failed("Cuộc trò chuyện chưa sẵn sàng, hãy thử lại sau giây lát.")
        case "not-ready": self = .failed("Zalo chưa sẵn sàng, hãy thử lại sau giây lát.")
        default: self = .failed(text ?? Self.genericFailure)
        }
    }

    var logName: String {
        switch self {
        case .done: "done"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}

/// An official confirm asked while a composer action ran (e.g. "Gửi dưới dạng file" for a photo over the limit).
struct ComposerConfirm: Identifiable, Equatable {
    let id: String
    var conversationId: String
    var title: String
    var message: String
    var ok: String
    var cancel: String
}

/// "Chia sẻ" from the screenshot tool: the shot (or its recognised text) waiting for the conversations to send it to.
struct ScreenshotShare: Identifiable, Equatable {
    let id = UUID()
    var image: URL?
    var text: String?
    var conversationId: String
}

/// An image pasted with ⌘V waiting in the conversation's composer tray (`StagedImageStrip`) to be sent with an optional caption.
struct StagedImage: Identifiable, Equatable {
    let id: UUID
    let image: NSImage
    let fileURL: URL

    init(id: UUID = UUID(), image: NSImage, fileURL: URL) {
        self.id = id
        self.image = image
        self.fileURL = fileURL
    }

    static func == (lhs: StagedImage, rhs: StagedImage) -> Bool {
        lhs.id == rhs.id && lhs.fileURL == rhs.fileURL
    }
}

/// My own contact card as the official "Gửi danh thiếp" modal would send it.
struct MyCardInfo: Equatable {
    var uid: String
    var name: String
    var avatar: URL?
    /// Display form of my number (official `getPhoneNumberPro`), "" when the profile has none.
    var phone: String
    /// The official "Gửi kèm số điện thoại" choice remembered for this account.
    var withPhone: Bool

    init?(json: Any?) {
        guard let row = json as? [String: Any], let uid = row["uid"] as? String, !uid.isEmpty else { return nil }
        self.uid = uid
        name = row["name"] as? String ?? ""
        avatar = (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        phone = row["phone"] as? String ?? ""
        withPhone = row["withPhone"] as? Bool ?? true
    }
}

/// What the official chat-bar gate and compose modal allow for a conversation.
struct ReminderComposeInfo: Equatable {
    var allowed: Bool
    /// OA conversations have no "Nhắc hẹn" item at all.
    var hidden: Bool
    /// Why it is not allowed (official warning), "" when there is nothing to say.
    var text: String
    var isGroup: Bool
    /// Group reminders are pinned (official default) when I may pin; `pinToggle` = the modal shows the checkbox.
    var canPin: Bool
    var pinToggle: Bool
    var titleMaxChars: Int
    var titleMaxBytes: Int

    init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        allowed = row["allowed"] as? Bool ?? false
        hidden = row["hidden"] as? Bool ?? false
        text = row["text"] as? String ?? ""
        isGroup = row["isGroup"] as? Bool ?? false
        canPin = row["canPin"] as? Bool ?? false
        pinToggle = row["pinToggle"] as? Bool ?? false
        titleMaxChars = (row["titleMaxChars"] as? NSNumber)?.intValue ?? 3000
        titleMaxBytes = (row["titleMaxBytes"] as? NSNumber)?.intValue ?? 3700
    }

    /// Official limits: fewer than `titleMaxChars` UTF-16 units of raw text and at most `titleMaxBytes` UTF-8 bytes trimmed.
    func titleTooLong(_ raw: String) -> Bool {
        raw.utf16.count >= titleMaxChars || raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > titleMaxBytes
    }
}

/// Repeat choices of the legacy compose modal (the weekday picker, 4, is not reachable there).
enum ReminderRepeat: Int, CaseIterable, Identifiable {
    case none = 0, daily, weekly, monthly
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: "Không lặp lại"
        case .daily: "Hàng ngày"
        case .weekly: "Hàng tuần"
        case .monthly: "Hàng tháng"
        }
    }
}

extension ZaloEngine {
    static let maxStagedImages = 50

    // MARK: Attachments

    /// "Ảnh hoặc Video": photos through the official photo button's path, videos and other files as files.
    func sendMedia(_ urls: [URL], to id: String, caption: String? = nil) async -> ComposerOutcome {
        let prepared = Self.prepareAttachmentURLs(urls, convertUnsupportedPhotos: true)
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let args: [Any] = trimmed.isEmpty ? [id] : [id, trimmed]
        return await composeWithFiles("sendMedia", args, files: prepared)
    }

    func stageImageFile(_ fileURL: URL, image: NSImage? = nil, in id: String) {
        guard !id.isEmpty else { return }
        var current = stagedImages[id] ?? []
        guard current.count < Self.maxStagedImages else {
            CardActionCenter.shared.show("Chỉ gửi được tối đa \(Self.maxStagedImages) ảnh mỗi lần.", in: id)
            return
        }
        guard let resolvedImage = image ?? NSImage(contentsOf: fileURL) else { return }
        let resolvedURL = fileURL.resolvingSymlinksInPath()
        MediaLoader.allowUserAttachment(resolvedURL)
        current.append(StagedImage(image: resolvedImage, fileURL: resolvedURL))
        stagedImages[id] = current
    }

    func stageImages(_ images: [NSImage], in id: String) {
        guard !id.isEmpty, !images.isEmpty else { return }
        var current = stagedImages[id] ?? []
        let remaining = max(0, Self.maxStagedImages - current.count)
        guard remaining > 0 else {
            CardActionCenter.shared.show("Chỉ gửi được tối đa \(Self.maxStagedImages) ảnh mỗi lần.", in: id)
            return
        }
        for img in images.prefix(remaining) {
            let pngData = ClipboardPasteContent.renderImageToPNG(img, opaqueWhiteBackground: false)?.data
                ?? img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            let fileURL = pngData.flatMap { Self.writeTemporaryPasteImage($0, prefix: "clipboard") }
                ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                    .appendingPathComponent("OlazAttachments/staged-\(UUID().uuidString).png")
            MediaLoader.allowUserAttachment(fileURL)
            current.append(StagedImage(image: img, fileURL: fileURL))
        }
        stagedImages[id] = current
    }

    func removeStagedImage(_ itemId: UUID, in id: String) {
        guard var current = stagedImages[id] else { return }
        current.removeAll { $0.id == itemId }
        stagedImages[id] = current.isEmpty ? nil : current
    }

    func clearStagedImages(in id: String) {
        stagedImages[id] = nil
    }

    func takeStagedImages(for id: String) -> [StagedImage] {
        stagedImages.removeValue(forKey: id) ?? []
    }

    func restoreStagedImages(_ items: [StagedImage], in id: String) {
        guard !id.isEmpty, !items.isEmpty else { return }
        let existing = stagedImages[id] ?? []
        stagedImages[id] = Array((items + existing).prefix(Self.maxStagedImages))
    }

    /// "Tệp": the official file button's path.
    func sendFiles(_ urls: [URL], to id: String) async -> ComposerOutcome {
        let prepared = Self.prepareAttachmentURLs(urls, convertUnsupportedPhotos: false)
        return await composeWithFiles("sendFiles", [id], files: prepared)
    }

    /// Prepares picked, dropped, or pasted file/directory URLs for WebKit's `<input type=file>`:
    /// - Directories and macOS packages (`.app`, `.bundle`, folders) are compressed into a temporary `.zip` archive via `ditto`
    ///   because browser `FileReader` cannot read raw directories.
    /// - When `convertUnsupportedPhotos` is true, macOS raster image formats outside Zalo's web `supportPhoto` list
    ///   (`.heic`, `.heif`, `.tiff`, `.tif`, `.bmp`) are converted to `.png` so they send as inline photo messages.
    static func prepareAttachmentURLs(_ urls: [URL], convertUnsupportedPhotos: Bool = true) -> [URL] {
        let fm = FileManager.default
        let convertExts: Set<String> = ["heic", "heif", "tiff", "tif", "bmp"]
        var out: [URL] = []
        for url in urls where url.isFileURL {
            guard fm.fileExists(atPath: url.path) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true || values?.isPackage == true {
                if let zipped = zipDirectoryForAttachment(url) {
                    out.append(zipped)
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if convertUnsupportedPhotos, convertExts.contains(ext),
               let image = NSImage(contentsOf: url),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let stem = url.deletingPathExtension().lastPathComponent
                if let converted = writeTemporaryPasteImage(png, prefix: stem.isEmpty ? "photo" : stem) {
                    out.append(converted)
                    continue
                }
            }
            let resolved = url.resolvingSymlinksInPath()
            MediaLoader.allowUserAttachment(resolved)
            out.append(resolved)
        }
        return out
    }

    /// Writes PNG image data (from clipboard paste, Excel table render, or drag-and-drop) to a temporary `.png` file.
    static func writeTemporaryPasteImage(_ pngData: Data, prefix: String = "clipboard") -> URL? {
        guard !pngData.isEmpty else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("OlazAttachments", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safePrefix = prefix.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let stamp = Int((Date().timeIntervalSince1970 * 1000).rounded())
        let fileURL = dir.appendingPathComponent("\(safePrefix)-\(stamp)-\(UUID().uuidString.prefix(6)).png")
        do {
            try pngData.write(to: fileURL, options: .atomic)
            return fileURL.resolvingSymlinksInPath()
        } catch {
            return nil
        }
    }

    private static func zipDirectoryForAttachment(_ directoryURL: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OlazAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = directoryURL.lastPathComponent.isEmpty ? "Folder" : directoryURL.lastPathComponent
        let zipURL = dir.appendingPathComponent("\(baseName).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directoryURL.path, zipURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, fm.fileExists(atPath: zipURL.path) else { return nil }
            return zipURL.resolvingSymlinksInPath()
        } catch {
            return nil
        }
    }

    /// Resolves `[NSItemProvider]` from a SwiftUI `.onDrop` modifier into local file URLs (or temporary PNG files for dropped images)
    /// and sends them to `conversationId`.
    @discardableResult
    func handleDroppedProviders(_ providers: [NSItemProvider], in conversationId: String) -> Bool {
        guard !conversationId.isEmpty, !providers.isEmpty else { return false }
        let usable = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        }
        guard !usable.isEmpty else { return false }
        Task { @MainActor in
            var resolvedURLs: [URL] = []
            for provider in usable {
                if let url = await Self.extractDroppedURL(from: provider) {
                    resolvedURLs.append(url)
                }
            }
            guard !resolvedURLs.isEmpty else { return }
            let outcome = await self.sendMedia(resolvedURLs, to: conversationId)
            self.report(outcome, in: conversationId)
        }
        return true
    }

    private static func extractDroppedURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let fileURL: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { coding, _ in
                    if let url = coding as? URL, url.isFileURL {
                        continuation.resume(returning: url)
                    } else if let data = coding as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                        continuation.resume(returning: url)
                    } else if let str = coding as? String,
                              let url = URL(string: str), url.isFileURL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let fileURL { return fileURL }
        }
        for ut in [UTType.png, UTType.tiff, UTType.image, UTType.pdf] where provider.hasItemConformingToTypeIdentifier(ut.identifier) {
            let rawData: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: ut.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let rawData, let img = NSImage(data: rawData),
               let png = ClipboardPasteContent.renderImageToPNG(img, opaqueWhiteBackground: ut == .pdf)?.data,
               let tempURL = writeTemporaryPasteImage(png, prefix: "dropped") {
                return tempURL
            }
        }
        return nil
    }

    // MARK: Screenshot

    /// Starts the official screenshot tool for the conversation `id`; the result arrives through `handleCapture`.
    func startScreenCapture(in id: String, withOlaz: Bool) {
        screenCapture().start(in: id, withOlaz: withOlaz)
    }

    func shareScreenshot(_ share: ScreenshotShare, to ids: [String]) async -> ComposerOutcome {
        if let text = share.text {
            var sent = 0
            for id in ids where await sendText(text, to: id) { sent += 1 }
            return sent > 0 ? .done : .failed(ComposerOutcome.genericFailure)
        }
        guard let image = share.image else { return .cancelled }
        return await composeWithFiles("shareShot", [ids], files: [image])
    }

    private func screenCapture() -> ScreenCapture {
        if let screenCaptureTool { return screenCaptureTool }
        let tool = ScreenCapture()
        tool.log = { EngineLog.shared.write($0) }
        tool.onOutcome = { [weak self] outcome in self?.handleCapture(outcome) }
        screenCaptureTool = tool
        return tool
    }

    private func handleCapture(_ outcome: ScreenCapture.Outcome) {
        switch outcome {
        case .send(let url, let id), .sendToMe(let url, let id):
            var toMe = false
            if case .sendToMe = outcome { toMe = true }
            Task {
                let result = await composeWithFiles("sendShot", [id, toMe], files: [url])
                report(result, in: id)
            }
        case .share(let url, let id):
            screenshotShare = ScreenshotShare(image: url, text: nil, conversationId: id)
        case .shareText(let text, let id):
            screenshotShare = ScreenshotShare(image: nil, text: text, conversationId: id)
        case .noPermission:
            screenCaptureNeedsPermission = true
        case .failed(let text, let id):
            CardActionCenter.shared.show(text, in: id.isEmpty ? nil : id)
        }
    }

    // MARK: Danh thiếp

    func myCard() async -> MyCardInfo? {
        let answer = await raceTimeout(15) { [self] in JSBox(value: await callCompose("myCard", [])) }
        return MyCardInfo(json: answer?.value)
    }

    func sendMyCard(to id: String, withPhone: Bool) async -> ComposerOutcome {
        await compose("sendMyCard", [id, withPhone], timeout: 45)
    }

    // MARK: Nhắc hẹn

    func reminderComposeInfo(for id: String) async -> ReminderComposeInfo? {
        let answer = await raceTimeout(15) { [self] in JSBox(value: await callCompose("reminderInfo", [id])) }
        return ReminderComposeInfo(json: answer?.value)
    }

    func createReminder(in id: String, title: String, start: Date, repeat rule: ReminderRepeat, pin: Bool) async -> ComposerOutcome {
        let options: [String: Any] = ["title": title, "startTime": (start.timeIntervalSince1970 * 1000).rounded(),
                                      "repeat": rule.rawValue, "needPin": pin]
        return await compose("createReminder", [id, options], timeout: 40)
    }

    // MARK: Official confirms / toasts

    func answerComposerConfirm(_ confirm: ComposerConfirm, ok: Bool) {
        guard composerConfirm?.id == confirm.id else { return }
        composerConfirm = nil
        Task { _ = await callCompose("answer", [confirm.id, ok]) }
        guard !queuedComposerConfirms.isEmpty else { return }
        // The next one after a beat, so the alert closes and opens again with its own text.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.composerConfirm == nil, !self.queuedComposerConfirms.isEmpty else { return }
            self.composerConfirm = self.queuedComposerConfirms.removeFirst()
        }
    }

    /// A page reload: its unanswered confirms are gone with it.
    func dropComposerConfirms() {
        composerConfirm = nil
        queuedComposerConfirms = []
    }

    func handleCompose(state: [String: Any]) {
        guard let event = state["compose"] as? [String: Any] else { return }
        let conversation = (event["convId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch event["kind"] as? String {
        case "toast":
            if let text = event["text"] as? String, !text.isEmpty { CardActionCenter.shared.show(text, in: conversation) }
        case "confirm":
            guard let token = event["token"] as? String else { return }
            let confirm = ComposerConfirm(id: token, conversationId: conversation ?? "",
                                          title: event["title"] as? String ?? "", message: event["message"] as? String ?? "",
                                          ok: event["ok"] as? String ?? "OK", cancel: event["cancel"] as? String ?? "Hủy")
            // One at a time, in the order asked.
            if composerConfirm == nil { composerConfirm = confirm } else { queuedComposerConfirms.append(confirm) }
        default:
            break
        }
    }

    /// Logout: nothing of the previous account may be asked or shared in the next.
    func resetComposer() {
        dropComposerConfirms()
        screenshotShare = nil
        screenCaptureNeedsPermission = false
        stagedImages = [:]
    }

    /// Shows a failure or pending text for a composer action as the conversation's toast.
    func report(_ outcome: ComposerOutcome, in id: String) {
        switch outcome {
        case .failed(let text), .pending(let text): CardActionCenter.shared.show(text, in: id.isEmpty ? nil : id)
        case .done, .cancelled: break
        }
    }

    #if DEBUG
    /// Dev evaluation channel only (`compose.json`): a composer action with `files` as the user's pick.
    func devCompose(_ method: String, _ args: [Any], files: [URL]) async -> String {
        if method == "screenshot", let id = args.first as? String {
            startScreenCapture(in: id, withOlaz: (args.dropFirst().first as? Bool) ?? true)
            return "started"
        }
        let outcome = files.isEmpty ? await compose(method, args, timeout: 60) : await composeWithFiles(method, args, files: files)
        return "\(outcome)"
    }
    #endif

    // MARK: Calls into composer-adapter.js

    private func composeWithFiles(_ method: String, _ args: [Any], files: [URL]) async -> ComposerOutcome {
        guard !files.isEmpty else { return .cancelled }
        // Photos are processed (resized) before the call returns; the uploads themselves continue in the page.
        let answer = await raceTimeout(45) { [self] in JSBox(value: await callCompose(method, args, files: files)) }
        guard let answer else {
            EngineLog.shared.write("compose \(method) files=\(files.count) → timeout")
            return .pending(CardActionOutcome.noAnswerText)
        }
        var outcome = ComposerOutcome(json: answer.value)
        // Files were picked but the page's file input received none: say so instead of nothing.
        if outcome == .cancelled, (answer.value as? [String: Any])?["status"] as? String == "cancelled" {
            outcome = .failed("Không đọc được tệp đã chọn. Hãy thử lại.")
        }
        EngineLog.shared.write("compose \(method) files=\(files.count) → \(outcome.logName)")
        return outcome
    }

    private func compose(_ method: String, _ args: [Any], timeout: Double) async -> ComposerOutcome {
        let answer = await raceTimeout(timeout) { [self] in JSBox(value: await callCompose(method, args)) }
        guard let answer else { return .pending(CardActionOutcome.noAnswerText) }
        let outcome = ComposerOutcome(json: answer.value)
        EngineLog.shared.write("compose \(method) → \(outcome.logName)")
        return outcome
    }

    private func callCompose(_ method: String, _ args: [Any], files: [URL]? = nil) async -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        // The adapter clicks its file input synchronously in this call: nothing may be awaited before it.
        let script = "const c = window.__zaloCompose; if (!c || !c.\(method)) return null; return await c.\(method)(...\(json));"
        guard let host else { return nil }
        if let files { return await host.evaluate(script, providingFiles: files) }
        return await host.evaluate(script)
    }
}
