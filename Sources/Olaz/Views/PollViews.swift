import SwiftUI

// Group polls (MSG_POLL 26): the chat card, the vote / voter-list sheet and the "Tạo bình chọn" sheet. Layout and
// wording follow the official v3 poll UI (card ~9462018, vote popup ~8412500, create popup ~17508300 in compact-app-pc);
// data and every action go through `ZaloEngine+Poll.swift` → the official GroupPollManager.

private enum PollFormat {
    private static let deadline: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm dd/MM/yyyy"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "dd/MM"
        return f
    }()

    static func deadline(_ date: Date) -> String { deadline.string(from: date) }
    static func day(_ date: Date) -> String { day.string(from: date) }

    static func percent(_ weight: Double) -> String { "\(Int((weight * 100).rounded()))%" }
}

private struct PollChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(ChatPalette.incoming)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Setting chips under the question: deadline, one / many answers, hidden voters, hidden results (official `WYKB`).
private struct PollSettingsLine: View {
    let poll: PollDetail
    /// The vote popup also states "Chỉ chọn một phương án"; the chat card only the multi-choice case.
    var showsSingleChoice = false

    private var items: [(symbol: String, text: String)] {
        var out: [(String, String)] = []
        if let end = poll.expires { out.append(("clock", "Kết thúc lúc " + PollFormat.deadline(end))) }
        if poll.multi { out.append(("checklist", "Chọn nhiều phương án")) } else if showsSingleChoice { out.append(("checkmark.circle", "Chỉ chọn một phương án")) }
        if poll.anonymous { out.append(("person.fill.questionmark", "Ẩn người bình chọn")) }
        if poll.hidePreview { out.append(("eye.slash", "Ẩn kết quả khi chưa bình chọn")) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items, id: \.text) { item in
                Label(item.text, systemImage: item.symbol)
                    .labelStyle(CompactLabelStyle())
                    .foregroundStyle(item.symbol == "clock" && poll.isExpired() ? Color.red : Color.secondary)
            }
        }
        .font(.system(size: 11.5))
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.font(.system(size: 10.5)).frame(width: 13)
            configuration.title
        }
    }
}

/// One option: progress bar behind the text, vote count on the right, tick when I voted.
private struct PollOptionRow: View {
    let option: PollDetail.Option
    let weight: Double
    var showsCount = true
    /// Editing: leading checkbox / radio.
    var control: Control?

    struct Control {
        var multi: Bool
        var isOn: Bool
        var enabled: Bool
        var toggle: () -> Void
    }

