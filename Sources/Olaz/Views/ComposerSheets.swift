import SwiftUI
import AppKit

// Sheets of the composer's "+" menu: my contact card, a new reminder, and the conversation picker of the screenshot tool's
// "Chia sẻ". They gather what the official modals gather; sending goes through `ZaloEngine+Composer.swift`.

// MARK: - Danh thiếp

/// "Gửi danh thiếp" for my own card: the payload of the official SHARE_CONTACT modal, with its "Gửi kèm số điện thoại" option.
struct MyCardSheet: View {
    let conversationId: String
    let conversationName: String

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var card: MyCardInfo?
    @State private var loaded = false
    @State private var withPhone = true
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Gửi danh thiếp") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let card {
                    preview(card)
                    Toggle("Gửi kèm số điện thoại", isOn: $withPhone)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                        .disabled(card.phone.isEmpty)
                    Text("Danh thiếp của bạn sẽ được gửi tới \(conversationName).")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if loaded {
                    Label("Chưa đọc được hồ sơ của bạn từ Zalo. Hãy thử lại sau giây lát.", systemImage: "info.circle.fill")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .padding(16)
            Divider()
            SheetFooter(message: message, action: "Gửi", busy: busy, disabled: card == nil, cancel: { dismiss() }) {
                Task { await send() }
            }
        }
        .frame(width: 380)
        .task {
            card = await engine.myCard()
            withPhone = (card?.withPhone ?? true) && !(card?.phone.isEmpty ?? true)
            loaded = true
        }
    }

    private func preview(_ card: MyCardInfo) -> some View {
        HStack(spacing: 12) {
            RemoteAvatar(url: card.avatar, name: card.name, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name.isEmpty ? "Tài khoản của bạn" : card.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(withPhone && !card.phone.isEmpty ? card.phone : "Danh thiếp Zalo")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "person.crop.rectangle").font(.system(size: 18)).foregroundStyle(.tint)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private func send() async {
        guard card != nil, !busy else { return }
        busy = true; message = nil
        let outcome = await engine.sendMyCard(to: conversationId, withPhone: withPhone)
        busy = false
        switch outcome {
        case .done, .cancelled: dismiss()
        case .pending(let text): CardActionCenter.shared.show(text, in: conversationId); dismiss()
        case .failed(let text): message = text
        }
    }
}

// MARK: - Nhắc hẹn

/// "Tạo nhắc hẹn" (the official legacy compose modal): content, a time chip or a picked time, repeat, and the group pin.
struct ReminderComposeSheet: View {
    let conversationId: String
    let info: ReminderComposeInfo

    enum TimeChoice: Hashable { case in15, in30, tomorrow9, custom }

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var choice = TimeChoice.in30
    @State private var start = ReminderComposeSheet.time(for: .in30)
    @State private var rule = ReminderRepeat.none
    @State private var pin = true
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDiscard = false
    /// Re-evaluates "is the time still in the future" while the sheet stays open.
    @State private var now = Date()

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var issue: String? {
        if trimmed.isEmpty { return "Vui lòng nhập nội dung nhắc hẹn" }
        if info.titleTooLong(title) { return "Bạn đã nhập quá số kí tự cho phép" }
        if start < now.addingTimeInterval(-59) { return "Vui lòng chọn thời gian tương lai" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Tạo nhắc hẹn") { requestClose() }
            Divider()
            form.padding(16)
            Divider()
            SheetFooter(message: message, hint: issue, action: "Tạo nhắc hẹn", busy: busy, disabled: issue != nil, cancel: { requestClose() }) {
                Task { await create() }
            }
        }
        .frame(width: 440)
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { now = $0 }
        .confirmationDialog("Bạn muốn huỷ nhắc hẹn đang được tạo?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Hủy thay đổi", role: .destructive) { dismiss() }
            Button("Không", role: .cancel) {}
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nội dung").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Nhập nội dung mới hoặc dán link", text: $title, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Chọn thời gian").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Picker("Chọn thời gian", selection: Binding(get: { choice }, set: pick)) {
                    Text("15 phút nữa").tag(TimeChoice.in15)
                    Text("30 phút nữa").tag(TimeChoice.in30)
                    Text("9:00 ngày mai").tag(TimeChoice.tomorrow9)
                    Text("Khác").tag(TimeChoice.custom)
                }
                .pickerStyle(.segmented).labelsHidden()
                if choice == .custom {
                    DatePicker("Chọn ngày nhắc hẹn", selection: $start, in: Calendar.current.startOfDay(for: now)..., displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "vi_VN"))
                        .font(.system(size: 13))
                } else {
                    Label(start.formatted(.dateTime.locale(Locale(identifier: "vi_VN")).weekday(.wide).day().month(.twoDigits).hour().minute()),
                          systemImage: "alarm")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Picker("Lặp lại", selection: $rule) {
                ForEach(ReminderRepeat.allCases) { Text($0.title).tag($0) }
            }
            .font(.system(size: 13))
            if info.pinToggle {
                Toggle("Ghim nhắc hẹn", isOn: $pin).toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
            }
        }
    }

    private func pick(_ next: TimeChoice) {
        choice = next
        if next != .custom { start = Self.time(for: next) }
    }

    /// The modal's chips: seconds dropped, "9:00 ngày mai" in local time.
    static func time(for choice: TimeChoice, from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let base = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        switch choice {
        case .in15: return base.addingTimeInterval(15 * 60)
        case .in30, .custom: return base.addingTimeInterval(30 * 60)
        case .tomorrow9:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }

    private func requestClose() { if trimmed.isEmpty { dismiss() } else { confirmDiscard = true } }

    /// WRITE: runs only from the "Tạo nhắc hẹn" button.
    private func create() async {
        now = Date()
        guard issue == nil, !busy else { return }
        busy = true; message = nil
        let outcome = await engine.createReminder(in: conversationId, title: title, start: start, repeat: rule, pin: info.canPin && pin)
        busy = false
        switch outcome {
        case .done, .cancelled: dismiss()
        case .pending(let text): CardActionCenter.shared.show(text, in: conversationId); dismiss()
        case .failed(let text): message = text
        }
    }
}

