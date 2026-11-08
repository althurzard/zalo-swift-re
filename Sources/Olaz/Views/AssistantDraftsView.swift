import SwiftUI

/// "Duyệt nháp" window: every reply an AI proposed through the assistant socket. Nothing leaves without a click on Gửi.
struct AssistantDraftsView: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var showFinished = false

    private var desk: AssistantDesk { engine.assistant }

    var body: some View {
        let shown = desk.drafts.filter { showFinished || $0.isOpen }.reversed()
        VStack(spacing: 0) {
            header
            Divider()
            if shown.isEmpty {
                ContentUnavailableView("Chưa có nháp nào", systemImage: "tray",
                                       description: Text(desk.isListening ? "AI đề xuất trả lời sẽ hiện ở đây để bạn duyệt."
                                                                          : "Bật Trợ lý AI trong Cài đặt để nhận nháp."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(shown)) { DraftCard(draft: $0, desk: desk) }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var header: some View {
        @Bindable var desk = desk
        return HStack(spacing: 10) {
            Label(desk.isListening ? "Đang nhận nháp" : "Trợ lý AI đang tắt",
                  systemImage: desk.isListening ? "dot.radiowaves.left.and.right" : "pause.circle")
                .foregroundStyle(desk.isListening ? Color.green : Color.secondary)
            if let error = desk.lastError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
            Spacer()
            Toggle("Tạm dừng gửi", isOn: $desk.paused).toggleStyle(.switch).controlSize(.small)
            Toggle("Hiện đã xong", isOn: $showFinished).toggleStyle(.checkbox)
            Button("Dọn", action: desk.clearFinished).disabled(!desk.drafts.contains { !$0.isOpen })
        }
        .padding(10)
    }
}

private struct DraftCard: View {
    let draft: AssistantDesk.Draft
    let desk: AssistantDesk
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(draft.conversationName).font(.headline)
                Spacer()
                stateBadge
                Text(draft.created, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            if !draft.replyingTo.isEmpty {
                Text("Khách: \(draft.replyingTo)").font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if draft.state == .pending {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    .focused($editing)
                    .onChange(of: text) { _, new in if new != draft.text { desk.edit(draft.id, text: new) } }
            } else {
                Text(draft.text).textSelection(.enabled)
            }
            if draft.quoteMessageId != nil { Label("Trả lời trích dẫn tin của khách", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.secondary) }
            if !draft.mentions.isEmpty {
                Label("Tag: " + draft.mentions.map { "@" + $0.name }.joined(separator: ", "), systemImage: "at").font(.caption).foregroundStyle(.secondary)
            }
            if !draft.note.isEmpty { Text("AI: \(draft.note)").font(.caption).foregroundStyle(.secondary) }
            ForEach(draft.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                switch draft.state {
                case .pending:
                    Button("Bỏ", role: .destructive) { desk.discard(draft.id) }
                    Button("Gửi") { desk.approve(draft.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .queued:
                    Button("Huỷ") { desk.discard(draft.id) }
                case .failed:
                    Button("Sửa lại") { desk.retry(draft.id) }
                default: EmptyView()
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .onAppear { text = draft.text }
    }

    @ViewBuilder private var stateBadge: some View {
        switch draft.state {
        case .pending: Text("Chờ duyệt").badgeStyle(.blue)
        case .queued(let t): (Text("Chờ lượt gửi ") + Text(t, style: .relative)).badgeStyle(.orange)
        case .sending: Text("Đang gửi").badgeStyle(.orange)
        case .sent: Text("Đã gửi").badgeStyle(.green)
        case .discarded: Text("Đã bỏ").badgeStyle(.gray)
        case .failed(let why): Text(why).badgeStyle(.red)
        }
    }
}

private extension Text {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule).lineLimit(2)
    }
}

/// Settings ▸ Trợ lý AI.
struct AssistantSettings: View {
    @Environment(ZaloEngine.self) private var engine
    @AppStorage(AssistantDesk.enabledKey) private var enabled = false
    @AppStorage(AssistantDesk.chatApprovalKey) private var chatApproval = false

    var body: some View {
        Section {
            Toggle("Cho phép công cụ AI (MCP) đọc tin và đề xuất trả lời", isOn: $enabled)
                .onChange(of: enabled) { _, on in engine.assistant.setEnabled(on) }
            Toggle("Cho phép duyệt qua chat (nói \"duyệt\" với AI)", isOn: $chatApproval)
            LabeledContent("Trạng thái", value: engine.assistant.isListening ? "Đang lắng nghe" : "Tắt")
            LabeledContent("Socket") { Text(AssistantDesk.socketPath).font(.caption).textSelection(.enabled) }
        } footer: {
            Text("AI chỉ tạo nháp. Tin chỉ được gửi khi bạn bấm Gửi (⌘⇧D) hoặc, nếu bật duyệt qua chat, khi bạn nói \"duyệt\" sau khi đọc preview. Giới hạn chống khoá luôn áp dụng.")
        }
        Section("Giới hạn chống khoá tài khoản") {
            LabeledContent("Khoảng cách giữa 2 tin", value: "≥ \(Int(SendGuard.minGap))–\(Int(SendGuard.minGap + SendGuard.maxJitter)) giây")
            LabeledContent("Tối đa", value: "\(SendGuard.maxPerBurst) tin / 10 phút · \(SendGuard.maxPerDay) tin / 24 giờ")
            LabeledContent("Mỗi hội thoại", value: "\(SendGuard.maxPerConversationHour) tin / giờ")
            LabeledContent("Chỉ trả lời", value: "khách đã nhắn trong 7 ngày")
            LabeledContent("Nội dung trùng", value: "chặn khi gửi cho > \(SendGuard.maxSameTextConversations) hội thoại / giờ")
            LabeledContent("Lỗi gửi", value: "2 lần liên tiếp → tự tạm dừng")
        }
    }
}