    var body: some View {
        HStack(spacing: 8) {
            if let control {
                Button(action: control.toggle) {
                    Image(systemName: control.multi ? (control.isOn ? "checkmark.square.fill" : "square") : (control.isOn ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 16))
                        .foregroundStyle(control.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                }
                .buttonStyle(.plain)
                .disabled(!control.enabled)
                .accessibilityLabel(option.content)
                .accessibilityAddTraits(control.isOn ? .isSelected : [])
            }
            HStack(spacing: 6) {
                Text(option.content).font(.system(size: 13)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                if option.voted && control == nil {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tint)
                }
                if showsCount {
                    Text("\(option.votes)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.tint.opacity(weight >= 1 ? 0.28 : 0.16))
                        .frame(width: max(0, proxy.size.width * min(1, weight)))
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: control == nil ? .combine : .contain)
        .accessibilityLabel(control == nil ? "\(option.content), \(option.votes) phiếu, \(PollFormat.percent(weight))\(option.voted ? ", đã chọn" : "")" : "")
    }
}

// MARK: - Chat message

/// A poll event in the chat: the info line ("Lan đã bình chọn"), and under the newest event of a poll its card
/// (the official list shows the card only on the last message of each poll).
struct PollMessageView: View {
    let poll: ChatMessage.PollInfo
    let message: ChatMessage
    @Environment(ZaloEngine.self) private var engine
    @State private var sheet: PollSheetMode?

    private var conversationId: String { poll.conversationId.isEmpty ? message.conversationId : poll.conversationId }

    /// This message is the newest poll event of its poll in the loaded list.
    private var isNewest: Bool {
        guard !poll.pollId.isEmpty else { return true }
        let newest = engine.messages[message.conversationId]?.last { other in
            if case .poll(let info) = other.kind { return info.pollId == poll.pollId }
            return false
        }
        return newest == nil || newest?.id == message.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !poll.header.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill").foregroundStyle(.tint)
                    Text(poll.header).lineLimit(2)
                    if !poll.pollId.isEmpty {
                        Button("Xem") { sheet = .vote }.buttonStyle(.plain).foregroundStyle(.tint)
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            }
            if poll.pollId.isEmpty {
                PollFallbackCard(question: poll.question)
            } else if isNewest {
                PollDetailCard(poll: poll, conversationId: conversationId, open: { sheet = $0 })
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .sheet(item: $sheet) { mode in
            PollDetailSheet(pollId: poll.pollId, conversationId: conversationId, question: poll.question, startOnVoters: mode == .voters)
        }
    }
}

enum PollSheetMode: Identifiable {
    case vote, voters
    var id: Int { self == .vote ? 0 : 1 }
}

/// Used when the message carries no poll id (nothing to read): just the question.
private struct PollFallbackCard: View {
    let question: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chart.bar.fill").foregroundStyle(.tint)
            Text(question.isEmpty ? "Bình chọn" : question).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .modifier(PollChrome())
        .accessibilityElement(children: .combine)
    }
}

/// The poll card: question, settings, voter count, the first options with bars, and the vote button.
private struct PollDetailCard: View {
    let poll: ChatMessage.PollInfo
    let conversationId: String
    let open: (PollSheetMode) -> Void
    @Environment(ZaloEngine.self) private var engine
    @State private var config = PollConfig()

    var body: some View {
        Group {
            if let detail = engine.polls.details[poll.pollId] {
                content(detail)
            } else if engine.polls.failed.contains(poll.pollId) {
                VStack(alignment: .leading, spacing: 8) {
                    PollFallbackCard(question: poll.question)
                    Button("Thử lại") { engine.retryPoll(poll.pollId, in: conversationId) }.controlSize(.small)
                }
            } else {
                PollFallbackCard(question: poll.question).overlay(alignment: .bottomTrailing) { ProgressView().controlSize(.mini).padding(8) }
            }
        }
        .task(id: poll.pollId) {
            engine.watchPoll(poll.pollId, in: conversationId)
            config = await engine.pollCapabilities(in: conversationId).config
            await engine.refreshPollPin(poll.pollId, in: conversationId)
        }
    }

    private func content(_ detail: PollDetail) -> some View {
        let shown = detail.options.prefix(config.displayOptions)
        let rest = detail.options.count - shown.count
        return VStack(alignment: .leading, spacing: 8) {
            if engine.polls.pins[poll.pollId]?.pinned == true {
                Label("Đã ghim", systemImage: "pin.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.tint)
            }
            Text(detail.question.isEmpty ? poll.question : detail.question)
                .font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(4)
            PollSettingsLine(poll: detail)
            if detail.voterCount > 0 {
                Button { open(detail.votersVisible ? .voters : .vote) } label: {
                    HStack(spacing: 3) {
                        Text("\(detail.voterCount) người bình chọn")
                        if detail.votersVisible { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                    }
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 5) {
                ForEach(shown) { PollOptionRow(option: $0, weight: detail.weight(of: $0)) }
            }
            if rest > 0 {
                Text("* Còn \(rest) lựa chọn khác").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Button { open(.vote) } label: {
                Text(buttonTitle(detail)).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .modifier(PollChrome())
        .accessibilityElement(children: .contain)
    }

    private func buttonTitle(_ detail: PollDetail) -> String {
        if detail.closed || (detail.joined && detail.hidePreview) { return "Xem lựa chọn" }
        return detail.joined ? "Đổi lựa chọn" : "Bình chọn"
    }
}

// MARK: - Vote / voters sheet

/// The official "Bình chọn" popup: question, settings, options with checkboxes, "Thêm lựa chọn", and
/// "Chi tiết bình chọn" (who voted for what).
struct PollDetailSheet: View {
    let pollId: String
    let conversationId: String
    let question: String
    var startOnVoters = false

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PollVoteDraft?
    @State private var config = PollConfig()
    @State private var showVoters = false
    @State private var voters: PollVoters?
    @State private var votersFailed = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmHide = false
    @State private var confirmLock = false
    @State private var confirmExit = false
    @State private var pinConfirm: PollPinConfirm?

    private var detail: PollDetail? { engine.polls.details[pollId] }
    private var pinState: PollPinState { engine.polls.pins[pollId] ?? PollPinState() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let detail {
                    ScrollView {
                        if showVoters { votersPage(detail) } else { votePage(detail) }
                    }
                } else {
                    VStack(spacing: 8) {
                        if engine.polls.failed.contains(pollId) {
                            Text("Có lỗi xảy ra khi lấy thông tin bình chọn").font(.system(size: 12.5)).foregroundStyle(.secondary)
                            Button("Thử lại") { engine.retryPoll(pollId, in: conversationId) }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 560)
        .task(id: pollId) {
            showVoters = startOnVoters
            engine.watchPoll(pollId, in: conversationId)
            config = await engine.pollCapabilities(in: conversationId).config
            await engine.refreshPollPin(pollId, in: conversationId)
        }
        .task(id: detail) {
            // Live updates replace an untouched draft; edits in progress are kept.
            if let detail, draft == nil || draft?.hasChanges == false { draft = PollVoteDraft(detail) }
            if showVoters { await loadVoters() }
        }
        .onChange(of: showVoters) { _, on in if on { Task { await loadVoters() } } }
        .alert("Khóa bình chọn?", isPresented: $confirmLock) {
            Button("Khóa bình chọn", role: .destructive) { Task { await lock() } }
            Button("Không", role: .cancel) {}
        } message: {
            Text("Sau khi khóa, bạn & các thành viên khác sẽ không thể tiếp tục tham gia bình chọn")
        }
        .alert("Cập nhật danh sách ghim", isPresented: Binding(get: { pinConfirm != nil }, set: { if !$0 { pinConfirm = nil } }), presenting: pinConfirm) { confirm in
            Button("Cập nhật") { Task { await pin(confirming: confirm.ref) } }
            Button("Hủy", role: .cancel) {}
        } message: { confirm in
            Text(confirm.message)
        }
        .alert("Ẩn kết quả khi chưa bình chọn", isPresented: $confirmHide) {
            Button("Xác nhận") { Task { await submit() } }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Bạn không thể thay đổi lựa chọn")
        }
        .confirmationDialog("Bạn chưa lưu bình chọn của mình. Thoát bình chọn?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Thoát", role: .destructive) { dismiss() }
            Button("Hủy", role: .cancel) {}
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 8) {
            if showVoters {
                Button("Quay lại", systemImage: "chevron.left") { showVoters = false }.labelStyle(.iconOnly).buttonStyle(.plain)
            }
            Text(showVoters ? "Chi tiết bình chọn" : "Bình chọn").font(.system(size: 15, weight: .semibold))
            Spacer()
            if let detail, !showVoters {
                Menu {
                    // Official menu order: pin / unpin (only with `isEnablePin`), then share, then lock.
                    if pinState.offersPin {
                        if pinState.pinned {
                            Button("Bỏ ghim bình chọn", systemImage: "pin.slash") { Task { await unpin() } }
                        } else {
                            Button("Ghim lên đầu trò chuyện", systemImage: "pin") { Task { await pin() } }
                        }
                    }
                    Button("Gửi vào nhóm", systemImage: "arrowshape.turn.up.right") { Task { await share() } }
                    if detail.canClose && !detail.closed {
                        Button("Khóa bình chọn", systemImage: "lock", role: .destructive) { confirmLock = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 16))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(busy)
                .accessibilityLabel("Tùy chọn bình chọn")
            }
            Button("Đóng", systemImage: "xmark") { requestClose() }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if showVoters || detail == nil || editingLocked {
                    Button("Đóng") { dismiss() }
                } else {
                    Button("Hủy") { requestClose() }
                    Button { requestSubmit() } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Xác nhận") }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canConfirm || busy)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var editingLocked: Bool { detail?.isVotingLocked() ?? true }

    private var canConfirm: Bool {
        guard let detail, let draft else { return false }
        return draft.canSubmit && !draft.hasDuplicates(in: detail)
    }

    // MARK: Vote page

    private func votePage(_ detail: PollDetail) -> some View {
        let draft = self.draft ?? PollVoteDraft(detail)
        let preview = draft.applied(to: detail)
        let locked = detail.isVotingLocked()
        let addVisible = detail.allowAdd && !locked && detail.options.count + draft.added.count < config.maxOptions
        return VStack(alignment: .leading, spacing: 12) {
            Text(detail.question.isEmpty ? question : detail.question).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
            let byline = [detail.creatorName.isEmpty ? nil : "Tạo bởi \(detail.creatorName)", detail.created.map(PollFormat.day)].compactMap { $0 }
            if !byline.isEmpty {
                Text(byline.joined(separator: " - ")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if pinState.pinned {
                Label("Đã ghim lên đầu trò chuyện", systemImage: "pin.fill").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tint)
            }
            PollSettingsLine(poll: detail, showsSingleChoice: true)
            if detail.voterCount > 0 {
                Button { showVoters = true } label: {
                    HStack(spacing: 3) {
                        Text("\(detail.voterCount) người bình chọn")
                        if detail.votersVisible { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(detail.votersVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                }
                .buttonStyle(.plain).disabled(!detail.votersVisible)
            }
            if detail.resultsHidden && !locked {
                Text("Người tham gia chỉ có thể thấy kết quả sau khi bình chọn.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(detail.options) { option in
                    let shown = preview.options.first { $0.id == option.id } ?? option
                    PollOptionRow(option: shown, weight: preview.weight(of: shown),
                                  control: .init(multi: detail.multi, isOn: draft.selected.contains(option.id), enabled: !locked && !busy) {
                                      var next = self.draft ?? PollVoteDraft(detail)
                                      next.toggle(option.id)
                                      self.draft = next
                                  })
                }
                ForEach(draft.added) { row in addedRow(row, detail: detail, draft: draft) }
            }
            if addVisible {
                Button("Thêm lựa chọn", systemImage: "plus") {
                    var next = self.draft ?? PollVoteDraft(detail)
                    next.addRow()
                    self.draft = next
                }
                .buttonStyle(.glass).controlSize(.regular)
                .disabled(draft.hasDuplicates(in: detail))
            }
            if detail.closed {
                Label("Bình chọn đã đóng", systemImage: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if detail.isExpired() {
                Label("Đã hết hạn", systemImage: "clock.badge.exclamationmark").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if detail.hidePreview && detail.joined {
                Label("Không thể thay đổi bình chọn", systemImage: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addedRow(_ row: PollVoteDraft.Added, detail: PollDetail, draft: PollVoteDraft) -> some View {
        let binding = Binding<String>(
            get: { self.draft?.added.first { $0.id == row.id }?.text ?? row.text },
            set: { text in
                guard var next = self.draft, let at = next.added.firstIndex(where: { $0.id == row.id }) else { return }
                next.added[at].text = text.limitedUTF16(config.maxOption)
                self.draft = next
            })
        let empty = row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    var next = self.draft ?? draft
                    next.setAddedVoted(row.id, !row.voted)
                    self.draft = next
                } label: {
                    Image(systemName: detail.multi ? (row.voted ? "checkmark.square.fill" : "square") : (row.voted ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 16)).foregroundStyle(row.voted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                }
                .buttonStyle(.plain).disabled(empty)
                .accessibilityLabel("Chọn lựa chọn mới")
                TextField("Lựa chọn \(detail.options.count + (draft.added.firstIndex { $0.id == row.id } ?? 0) + 1)", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        // Official: Enter / Tab in the last option adds the next row.
                        guard var next = self.draft, next.added.last?.id == row.id, !row.text.trimmingCharacters(in: .whitespaces).isEmpty,
                              detail.options.count + next.added.count < config.maxOptions, !next.hasDuplicates(in: detail) else { return }
                        next.addRow()
                        self.draft = next
                    }
                Button("Xóa lựa chọn", systemImage: "xmark.circle.fill") {
                    var next = self.draft ?? draft
                    next.removeAdded(row.id)
                    self.draft = next
                }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if draft.isDuplicate(row.id, in: detail) {
                Text("Phương án được thêm đã tồn tại").font(.system(size: 11)).foregroundStyle(.red).padding(.leading, 24)
            }
        }
    }

    // MARK: Voters page

    private func votersPage(_ detail: PollDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let voters {
                if voters.restricted || voters.groups.isEmpty {
                    Text(voters.restricted ? "Danh sách người bình chọn không được hiển thị." : "Chưa có ai bình chọn.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                ForEach(voters.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(group.content) (\(group.votes))").font(.system(size: 13, weight: .semibold))
                        ForEach(group.users) { user in
                            HStack(spacing: 10) {
                                RemoteAvatar(url: user.avatar, name: user.name, size: 28)
                                Text(user.name).font(.system(size: 13)).lineLimit(1)
                                if user.isMe { Text("Bạn").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            } else if votersFailed {
                VStack(spacing: 8) {
                    Text("Không tải được danh sách người bình chọn").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Button("Thử lại") { Task { await loadVoters() } }
                }
                .frame(maxWidth: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadVoters() async {
        votersFailed = false
        if let next = await engine.pollVoters(pollId) { voters = next } else if voters == nil { votersFailed = true }
    }

    // MARK: Actions (each one starts from a button press)

    private func requestClose() {
        if !showVoters, draft?.hasChanges == true { confirmExit = true } else { dismiss() }
    }

    private func requestSubmit() {
        guard let detail, let draft else { return }
        if detail.isExpired() { message = "Bình chọn \(detail.question) đã hết hạn"; return }
        if draft.hasDuplicates(in: detail) { message = "Phương án được thêm đã tồn tại"; return }
        if detail.hidePreview && !draft.votesNothing { confirmHide = true } else { Task { await submit() } }
    }

    private func submit() async {
        guard let detail, var draft, !busy else { return }
        busy = true; message = nil
        // A field left while composing may still be over the limit.
        for index in draft.added.indices { draft.added[index].text = draft.added[index].text.prefixUTF16(config.maxOption) }
        let result = await engine.votePoll(pollId, in: conversationId, draft: draft, detail: detail)
        busy = false
        if result.ok { dismiss() } else { message = result.message(for: .vote) }
    }

    private func lock() async {
        guard !busy else { return }
        busy = true; message = nil
        let result = await engine.lockPoll(pollId, in: conversationId)
        busy = false
        if result.ok { dismiss() } else { message = result.message(for: .lock) }
    }

    private func share() async {
        guard !busy else { return }
        busy = true; message = nil
        let result = await engine.sharePoll(pollId, in: conversationId)
        busy = false
        if result.ok { dismiss() } else { message = result.message(for: .share) }
    }

    /// "Ghim lên đầu trò chuyện" (user click). A full board asks first; the confirmation replaces the oldest pin.
    private func pin(confirming ref: String? = nil) async {
        guard !busy else { return }
        busy = true; message = nil
        let outcome = await engine.pinPoll(pollId, in: conversationId, confirming: ref)
        busy = false
        switch outcome {
        case .done: break
        case .needsConfirmation(let confirm): pinConfirm = confirm
        case .failed(let result): message = result.message(for: .pin)
        }
    }

    private func unpin() async {
        guard !busy else { return }
        busy = true; message = nil
        let result = await engine.unpinPoll(pollId, in: conversationId)
        busy = false
        if !result.ok { message = result.message(for: .unpin) }
    }
}

// MARK: - Create sheet

/// The official "Tạo bình chọn" popup (group chat bar item): question, options, advanced settings.
struct PollCreateSheet: View {
    let conversationId: String

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var caps = PollCapabilities()
    @State private var loaded = false
    @State private var draft = PollCreateDraft()
    @State private var showSettings = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDiscard = false
    /// Stable row identities for `draft.options` (same order and count): removing an option must not hand its field, focus
    /// and IME state to the next one, as index ids did.
    @State private var optionIDs: [UUID] = []

    private var config: PollConfig { caps.config }
    private var issue: PollCreateDraft.Issue? { draft.issue(config: config) }
    private var isDirty: Bool { !draft.trimmedQuestion.isEmpty || !draft.filledOptions.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tạo bình chọn").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Đóng", systemImage: "xmark") { requestClose() }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView { form.padding(16) }
            Divider()
            footer
        }
        .frame(width: 460, height: 580)
        .task {
            caps = await engine.pollCapabilities(in: conversationId)
            loaded = true
            let minimum = caps.config.minOptions
            if draft.options.count < minimum { draft.options += Array(repeating: "", count: minimum - draft.options.count) }
            syncOptionIDs()
        }
        .onAppear(perform: syncOptionIDs)
        .onChange(of: draft.options.count) { _, _ in syncOptionIDs() }
        .confirmationDialog("Bạn muốn hủy tạo bình chọn?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Hủy tạo bình chọn", role: .destructive) { dismiss() }
            Button("Không", role: .cancel) {}
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loaded && !caps.ready {
                notice("Chưa đọc được thông tin nhóm hoặc dịch vụ bình chọn của Zalo.")
            } else if loaded && !caps.canCreate {
                notice("Chỉ trưởng/phó nhóm được phép tạo bình chọn")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Chủ đề bình chọn").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Nội dung bình chọn?", text: Binding(get: { draft.question }, set: { draft.question = $0.limitedUTF16(config.maxQuestion) }), axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Các lựa chọn").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(optionIDs.prefix(draft.options.count).enumerated()), id: \.element) { index, _ in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            TextField("Lựa chọn \(index + 1)", text: Binding(
                                get: { draft.options.indices.contains(index) ? draft.options[index] : "" },
                                set: { if draft.options.indices.contains(index) { draft.options[index] = $0.limitedUTF16(config.maxOption) } }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    if index == draft.options.count - 1, !draft.options[index].trimmingCharacters(in: .whitespaces).isEmpty,
                                       draft.options.count < config.maxOptions, !draft.isDuplicate(at: index) { appendOption() }
                                }
                            if draft.options.count > config.minOptions {
                                Button("Xóa lựa chọn", systemImage: "xmark.circle.fill") { removeOption(at: index) }
                                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                        if draft.isDuplicate(at: index) {
                            Text("Bạn đã tạo trùng phương án.").font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                }
                Button("Thêm lựa chọn", systemImage: "plus") { appendOption() }
                    .buttonStyle(.glass)
                    .disabled(draft.options.count >= config.maxOptions || draft.options.indices.contains { draft.isDuplicate(at: $0) })
            }
            DisclosureGroup(isExpanded: $showSettings) { settings.padding(.top, 8) } label: {
                Text("Thiết lập nâng cao").font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Thời hạn bình chọn", isOn: $draft.hasDeadline)
            if draft.hasDeadline {
                DatePicker("Kết thúc lúc", selection: $draft.deadline, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .environment(\.locale, Locale(identifier: "vi_VN"))
            } else {
                Text("Không thời hạn").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Ghim lên đầu trò chuyện", isOn: $draft.pin).disabled(!caps.canPin)
            Toggle("Chọn nhiều phương án", isOn: $draft.multi)
                .help("Người tham gia có thể bình chọn nhiều phương án khác nhau")
            Toggle("Có thể thêm phương án", isOn: Binding(get: { draft.effectiveAllowAdd }, set: { draft.allowAdd = $0 }))
                .disabled(draft.hidePreview)
                .help("Người tham gia có thể thêm phương án mới")
            if config.enableHidePreview || config.enableAnonymous {
                Divider()
                Text("Bình chọn ẩn danh").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if config.enableHidePreview {
                    Toggle("Ẩn kết quả khi chưa bình chọn", isOn: $draft.hidePreview)
                        .help("Người tham gia chỉ có thể thấy kết quả sau khi bình chọn.")
                }
                if config.enableAnonymous {
                    Toggle("Ẩn người bình chọn", isOn: $draft.anonymous)
                        .help("Người tham gia không thể thấy người khác bình chọn.")
                }
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .font(.system(size: 13))
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle.fill").font(.system(size: 12.5)).foregroundStyle(.secondary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let hint = hint {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Hủy") { requestClose() }.keyboardShortcut(.cancelAction)
                Button { Task { await create() } } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Tạo bình chọn") }
                }
                .buttonStyle(.glassProminent)
                .disabled(issue != nil || !caps.canCreate || busy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var hint: String? {
        switch issue {
        case .emptyQuestion: "Vui lòng đặt câu hỏi cho bình chọn."
        case .tooFewOptions(let n): "Bạn không thể tạo bình chọn ít hơn \(n) bình chọn"
        case .duplicate: "Bạn đã tạo trùng phương án."
        case .pastDeadline: "Vui lòng chọn thời gian tương lai"
        case nil: nil
        }
    }

    private func requestClose() { if isDirty { confirmDiscard = true } else { dismiss() } }

    private func appendOption() {
        syncOptionIDs()
        draft.options.append("")
        optionIDs.append(UUID())
    }

    private func removeOption(at index: Int) {
        guard draft.options.indices.contains(index) else { return }
        syncOptionIDs()
        draft.options.remove(at: index)
        optionIDs.remove(at: index)
    }

    /// Options added or dropped elsewhere (the minimum filled in on load) get / lose ids at the end.
    private func syncOptionIDs() {
        let count = draft.options.count
        if optionIDs.count < count { optionIDs += (optionIDs.count..<count).map { _ in UUID() } }
        else if optionIDs.count > count { optionIDs.removeLast(optionIDs.count - count) }
    }

    /// WRITE: runs only from the "Tạo bình chọn" button.
    private func create() async {
        guard issue == nil, caps.canCreate, !busy else { return }
        busy = true; message = nil
        // A field left while composing may still be over the limit.
        var sent = draft
        sent.question = sent.question.prefixUTF16(config.maxQuestion)
        sent.options = sent.options.map { $0.prefixUTF16(config.maxOption) }
        let result = await engine.createPoll(in: conversationId, draft: sent, config: config, canPin: caps.canPin)
        busy = false
        if result.ok {
            if result.pinSkipped {
                CardActionCenter.shared.show("Đã tạo bình chọn nhưng chưa ghim được (bảng ghim đã đầy hoặc chưa kiểm tra được). Bạn có thể ghim từ menu bình chọn.", in: conversationId)
            }
            dismiss()
        } else { message = result.message(for: .create) }
    }
}