// MARK: - Chia sẻ (screenshot tool)

/// The conversations a screenshot (or its recognised text) is shared to — the official SHARE_MSG_COMPOSE picker, native.
struct ScreenshotShareSheet: View {
    let share: ScreenshotShare

    static let maxTargets = 10

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: [String] = []
    @State private var busy = false
    @State private var message: String?

    private var rows: [ZaloEngine.ConversationSummary] {
        let all = engine.visibleConversations.sorted { ($0.preview?.date ?? .distantPast) > ($1.preview?.date ?? .distantPast) }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { title(of: $0).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: share.text == nil ? "Chia sẻ ảnh chụp màn hình" : "Chia sẻ văn bản") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                preview
                TextField("Tìm cuộc trò chuyện", text: $search).textFieldStyle(.roundedBorder)
            }
            .padding(16)
            List(rows) { conversation in
                row(conversation)
            }
            .listStyle(.plain)
            Divider()
            SheetFooter(message: message, hint: "Đã chọn \(selected.count)/\(Self.maxTargets)", action: "Chia sẻ", busy: busy,
                        disabled: selected.isEmpty, cancel: { dismiss() }) {
                Task { await send() }
            }
        }
        .frame(width: 440, height: 560)
    }

    @ViewBuilder private var preview: some View {
        if let image = share.image, let picture = NSImage(contentsOf: image) {
            Image(nsImage: picture).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let text = share.text {
            Text(text).font(.system(size: 12.5)).lineLimit(4)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private func row(_ conversation: ZaloEngine.ConversationSummary) -> some View {
        let isOn = selected.contains(conversation.id)
        return Button {
            if isOn { selected.removeAll { $0 == conversation.id } }
            else if selected.count < Self.maxTargets { selected.append(conversation.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                RemoteAvatar(url: conversation.avatar, name: conversation.displayName, size: 30)
                Text(title(of: conversation)).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn && selected.count >= Self.maxTargets)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func title(of conversation: ZaloEngine.ConversationSummary) -> String {
        conversation.id == engine.selfConversationId ? "Cloud của tôi" : conversation.displayName
    }

    private func send() async {
        guard !selected.isEmpty, !busy else { return }
        busy = true; message = nil
        let outcome = await engine.shareScreenshot(share, to: selected)
        busy = false
        switch outcome {
        case .done, .cancelled: dismiss()
        case .pending(let text): CardActionCenter.shared.show(text, in: share.conversationId); dismiss()
        case .failed(let text): message = text
        }
    }
}

// MARK: - Shared chrome

struct SheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Đóng", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct SheetFooter: View {
    var message: String?
    var hint: String? = nil
    let action: String
    let busy: Bool
    let disabled: Bool
    let cancel: () -> Void
    let run: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let hint {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Hủy", action: cancel).keyboardShortcut(.cancelAction)
                Button(action: run) {
                    if busy { ProgressView().controlSize(.small) } else { Text(action) }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || busy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Engine-wide prompts of composer actions

/// What a composer action may ask while it runs, whichever chat is on screen: the official confirms (e.g. "Gửi dưới dạng file"),
/// the screenshot tool's "Chia sẻ" picker and the screen-recording permission notice.
private struct ComposerPrompts: ViewModifier {
    @Environment(ZaloEngine.self) private var engine

    func body(content: Content) -> some View {
        @Bindable var engine = engine
        content
            // Answered only by its buttons (the dismissal binding must not answer first and turn an OK into a cancel).
            .alert(engine.composerConfirm?.title ?? "", isPresented: Binding(get: { engine.composerConfirm != nil }, set: { _ in }),
                   presenting: engine.composerConfirm) { confirm in
                Button(confirm.ok) { engine.answerComposerConfirm(confirm, ok: true) }
                Button(confirm.cancel, role: .cancel) { engine.answerComposerConfirm(confirm, ok: false) }
            } message: { confirm in
                Text(confirm.message)
            }
            .sheet(item: $engine.screenshotShare) { share in
                ScreenshotShareSheet(share: share)
            }
            .alert("Cho phép ghi màn hình", isPresented: $engine.screenCaptureNeedsPermission) {
                Button("Mở Cài đặt") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
                Button("Để sau", role: .cancel) {}
            } message: {
                // STR_DES_NO_PERMISSION_MAC_1, then where to find it.
                Text("Để sử dụng tính năng chụp màn hình, cần được kích hoạt trong cài đặt của hệ điều hành. Hãy bật \(AppBrand.name) trong Quyền riêng tư & Bảo mật ▸ Ghi màn hình, rồi thử lại.")
            }
    }
}

extension View {
    func composerPrompts() -> some View { modifier(ComposerPrompts()) }
}

// MARK: - Clipboard & Spreadsheet Paste Inspection

/// Classification of `NSPasteboard` content when pasting (`⌘V`) or dropping into the chat composer.
@MainActor
enum ClipboardPasteContent: Equatable {
    /// File or directory URLs copied in Finder or dragged from disk.
    case files([URL])
    /// Both an image representation and plain text exist (e.g., copying cells in Excel, Numbers, Google Sheets, or a table).
    /// Presents a choice modal: Mode 1 = Gửi hình (Send as Image), Mode 2 = Gửi văn bản thuần túy (Send as Plain Text).
    case spreadsheetOrRichImageAndText(imageData: Data, imageSize: CGSize, text: String)
    /// Only an image representation exists (e.g., screenshot `⌃⌘⇧4` or "Copy Image").
    case imageOnly(imageData: Data, imageSize: CGSize)
    /// Plain text only.
    case plainText(String)
    /// Nothing actionable on the pasteboard.
    case empty

    private static let htmlPasteboardType = NSPasteboard.PasteboardType("public.html")
    private static let raycastRestoredType = NSPasteboard.PasteboardType("com.raycast.RestoredType")
    static let supportedImagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        .pdf,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.image"),
        NSPasteboard.PasteboardType("org.webmproject.webp"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("public.heic")
    ]

    /// Fast check for `validateUserInterfaceItem(_:)` so `Edit > Paste` (`⌘V`) and the context menu's `Paste` item stay enabled
    /// whenever the clipboard contains an image, file URL, spreadsheet, or plain text.
    static func hasPasteableContent(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: supportedImagePasteboardTypes + [.fileURL, .string, .tabularText, htmlPasteboardType]) != nil {
            return true
        }
        return NSImage.canInit(with: pasteboard)
    }

    static func inspect(_ pasteboard: NSPasteboard) -> ClipboardPasteContent {
        let types = pasteboard.types ?? []
        let isRaycastRestore = types.contains(raycastRestoredType)
        let pngIndex = types.firstIndex(of: .png)
        let fileURLIndex = types.firstIndex(of: .fileURL)
        // When an image is copied (or restored by a clipboard manager like Raycast), `.png` is placed on the pasteboard
        // ahead of `.fileURL` (whereas Finder file copy places `.fileURL` first and only includes a `.tiff` file icon).
        let prefersInlineImageOverFileURL: Bool = {
            if isRaycastRestore, pngIndex != nil { return true }
            if let pIdx = pngIndex, let fIdx = fileURLIndex, pIdx < fIdx { return true }
            return false
        }()

        // 1. Check for file URLs on disk first (unless a clipboard manager placed raw `.png` image data ahead of its temp cache file).
        if !prefersInlineImageOverFileURL,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let existing = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                return .files(existing)
            }
        }

        // 2. Read plain text (normalizing CRLF / CR line endings).
        let rawString = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .tabularText) ?? ""
        let normalizedText = rawString
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedText = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSpreadsheetText = !trimmedText.isEmpty && isSpreadsheetOrTableCopy(pasteboard: pasteboard, text: normalizedText)

        // 3. Check for image representations (.png, .tiff, .pdf, .jpeg, .webp — Excel and Numbers place .pdf / .tiff / .png on NSPasteboard).
        if let png = extractPNGImage(from: pasteboard, opaqueWhiteBackground: hasSpreadsheetText) {
            if hasSpreadsheetText {
                return .spreadsheetOrRichImageAndText(imageData: png.data, imageSize: png.size, text: normalizedText)
            }
            return .imageOnly(imageData: png.data, imageSize: png.size)
        }

        // Fallback if `.fileURL` existed alongside `.png` but `extractPNGImage` didn't decode it.
        if prefersInlineImageOverFileURL,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let existing = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                return .files(existing)
            }
        }

        // 4. If no bitmap/PDF was provided, check if the pasteboard carries tabular spreadsheet data (e.g. Google Sheets / TSV table).
        if !trimmedText.isEmpty {
            if isTabularSpreadsheet(pasteboard: pasteboard, text: normalizedText),
               let gridPNG = renderSpreadsheetGridToPNG(normalizedText) {
                return .spreadsheetOrRichImageAndText(imageData: gridPNG.data, imageSize: gridPNG.size, text: normalizedText)
            }
            return .plainText(normalizedText)
        }

        return .empty
    }

    /// Distinguishes a spreadsheet/table copy (Excel, Numbers, Google Sheets, Calc, HTML table, multi-cell TSV/multiline)
    /// from a single-line URL or filename string that browsers (Safari/Chrome "Copy Image") attach alongside a copied image.
    static func isSpreadsheetOrTableCopy(pasteboard: NSPasteboard, text: String) -> Bool {
        if isTabularSpreadsheet(pasteboard: pasteboard, text: text) {
            return true
        }
        let types = pasteboard.types?.map { $0.rawValue.lowercased() } ?? []
        let spreadsheetMarkers = ["excel", "spreadsheet", "iwork", "numbers", "art::gvml", "biff", "sylk", "csv", "tabular"]
        if types.contains(where: { raw in spreadsheetMarkers.contains(where: { raw.contains($0) }) }) {
            return true
        }
        if let html = pasteboard.string(forType: htmlPasteboardType),
           html.localizedCaseInsensitiveContains("<table") || html.localizedCaseInsensitiveContains("<tr") || html.localizedCaseInsensitiveContains("<td") {
            return true
        }
        if text.contains("\t") || text.contains("\n") {
            return true
        }
        return false
    }

    /// Extracts or rasterizes `.png`, `.tiff`, `.pdf`, `.jpeg`, `.webp`, or any `NSImage`-readable pasteboard data into a PNG buffer.
    static func extractPNGImage(from pasteboard: NSPasteboard, opaqueWhiteBackground: Bool) -> (data: Data, size: CGSize)? {
        let hasKnownType = pasteboard.availableType(from: supportedImagePasteboardTypes) != nil
        guard hasKnownType || NSImage.canInit(with: pasteboard) else { return nil }

        // Fast path: direct PNG without text (e.g., screenshot) when opaque white fill isn't required.
        if !opaqueWhiteBackground,
           let pngData = pasteboard.data(forType: .png),
           let rep = NSBitmapImageRep(data: pngData),
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            let size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            return (pngData, size)
        }

        var sourceImage: NSImage?
        for type in supportedImagePasteboardTypes {
            if let data = pasteboard.data(forType: type), let img = NSImage(data: data), img.size.width >= 2, img.size.height >= 2 {
                sourceImage = img
                break
            }
        }
        if sourceImage == nil, let img = NSImage(pasteboard: pasteboard), img.size.width >= 2, img.size.height >= 2 {
            sourceImage = img
        }
        guard let image = sourceImage else { return nil }
        return renderImageToPNG(image, opaqueWhiteBackground: opaqueWhiteBackground)
    }

    static func renderImageToPNG(_ image: NSImage, opaqueWhiteBackground: Bool) -> (data: Data, size: CGSize)? {
        let ptSize = image.size
        guard ptSize.width >= 2, ptSize.height >= 2 else { return nil }
        let maxDim = max(ptSize.width, ptSize.height)
        let scale: CGFloat = maxDim * 2 <= 4096 ? 2.0 : max(1.0, 4096.0 / maxDim)
        let pxW = max(2, Int((ptSize.width * scale).rounded()))
        let pxH = max(2, Int((ptSize.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = ptSize
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            let rect = NSRect(origin: .zero, size: ptSize)
            if opaqueWhiteBackground {
                NSColor.white.setFill()
                rect.fill()
            }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        return (pngData, CGSize(width: pxW, height: pxH))
    }

    /// Detects whether text on the pasteboard came from a spreadsheet or table copy when no bitmap/PDF was included.
    static func isTabularSpreadsheet(pasteboard: NSPasteboard, text: String) -> Bool {
        if let tabular = pasteboard.string(forType: .tabularText),
           !tabular.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           tabular.contains("\t") {
            return true
        }
        if let html = pasteboard.string(forType: htmlPasteboardType),
           html.localizedCaseInsensitiveContains("<table"),
           (text.contains("\t") || html.localizedCaseInsensitiveContains("<td")) {
            return true
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return false }
        let linesWithTabs = lines.filter { $0.contains("\t") }.count
        return linesWithTabs >= 2
    }

    /// Synthesizes a clean 2x Retina spreadsheet table PNG from tab-separated rows/columns.
    static func renderSpreadsheetGridToPNG(_ text: String) -> (data: Data, size: CGSize)? {
        let rawLines = text.components(separatedBy: "\n")
        let trimmedLines = rawLines.last?.isEmpty == true ? Array(rawLines.dropLast()) : rawLines
        let rows: [[String]] = trimmedLines.prefix(60).map { $0.components(separatedBy: "\t") }
        let colCount = rows.map(\.count).max() ?? 0
        guard !rows.isEmpty, colCount >= 1 else { return nil }

        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let padX: CGFloat = 12
        let rowHeight: CGFloat = 30
        let maxColWidth: CGFloat = 260
        let minColWidth: CGFloat = 68

        var colWidths = Array(repeating: minColWidth, count: colCount)
        for (rIdx, row) in rows.enumerated() {
            let f = rIdx == 0 && rows.count > 1 ? headerFont : font
            for (cIdx, cell) in row.enumerated() where cIdx < colCount {
                let measured = (cell as NSString).size(withAttributes: [.font: f]).width + padX * 2
                colWidths[cIdx] = min(maxColWidth, max(colWidths[cIdx], ceil(measured)))
            }
        }

        let outerPad: CGFloat = 12
        let tableWidth = colWidths.reduce(0, +)
        let tableHeight = CGFloat(rows.count) * rowHeight
        let totalSize = CGSize(width: tableWidth + outerPad * 2, height: tableHeight + outerPad * 2)

        let scale: CGFloat = 2.0
        let pxW = max(2, Int((totalSize.width * scale).rounded()))
        let pxH = max(2, Int((totalSize.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = totalSize

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            NSColor.white.setFill()
            NSRect(origin: .zero, size: totalSize).fill()

            let borderColor = NSColor(calibratedWhite: 0.82, alpha: 1.0)
            let headerFill = NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1.0)
            let zebraFill = NSColor(calibratedWhite: 0.985, alpha: 1.0)
            let textColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail

            for (rIdx, row) in rows.enumerated() {
                let y = totalSize.height - outerPad - CGFloat(rIdx + 1) * rowHeight
                var x = outerPad
                let isHeader = rIdx == 0 && rows.count > 1
                for cIdx in 0..<colCount {
                    let w = colWidths[cIdx]
                    let cellRect = NSRect(x: x, y: y, width: w, height: rowHeight)
                    if isHeader {
                        headerFill.setFill()
                        cellRect.fill()
                    } else if rIdx % 2 == 1 {
                        zebraFill.setFill()
                        cellRect.fill()
                    }
                    borderColor.setStroke()
                    let path = NSBezierPath(rect: cellRect)
                    path.lineWidth = 1.0
                    path.stroke()

                    let textValue = cIdx < row.count ? row[cIdx] : ""
                    if !textValue.isEmpty {
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: isHeader ? headerFont : font,
                            .foregroundColor: textColor,
                            .paragraphStyle: paragraph
                        ]
                        let textRect = NSRect(x: x + padX, y: y + (rowHeight - 18) / 2, width: w - padX * 2, height: 18)
                        (textValue as NSString).draw(in: textRect, withAttributes: attrs)
                    }
                    x += w
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        return (pngData, CGSize(width: pxW, height: pxH))
    }
}

/// Payload for `SpreadsheetPasteChoiceSheet` when the user pastes spreadsheet / table content.
struct SpreadsheetPastePayload: Identifiable, Equatable {
    let id = UUID()
    let imageData: Data
    let imageSize: CGSize
    let text: String
}

/// Modal allowing the user to choose between Mode 1 (Send as Image) and Mode 2 (Send as Plain Text) when pasting a spreadsheet.
struct SpreadsheetPasteChoiceSheet: View {
    enum Mode: Int, CaseIterable, Identifiable {
        case image = 1
        case plainText = 2
        var id: Int { rawValue }
    }

    let conversationId: String
    let conversationName: String
    let payload: SpreadsheetPastePayload
    let onInsertTextToDraft: (String) -> Void
    let onSent: () -> Void

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .image
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Chọn định dạng gửi") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Nội dung bảng tính vừa dán có thể gửi tới **\(conversationName)** theo 2 chế độ:")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    modeCard(
                        mode: .image,
                        badge: "Chế độ 1",
                        title: "Gửi hình",
                        subtitle: "Giữ nguyên khung bảng tính",
                        icon: "photo.fill"
                    )
                    modeCard(
                        mode: .plainText,
                        badge: "Chế độ 2",
                        title: "Gửi văn bản thuần túy",
                        subtitle: "Chỉ gửi nội dung chữ",
                        icon: "doc.plaintext.fill"
                    )
                }

                previewArea
            }
            .padding(16)
            Divider()
            footer
        }
        .frame(width: 480)
    }

    private func modeCard(mode target: Mode, badge: String, title: String, subtitle: String, icon: String) -> some View {
        let selected = mode == target
        return Button {
            withAnimation(.snappy(duration: 0.15)) { mode = target }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(badge.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(TintShapeStyle().opacity(0.12)) : AnyShapeStyle(Color.primary.opacity(0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(badge): \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var previewArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mode == .image ? "Xem trước hình ảnh bảng tính" : "Xem trước văn bản thuần túy")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if mode == .image {
                    Text("\(Int(payload.imageSize.width)) × \(Int(payload.imageSize.height)) px")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(payload.text.components(separatedBy: "\n").filter { !$0.isEmpty }.count) dòng")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            if mode == .image, let nsImage = NSImage(data: payload.imageData) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 440, maxHeight: 210)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
            } else {
                ScrollView {
                    Text(payload.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button("Chèn chữ vào ô nhập") {
                    onInsertTextToDraft(payload.text)
                    dismiss()
                }
                .disabled(busy)
                .help("Đưa văn bản thuần túy vào ô soạn thảo để chỉnh sửa trước khi gửi")

                Spacer()

                Button("Hủy") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)

                Button {
                    Task { await confirmSend() }
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .image ? "Gửi hình" : "Gửi văn bản thuần túy")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func confirmSend() async {
        guard !busy, !conversationId.isEmpty else { return }
        busy = true
        errorMessage = nil
        switch mode {
        case .image:
            guard let fileURL = ZaloEngine.writeTemporaryPasteImage(payload.imageData, prefix: "bang-tinh") else {
                busy = false
                errorMessage = "Không tạo được tệp ảnh tạm thời. Hãy thử lại."
                return
            }
            let outcome = await engine.sendMedia([fileURL], to: conversationId)
            busy = false
            switch outcome {
            case .done, .cancelled:
                onSent()
                dismiss()
            case .pending(let text):
                CardActionCenter.shared.show(text, in: conversationId)
                onSent()
                dismiss()
            case .failed(let text):
                errorMessage = text
            }
        case .plainText:
            let sent = await engine.sendText(payload.text, to: conversationId)
            busy = false
            if sent {
                onSent()
                dismiss()
            } else {
                errorMessage = "Không gửi được văn bản. Bạn có thể bấm \"Chèn chữ vào ô nhập\" để thử lại."
            }
        }
    }
}
